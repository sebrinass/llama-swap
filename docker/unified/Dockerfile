# Unified multi-stage Dockerfile for AI inference tools
# Components: llama.cpp, stable-diffusion.cpp, audio.cpp, vLLM + vLLM-Omni
# Supports CUDA and Vulkan backends via BACKEND build arg
# vLLM + vLLM-Omni are CUDA-only (not available in Vulkan builds)
#
# Usage:
#   docker buildx build --build-arg BACKEND=cuda -t llama-swap:unified-cuda .
#   docker buildx build --build-arg BACKEND=vulkan -t llama-swap:unified-vulkan .
#   docker buildx build --build-arg BACKEND=cuda --build-arg CMAKE_CUDA_ARCHITECTURES="86;89" -t llama-swap:unified-cuda .
#
# Each project has its own install script that handles cloning, building,
# and installing binaries. Build stages are independent for cache efficiency.

ARG BACKEND=cuda

# ── Builder bases ──────────────────────────────────────────────────────

FROM nvidia/cuda:13.3.0-devel-ubuntu24.04 AS builder-base-cuda

ARG CMAKE_CUDA_ARCHITECTURES="86"
ENV DEBIAN_FRONTEND=noninteractive
ENV CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES}
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=2G
ENV PATH="/usr/lib/ccache:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git python3 python3-pip libssl-dev \
    curl ca-certificates ccache make wget \
    gcc-14 g++-14 \
    libnccl-dev \
    && rm -rf /var/lib/apt/lists/*

# audio.cpp requires gcc-14
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

WORKDIR /build

# ──

FROM ubuntu:24.04 AS builder-base-vulkan

ENV DEBIAN_FRONTEND=noninteractive
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=2G
ENV PATH="/usr/lib/ccache:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git python3 python3-pip libssl-dev \
    curl ca-certificates ccache make wget software-properties-common \
    libvulkan-dev glslang-tools spirv-tools vulkan-validationlayers glslc \
    spirv-headers \
    gcc-14 g++-14 \
    && rm -rf /var/lib/apt/lists/*

# audio.cpp requires gcc-14
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

WORKDIR /build

# ── Select builder base by BACKEND ────────────────────────────────────

FROM builder-base-${BACKEND} AS builder-base

# ── Build stable-diffusion.cpp ────────────────────────────────────────

FROM builder-base AS sd-build
ARG BACKEND=cuda
ARG SD_COMMIT_HASH=master
COPY install-sd.sh /build/
RUN --mount=type=cache,id=ccache-${BACKEND},target=/ccache \
    --mount=type=cache,id=sd-${BACKEND},target=/src/stable-diffusion.cpp/build \
    BACKEND=${BACKEND} bash /build/install-sd.sh "${SD_COMMIT_HASH}"

# ── Build audio.cpp ────────────────────────────────────────────────────

FROM builder-base AS audiocpp-build
ARG BACKEND=cuda
ARG AUDIOCPP_COMMIT_HASH=release-0.1
COPY install-audiocpp.sh /build/
RUN --mount=type=cache,id=ccache-${BACKEND},target=/ccache \
    --mount=type=cache,id=audiocpp-${BACKEND},target=/src/audio.cpp/build \
    BACKEND=${BACKEND} bash /build/install-audiocpp.sh "${AUDIOCPP_COMMIT_HASH}"

# ── Build llama.cpp (slowest build, run last) ─────────────────────────

FROM builder-base AS llama-build
ARG BACKEND=cuda
ARG LLAMA_COMMIT_HASH=master
COPY install-llama.sh /build/
RUN --mount=type=cache,id=ccache-${BACKEND},target=/ccache \
    --mount=type=cache,id=llama-${BACKEND},target=/src/llama.cpp/build \
    BACKEND=${BACKEND} bash /build/install-llama.sh "${LLAMA_COMMIT_HASH}"

# ── Download llama-swap release binary ────────────────────────────────

FROM builder-base AS llama-swap-download
ARG LS_VERSION=latest
COPY install-llama-swap.sh /build/
RUN bash /build/install-llama-swap.sh "${LS_VERSION}"

# ── Install vLLM + vLLM-Omni (CUDA only) ──────────────────────────────
#
# Uses prebuilt wheels via uv — no source compilation needed.
# vLLM's kernels are precompiled; sm_86 (Ampere) is covered by default wheels.
# Two named stages allow ARG BACKEND to select at build time:
#   - vllm-cuda  : real install (from nvidia/cuda:13.3.0-runtime)
#   - vllm-vulkan: no-op (empty venv, skips vLLM entirely)

FROM ubuntu:24.04 AS vllm-vulkan
RUN mkdir -p /opt/vllm-venv/bin

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS vllm-cuda

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3-pip curl ca-certificates \
    espeak-ng ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages uv

RUN uv venv /opt/vllm-venv --python 3.12 --seed
ENV PATH="/opt/vllm-venv/bin:${PATH}"
ENV CUDA_HOME="/usr/local/cuda"
ENV VLLM_USE_V1=1

# Install vLLM (auto-detects CUDA 13.x from CUDA_HOME)
RUN uv pip install vllm --torch-backend=auto

# Install vLLM-Omni (multimodal extension: Qwen3-Omni, Qwen2.5-Omni, etc.)
RUN uv pip install vllm-omni

ARG BACKEND=cuda
FROM vllm-${BACKEND} AS vllm-build

# ── Runtime bases ─────────────────────────────────────────────────────

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS runtime-cuda

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 python3 curl ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# CUDA stub drivers for container compatibility
COPY --from=builder-base-cuda /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so
COPY --from=builder-base-cuda /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1

# NCCL library (built against libnccl-dev in builder, need it at runtime)
COPY --from=builder-base-cuda /usr/lib/x86_64-linux-gnu/libnccl.so.2 /usr/lib/x86_64-linux-gnu/libnccl.so.2

# ──

FROM ubuntu:24.04 AS runtime-vulkan

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 libvulkan1 mesa-vulkan-drivers \
    python3 curl ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# ── Select runtime base by BACKEND ────────────────────────────────────

FROM runtime-${BACKEND} AS runtime

ARG BACKEND=cuda
ARG LLAMA_COMMIT_HASH=unknown
ARG SD_COMMIT_HASH=unknown
ARG AUDIOCPP_COMMIT_HASH=unknown
ARG RUN_UID=0

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-numpy python3-sentencepiece python3-pip \
    espeak-ng \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user when RUN_UID != 0
RUN if [ "$RUN_UID" != "0" ]; then \
      groupadd --system --gid $RUN_UID llama-swap && \
      useradd --system --uid $RUN_UID --gid $RUN_UID \
        --home /app --shell /sbin/nologin llama-swap; \
    fi && \
    mkdir -p /etc/llama-swap/config && \
    chown -R ${RUN_UID}:${RUN_UID} /etc/llama-swap

WORKDIR /app

# Copy stable-diffusion.cpp binaries and libraries
COPY --from=sd-build /install/bin/sd-server /usr/local/bin/
COPY --from=sd-build /install/bin/sd-cli /usr/local/bin/
COPY --from=sd-build /install/lib/ /usr/local/lib/

# Copy audio.cpp binaries
COPY --from=audiocpp-build /install/bin/audiocpp_server /usr/local/bin/
COPY --from=audiocpp-build /install/bin/audiocpp_cli /usr/local/bin/

# Copy llama.cpp binaries (statically linked)
COPY --from=llama-build /install/bin/llama-server /usr/local/bin/
COPY --from=llama-build /install/bin/llama-cli /usr/local/bin/
COPY --from=llama-build /install/bin/llama-tts /usr/local/bin/

# Install uv
RUN pip install uv --break-system-packages

# Copy llama-swap binary
COPY --from=llama-swap-download /install/bin/llama-swap /usr/local/bin/
COPY --from=llama-swap-download /install/llama-swap-version /tmp/

# Copy vLLM + vLLM-Omni venv (CUDA only; empty for Vulkan)
COPY --from=vllm-build /opt/vllm-venv /opt/vllm-venv
ENV PATH="/opt/vllm-venv/bin:${PATH}"
ENV VLLM_USE_V1=1
ENV CUDA_HOME="/usr/local/cuda"

RUN ldconfig

COPY config.example.yaml /etc/llama-swap/config/config.yaml

# Version tracking
RUN echo "llama.cpp: ${LLAMA_COMMIT_HASH}" > /versions.txt && \
    echo "stable-diffusion.cpp: ${SD_COMMIT_HASH}" >> /versions.txt && \
    echo "audio.cpp: ${AUDIOCPP_COMMIT_HASH}" >> /versions.txt && \
    echo "llama-swap: $(cat /tmp/llama-swap-version)" >> /versions.txt && \
    echo "backend: ${BACKEND}" >> /versions.txt && \
    echo "cuda_version: 13.3.0" >> /versions.txt && \
    if [ -f /opt/vllm-venv/bin/vllm ]; then \
      echo "vllm: $(/opt/vllm-venv/bin/python -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt && \
      echo "vllm-omni: $(/opt/vllm-venv/bin/python -c 'import vllm_omni; print(vllm_omni.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt; \
    else \
      echo "vllm: skipped (vulkan build)" >> /versions.txt && \
      echo "vllm-omni: skipped (vulkan build)" >> /versions.txt; \
    fi && \
    echo "build_timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /versions.txt

RUN mkdir -p /models && chown ${RUN_UID}:${RUN_UID} /models && \
    chmod -R a+rX /opt/vllm-venv
WORKDIR /models
USER ${RUN_UID}
ENTRYPOINT ["llama-swap"]
CMD ["-config", "/etc/llama-swap/config/config.yaml", "-listen", "0.0.0.0:8080"]
