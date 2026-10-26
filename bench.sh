#!/bin/sh
# Benchmark the running llama-server with models/bench-prompt.json (see README).
#
# Usage: ./bench.sh [runs]
#   runs  number of requests (default 3). The first is a warm-up and isn't counted in the average.
#         Runs that generated fewer tokens than the prompt's n_predict are flagged and not counted either.
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

line() {
    awk "BEGIN { printf \"%-16s prefill %7.1f tok/s   generation %6.2f tok/s%s\n\", \"$1\", $2, $3, \"$4\" }"
}

expected=$(docker exec "$CONTAINER" cat "$PROMPT" | sed -n 's/.*"n_predict": *\([0-9]*\).*/\1/p')

pp_sum=0
tg_sum=0
counted=0
i=1
while [ "$i" -le "$RUNS" ]; do
    # $LLAMA_API_KEY is expanded inside the container, $PROMPT here.
    timings=$(docker exec "$CONTAINER" sh -c \
        "curl -sf localhost:8080/completion -H \"Authorization: Bearer \$LLAMA_API_KEY\" -H 'Content-Type: application/json' -d @$PROMPT" \
        | grep -o '"timings":{[^}]*}') || { echo "run $i: request failed" >&2; exit 1; }

    pp=$(field "$timings" prompt_per_second)
    tg=$(field "$timings" predicted_per_second)
    generated=$(field "$timings" predicted_n)
    generated=${generated:-0}
    label="run $i:"
    note=""
    if [ "$i" -eq 1 ]; then
        label="run 1 (warm-up):"
        echo "prompt: $(field "$timings" prompt_n) tokens, generated: $generated tokens"
    elif [ -n "$expected" ] && [ "$generated" -lt "$expected" ]; then
        note="   <- only $generated of $expected tokens, not counted"
    else
        pp_sum=$(awk "BEGIN { print $pp_sum + $pp }")
        tg_sum=$(awk "BEGIN { print $tg_sum + $tg }")
        counted=$((counted + 1))
    fi
    line "$label" "$pp" "${tg:-0}" "$note"
    i=$((i + 1))
done

if [ "$counted" -gt 0 ]; then
    line "average ($counted):" "$pp_sum / $counted" "$tg_sum / $counted" ""
elif [ "$RUNS" -gt 1 ]; then
    echo "no complete runs to average; add \"ignore_eos\": true to the prompt (see README)" >&2
    exit 1
fi
