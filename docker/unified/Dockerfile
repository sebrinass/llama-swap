# Unified multi-stage Dockerfile for AI inference tools
# Components: llama.cpp (CUDA + Vulkan dual backend), audio.cpp,
#             vLLM + vLLM-Omni + vLLM-GGUF-Plugin, SGLang
#
# Single unified image: CUDA-based runtime, llama.cpp compiled with both
# CUDA and Vulkan backends so the same binary works on NVIDIA, AMD and
# Intel GPUs. vLLM and SGLang run in isolated venvs (CUDA only).
#
# Usage:
#   docker buildx build -t llama-swap:unified-cuda .
#   docker buildx build --build-arg CMAKE_CUDA_ARCHITECTURES="86;89" -t llama-swap:unified-cuda .
#
# Each project has its own install script that handles cloning, building,
# and installing binaries. Build stages are independent for cache efficiency.

# ── Builder base (CUDA devel + Vulkan SDK) ───────────────────────────
# A single builder image that carries both the CUDA toolchain and the
# Vulkan SDK, so llama.cpp can be compiled with GGML_CUDA + GGML_VULKAN
# enabled at the same time (dual backend).

FROM nvidia/cuda:13.3.0-devel-ubuntu24.04 AS builder-base

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
    libvulkan-dev glslang-tools spirv-tools vulkan-validationlayers glslc \
    spirv-headers \
    && rm -rf /var/lib/apt/lists/*

# audio.cpp and llama.cpp builds require gcc-14
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

WORKDIR /build

# ── Build audio.cpp ────────────────────────────────────────────────────

FROM builder-base AS audiocpp-build
ARG AUDIOCPP_COMMIT_HASH=release-0.1
COPY install-audiocpp.sh /build/
RUN --mount=type=cache,id=ccache,target=/ccache \
    --mount=type=cache,id=audiocpp,target=/src/audio.cpp/build \
    BACKEND=cuda bash /build/install-audiocpp.sh "${AUDIOCPP_COMMIT_HASH}"

# ── Build llama.cpp (dual backend: CUDA + Vulkan, slowest build) ─────

FROM builder-base AS llama-build
ARG LLAMA_COMMIT_HASH=master
COPY install-llama.sh /build/
RUN --mount=type=cache,id=ccache,target=/ccache \
    --mount=type=cache,id=llama,target=/src/llama.cpp/build \
    bash /build/install-llama.sh "${LLAMA_COMMIT_HASH}"

# ── Download llama-swap release binary ────────────────────────────────

FROM builder-base AS llama-swap-download
ARG LS_VERSION=latest
COPY install-llama-swap.sh /build/
RUN bash /build/install-llama-swap.sh "${LS_VERSION}"

# ── Install vLLM + vLLM-Omni (CUDA only) ──────────────────────────────
#
# Uses prebuilt wheels via uv — no source compilation needed.
# vLLM's kernels are precompiled; sm_86 (Ampere) is covered by default wheels.

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS vllm-build

ENV DEBIAN_FRONTEND=noninteractive

# gcc + python3.12-dev are required for Triton JIT kernel compilation at
# runtime (e.g. cuda_utils.cu needs Python.h; triton needs a C compiler).
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    gcc curl ca-certificates \
    espeak-ng ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages uv

RUN uv venv /opt/vllm-venv --python 3.12 --seed
ENV PATH="/opt/vllm-venv/bin:${PATH}"
ENV CUDA_HOME="/usr/local/cuda"

# vLLM / vLLM-Omni versions are injected as build-args by build-image.sh,
# which resolves the latest version from PyPI at build time. Pinning the
# version string (instead of a bare `vllm`) forces BuildKit to re-run this
# layer whenever the version changes, avoiding stale registry-cache hits.
ARG VLLM_VERSION=latest
ARG VLLM_OMNI_VERSION=latest

# Install vLLM + vLLM-Omni + vLLM-GGUF-plugin with the CUDA PyTorch wheel.
#
# All packages are installed in a single uv pip install so uv resolves all
# constraints together, avoiding conflicts that arise when installing them
# separately (the second install can upgrade/downgrade shared deps).
#
# vLLM 0.27+ pins torch==2.13.0 AND torchaudio==2.11.0.  The PyPI torch 2.13.0
# wheel is a cu13 build, but torchaudio 2.11.0 only ships as a CUDA 12 build;
# installing both from PyPI makes torchaudio's _check_cuda_version() fail
# ("PyTorch has CUDA 13.0 whereas TorchAudio has 12.8").  The matching pair
# exists on the cu126 index as torch==2.13.0+cu126 / torchaudio==2.11.0+cu126
# (both CUDA 12.6).  Pointing --extra-index-url at cu126 + unsafe-best-match
# makes uv prefer those local builds for torch/torchaudio/torchvision/torchcodec
# while still resolving torchcodec>=0.14 and flashinfer correctly.
#
# --torch-backend=auto must NOT be used: uv reads CUDA_HOME and can fall back
# to a CPU-only torch build, which breaks `import vllm`.
#
# vllm-gguf-plugin lets vLLM serve GGUF models directly (repo:quant or a
# local .gguf + tokenizer).  Note: GGUF models do NOT support fp8 KV cache,
# so --kv-cache-dtype fp8 must not be used with GGUF models.
RUN uv pip install "vllm==${VLLM_VERSION}" "vllm-omni==${VLLM_OMNI_VERSION}" \
    vllm-gguf-plugin \
    --extra-index-url https://download.pytorch.org/whl/cu126 \
    --index-strategy unsafe-best-match

# ── Install SGLang (CUDA only, separate venv) ─────────────────────────
#
# SGLang is kept in its own venv because its torch/numba pins conflict with
# vLLM's (vLLM 0.27 needs torch==2.13.0 + numba==0.65.0, SGLang 0.5.17 needs
# torch==2.11.0 + numba==0.65.1).  Isolated venvs let both coexist.
#
# SGLANG_VERSION is injected as a build-arg by build-image.sh, resolved to the
# latest PyPI release at build time (same "not locked" pattern as vLLM), so a
# new upstream release automatically triggers a rebuild.

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS sglang-build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    gcc curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages uv

RUN uv venv /opt/sglang-venv --python 3.12 --seed
ENV PATH="/opt/sglang-venv/bin:${PATH}"
ENV CUDA_HOME="/usr/local/cuda"

ARG SGLANG_VERSION=latest

# SGLang is installed from the default PyPI index only. SGLang 0.5.x pins
# torch/torchaudio/torchcodec and needs cuda-python>=13.0, matching the
# CUDA 13 torch family (torch 2.11.0 + torchvision 0.26.0) that plain PyPI
# ships. Pointing at the cu126 extra index would pull a CUDA 12.6 torchvision
# while torch stays CUDA 13 -> RuntimeError at import (torchvision
# _check_cuda_version). Keeping sglang unpinned follows the same "not locked"
# pattern as vllm: a new upstream release automatically triggers a rebuild.
RUN uv pip install --prerelease=allow "sglang==${SGLANG_VERSION}"

# ── Runtime ───────────────────────────────────────────────────────────

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/cuda/bin:/usr/local/bin:${PATH}"

# libvulkan1 = Vulkan loader; mesa-vulkan-drivers = Intel (ANV) + AMD (RADV)
# user-space Vulkan drivers, so the same llama.cpp dual-backend binary can
# use the Intel iGPU via /dev/dri in addition to NVIDIA via CUDA. Ships
# /usr/share/vulkan/icd.d/intel_icd.json alongside the NVIDIA ICD.
#
# The runtime only owns Intel iGPUs, so the AMD (RADV) user-space driver and
# its ICD manifest are removed to slim the image. Intel (ANV) + lavapipe
# (software) are kept.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 python3 python3.12-dev gcc curl ca-certificates ffmpeg \
    libvulkan1 mesa-vulkan-drivers \
    && rm -f /usr/lib/x86_64-linux-gnu/libvulkan_radeon.so \
    && rm -f /usr/share/vulkan/icd.d/radv_icd.json \
    && rm -rf /var/lib/apt/lists/*

# ── CUDA compiler toolchain (nvcc) for FlashInfer JIT ─────────────────
# vLLM's fp8 KV cache (--kv-cache-dtype fp8) relies on FlashInfer, which
# JIT-compiles CUDA kernels at runtime.  That needs nvcc + CUDA headers,
# which the runtime image does not ship.  Add NVIDIA's CUDA apt repo and
# install the CUDA 13.3 toolkit subset.
#   cuda-nvcc-13-3 pulls in cuda-cudart-dev-13-3, libnvvm-13-3,
#   cuda-crt-13-3 and libnvptxcompiler-13-3 automatically; cuda-driver-dev
#   provides cuda.h for FlashInfer JIT compilation.
#   cuda-cudart-12-8 provides libcudart.so.12, which vLLM 0.27.1's pinned
#   torchaudio==2.11.0 (a CUDA 12 build) needs at import time; the CUDA 13.3
#   runtime image only ships libcudart.so.13.
RUN curl -fsSL -o /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-nvcc-13-3 cuda-driver-dev-13-3 cuda-cudart-12-8 \
    && rm -rf /var/lib/apt/lists/*

# CUDA stub drivers for container compatibility
COPY --from=builder-base /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so
COPY --from=builder-base /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1

# NCCL library (built against libnccl-dev in builder, need it at runtime)
COPY --from=builder-base /usr/lib/x86_64-linux-gnu/libnccl.so.2 /usr/lib/x86_64-linux-gnu/libnccl.so.2

ARG LLAMA_COMMIT_HASH=unknown
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

# Copy audio.cpp binaries
COPY --from=audiocpp-build /install/bin/audiocpp_server /usr/local/bin/
COPY --from=audiocpp-build /install/bin/audiocpp_cli /usr/local/bin/

# Copy llama.cpp binaries (statically linked, CUDA + Vulkan dual backend)
COPY --from=llama-build /install/bin/llama-server /usr/local/bin/
COPY --from=llama-build /install/bin/llama-cli /usr/local/bin/
COPY --from=llama-build /install/bin/llama-tts /usr/local/bin/

# Install uv
RUN pip install uv --break-system-packages

# Copy llama-swap binary
COPY --from=llama-swap-download /install/bin/llama-swap /usr/local/bin/
COPY --from=llama-swap-download /install/llama-swap-version /tmp/

# Copy vLLM + vLLM-Omni venv
COPY --from=vllm-build /opt/vllm-venv /opt/vllm-venv
ENV PATH="/opt/vllm-venv/bin:${PATH}"
ENV CUDA_HOME="/usr/local/cuda"

# Copy SGLang venv
COPY --from=sglang-build /opt/sglang-venv /opt/sglang-venv

RUN ldconfig

COPY config.example.yaml /etc/llama-swap/config/config.yaml

# Version tracking
RUN echo "llama.cpp: ${LLAMA_COMMIT_HASH}" > /versions.txt && \
    echo "audio.cpp: ${AUDIOCPP_COMMIT_HASH}" >> /versions.txt && \
    echo "llama-swap: $(cat /tmp/llama-swap-version)" >> /versions.txt && \
    echo "cuda_version: 13.3.0" >> /versions.txt && \
    echo "vllm: $(/opt/vllm-venv/bin/python -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt && \
    echo "vllm-omni: $(/opt/vllm-venv/bin/python -c 'import vllm_omni; print(vllm_omni.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt && \
    echo "sglang: $(/opt/sglang-venv/bin/python -c 'import sglang; print(sglang.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt && \
    echo "build_timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /versions.txt

RUN mkdir -p /models && chown ${RUN_UID}:${RUN_UID} /models && \
    chmod -R a+rX /opt/vllm-venv /opt/sglang-venv
WORKDIR /models
USER ${RUN_UID}
ENTRYPOINT ["llama-swap"]
CMD ["-config", "/etc/llama-swap/config/config.yaml", "-listen", "0.0.0.0:8080"]
