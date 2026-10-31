# llama.cpp for the CMP 170HX

`llama-server` (plus `llama-bench`) built for the NVIDIA CMP 170HX (GA100, sm_80) from upstream llama.cpp
releases. See the [Dockerfile](Dockerfile) for how the build differs from upstream, and
[docker-compose.yaml](docker-compose.yaml) for how it runs Qwen3.8-Flash-Next.

## Benchmarking

Measure against the running server, so the numbers include exactly what it does: `--fit` placement,
`--load-mode`, MTP and so on.

### One-time setup: a realistic prompt

Which experts the model uses depends on the text, and some experts live on the CPU, so use a prompt that looks
like real use (a source file, a long document) rather than repeated filler. Repeated text also makes MTP
acceptance look far better than it is.

Save about 30 KB of text (roughly 8k tokens) as `./models/bench-prompt.txt`, then wrap it in a request:

```bash
docker run --rm -v ./models:/models python:3.12-slim python -c 'import json; p = open("/models/bench-prompt.txt").read(); json.dump({"prompt": p, "n_predict": 256, "ignore_eos": True, "seed": 42, "cache_prompt": False}, open("/models/bench-prompt.json", "w"))'
```

`ignore_eos` makes every run generate the full `n_predict` tokens (otherwise the model can stop early, even
after 0 tokens), and the fixed `seed` makes every run produce the same text. `models/` is git-ignored, so the
prompt stays local.

### Running a measurement

1. Change one setting in `docker-compose.yaml` (e.g. `--threads`).
2. Restart with `docker compose up -d` and wait until `docker compose ps` shows the server as healthy.
3. Make sure nothing else (Bifrost clients) is using the server.
4. Run [`./bench.sh`](bench.sh). It sends the prompt three times, treats the first as a warm-up and prints
   prefill and generation speed for each run plus the average of the other two:

```
prompt: 6844 tokens, generated: 256 tokens
run 1 (warm-up): prefill   470.4 tok/s   generation  37.48 tok/s
run 2:           prefill   ...
run 3:           prefill   ...
average (2):     prefill   ...
```

`./bench.sh 5` does more runs. Runs that generated fewer tokens than `n_predict` are flagged and left out of the
average. With MTP enabled each run also shows how many drafted tokens were accepted, e.g.
`draft 180/300 accepted (60%)`. Generation speed then varies a lot more between runs, so use 6 or more. Under the hood each run is:

```bash
docker exec llama-server sh -c 'curl -s localhost:8080/completion -H "Authorization: Bearer $LLAMA_API_KEY" -H "Content-Type: application/json" -d @/models/bench-prompt.json' | grep -o '"timings":{[^}]*}'
```

`prompt_per_second` is prefill speed and `predicted_per_second` is generation speed, in tokens/s. The server
logs the same numbers for every request (`docker compose logs -f llama-server`), and with MTP enabled also the
draft acceptance rate.

For a quick sanity check without a prompt file, generate filler instead (fine for prefill, not representative
for generation or MTP):

```bash
docker exec llama-server sh -c 'curl -s localhost:8080/completion -H "Authorization: Bearer $LLAMA_API_KEY" -H "Content-Type: application/json" -d "{\"prompt\":\"$(yes "The quick brown fox jumps over the lazy dog." | head -n 800 | tr "\n" " ")\",\"n_predict\":256,\"cache_prompt\":false}"' | grep -o '"timings":{[^}]*}'
```

### Thread counts

`--threads` can't usefully go above the number of CPUs in `cpuset`; widen `cpuset` first to test more. Use
physical cores only (check with `lscpu -e` on the host; hyperthread siblings share a `CORE`).

### llama-bench (for the two-card setup)

The image also contains `llama-bench`, which sweeps several values in one run (e.g. `-ub 512,1024,2048`).
It doesn't do `--fit`, so on one card it can't reproduce the server's expert placement. Once the whole model
fits in VRAM on two cards, it works as is. Stop the server first so it has the VRAM:

```bash
docker compose stop llama-server
docker compose run --rm --entrypoint /app/llama-bench llama-server -m /models/huihui/unsloth-UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf -ngl 999 -mmp 0 -fa 1 -ctk q8_0 -ctv q8_0 -ub 512,1024,2048 -p 2048 -n 128 -r 3
docker compose start llama-server
```
