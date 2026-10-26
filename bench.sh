#!/bin/sh
# Benchmark the running llama-server with models/bench-prompt.json (see README).
#
# Usage: ./bench.sh [runs]
#   runs  number of requests (default 3). The first is a warm-up and isn't counted in the average.
#
# CONTAINER and PROMPT (path inside the container) can be overridden through the environment.
set -eu

RUNS=${1:-3}
CONTAINER=${CONTAINER:-llama-server}
PROMPT=${PROMPT:-/models/bench-prompt.json}

# Pulls one number out of the "timings" object.
field() {
    echo "$1" | sed -n "s/.*\"$2\":\([0-9.]*\).*/\1/p"
}

pp_sum=0
tg_sum=0
i=1
while [ "$i" -le "$RUNS" ]; do
    # $LLAMA_API_KEY is expanded inside the container, $PROMPT here.
    timings=$(docker exec "$CONTAINER" sh -c \
        "curl -sf localhost:8080/completion -H \"Authorization: Bearer \$LLAMA_API_KEY\" -H 'Content-Type: application/json' -d @$PROMPT" \
        | grep -o '"timings":{[^}]*}') || { echo "run $i: request failed" >&2; exit 1; }

    pp=$(field "$timings" prompt_per_second)
    tg=$(field "$timings" predicted_per_second)
    label="run $i"
    if [ "$i" -eq 1 ]; then
        label="run 1 (warm-up)"
        echo "prompt: $(field "$timings" prompt_n) tokens, generated: $(field "$timings" predicted_n) tokens"
    else
        pp_sum=$(awk "BEGIN { print $pp_sum + $pp }")
        tg_sum=$(awk "BEGIN { print $tg_sum + $tg }")
    fi
    awk "BEGIN { printf \"%-16s prefill %7.1f tok/s   generation %6.2f tok/s\n\", \"$label:\", $pp, $tg }"
    i=$((i + 1))
done

if [ "$RUNS" -gt 1 ]; then
    n=$((RUNS - 1))
    awk "BEGIN { printf \"%-16s prefill %7.1f tok/s   generation %6.2f tok/s\n\", \"average ($n):\", $pp_sum / $n, $tg_sum / $n }"
fi
