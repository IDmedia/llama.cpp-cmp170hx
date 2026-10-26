# llama.cpp for the CMP 170HX

`llama-server` (plus `llama-bench`) built for the NVIDIA CMP 170HX (GA100, sm_80) from upstream llama.cpp
releases. See the [Dockerfile](Dockerfile) for how the build differs from upstream, and
[docker-compose.yaml](docker-compose.yaml) for how it runs Qwen3.8-Flash-Next.

## Benchmarking

Change one setting per run and keep everything else (image tag, quant, prompt) the same.

### Quick sweeps with llama-bench

Good for comparing thread counts and batch sizes. The model only just fits in VRAM, so stop the server first:

```bash
docker compose stop llama-server
```

`llama-bench` doesn't use `--fit`, so copy the expert placement from the server instead. Look up how many
expert layers `--fit` put on the CPU at the last startup:

```bash
docker compose logs llama-server | grep -iE "fit|cpu_moe|offload"
```

Then run the bench through the same service, so it gets the same `cpuset`, GPU and model volume. Replace `N` with
that number:

```bash
docker compose run --rm --entrypoint /app/llama-bench llama-server -m /models/huihui/unsloth-UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf -ngl 999 -ncmoe N -mmp 0 -fa 1 -ctk q8_0 -ctv q8_0 -b 2048 -ub 1024 -t 6,8,10,12 -p 2048 -n 128 -r 3
```

- `pp2048` is prompt processing (prefill) and `tg128` is generation, in tokens/s.
- Comma-separated values are all tested in one run, e.g. `-t 6,8,10,12` or `-ub 512,1024`.
- `-d 0,32768` repeats the tests with a filled context. Long-context speed is often what matters in practice.
- `-mmp 0` reads the weights into RAM. Without it the CPU-side tensors are read through mmap from `./models`,
  which is slow on Unraid's `/mnt/user` and makes `tg` look worse than it is.
- `--threads` can't usefully go above the number of CPUs in `cpuset`. To test more threads, widen `cpuset`
  first. Use physical cores only (check with `lscpu -e` on the host; hyperthread siblings share a `CORE`).

Start the server again afterwards:

```bash
docker compose start llama-server
```

### Real numbers from the running server

`llama-bench` doesn't do `--fit`, `--load-mode` or speculative decoding exactly like the server, so check the
final settings against the server itself. After changing `docker-compose.yaml`, restart it
(`docker compose up -d`) and send the same ~8k-token prompt each time:

```bash
docker exec llama-server sh -c 'curl -s localhost:8080/completion -H "Authorization: Bearer $LLAMA_API_KEY" -H "Content-Type: application/json" -d "{\"prompt\":\"$(yes "The quick brown fox jumps over the lazy dog." | head -n 800 | tr "\n" " ")\",\"n_predict\":256,\"cache_prompt\":false}"' | grep -o '"timings":{[^}]*}'
```

`prompt_per_second` is prefill speed and `predicted_per_second` is generation speed. Run it two or three times
and ignore the first run. The server also logs the same numbers for every request (`docker compose logs -f
llama-server`), and with MTP enabled it logs the draft acceptance rate.
