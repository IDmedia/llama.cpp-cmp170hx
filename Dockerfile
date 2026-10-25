# llama-server built for the NVIDIA CMP 170HX (GA100, sm_80).
#
# Differences from upstream's ghcr.io/ggml-org/llama.cpp:server-cuda:
#   - --fmad=false: the CMP 170HX throttles fused multiply-add (FFMA). Without it nvcc emits separate
#     MUL + ADD, which the card runs at near full speed (~1.35x prompt and decode on CMP cards).
#   - Only sm_80 is compiled: faster build, smaller image.
#   - No NCCL: only needed for --split-mode row/tensor, which is a bad idea over PCIe Gen2 x8 anyway.
# CPU code is built for all x86 variants and picked at runtime (GGML_BACKEND_DL), since CI doesn't
# build on the host that runs it.
#
# UPSTREAM_REF is set by the upstream-release-build CI template (an llama.cpp release tag).

ARG CUDA_VERSION=12.9.1
ARG UBUNTU_VERSION=24.04

# --- source + web UI assets (llama-server embeds the UI) ---
FROM docker.io/node:24 AS src
ARG UPSTREAM_REF=master
RUN git clone --depth 1 --branch "${UPSTREAM_REF}" https://github.com/ggml-org/llama.cpp /src
WORKDIR /src/tools/ui
RUN npm ci && npm run build

# --- build ---
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential cmake git libssl-dev libgomp1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=src /src /src
WORKDIR /src
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_NCCL=OFF \
        -DCMAKE_CUDA_ARCHITECTURES=80 \
        -DCMAKE_CUDA_FLAGS="--fmad=false" \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
    && cmake --build build --config Release -j"$(nproc)" \
    && mkdir -p /out \
    && cp build/bin/llama-server /out/ \
    && find build -name "*.so*" -exec cp -P {} /out/ \;

# --- runtime ---
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 curl openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /app/
ENV LD_LIBRARY_PATH=/app
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080
WORKDIR /app
HEALTHCHECK --interval=30s --timeout=5s --start-period=15m CMD ["curl", "-f", "http://localhost:8080/health"]
ENTRYPOINT ["/app/llama-server"]
