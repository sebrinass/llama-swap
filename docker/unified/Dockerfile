# Unified multi-stage Dockerfile for AI inference tools
#
# Components - each can be left out of the build via an INCLUDE_* build-arg
# (default 1 = included, i.e. the historical image contents):
#   llama.cpp (CUDA + Vulkan dual backend)  -> INCLUDE_LLAMA
#   audio.cpp                               -> INCLUDE_AUDIOCPP
#   llama-swap binary (image entrypoint)    -> INCLUDE_LLAMA_SWAP
#   vLLM (core)                             -> INCLUDE_VLLM
#   vLLM-Omni (opt-in, OFF)                 -> INCLUDE_VLLM_OMNI
#   vLLM-GGUF-plugin (opt-in, OFF)          -> INCLUDE_VLLM_GGUF
#   SGLang (isolated venv)                  -> INCLUDE_SGLANG
#   Strata (Qwen3.8-Flash-Next engine)      -> INCLUDE_STRATA
#   stable-diffusion.cpp (opt-in, OFF)      -> INCLUDE_SD
#
# The two vLLM add-ons default OFF (opt-in like SD): as of 2026-10-18 no model
# in the live config uses either of them, and vllm-omni's stable releases lag
# vLLM's own versioning (0.30.0 vs 0.31.0 -> RoutedExpertsLists ImportError),
# so shipping them by default only adds breakage surface. They are installed
# in the SAME uv pip install as vLLM on purpose: splitting the install would
# let uv re-resolve shared deps (torch etc.) and break the carefully tuned
# torch/torchaudio cu126 pairing.
#
# Single unified image: CUDA-based runtime, llama.cpp compiled with both
# CUDA and Vulkan backends so the same binary works on NVIDIA, AMD and
# Intel GPUs. vLLM and SGLang run in isolated venvs (CUDA only).
#
# Usage:
#   docker buildx build -t llama-swap:unified-cuda .
#   docker buildx build --build-arg INCLUDE_SGLANG=0 -t llama-swap:unified-cuda .
#   docker buildx build --build-arg CMAKE_CUDA_ARCHITECTURES="86;89" -t llama-swap:unified-cuda .
#
# Disabling a component keeps the image valid: the matching build stage only
# creates placeholder paths (empty /install/bin, empty venvs), so the runtime
# COPY --from lines never fail on missing files. Disabled components are
# reported as "disabled" in /versions.txt and skipped by build-image.sh
# verification.
#
# Each project has its own install script that handles cloning, building,
# and installing binaries. Build stages are independent for cache efficiency.
#
# Compressed image size with every component: ~11 GB. Biggest chunks:
# vLLM venv ~4.7 GB, SGLang venv ~3.8 GB, Strata ~1 GB.

# Component toggles (global scope). Every stage that uses a toggle
# re-declares it below, so a bare `docker buildx build` with no build-args
# still gets all components.
ARG INCLUDE_LLAMA=1
ARG INCLUDE_AUDIOCPP=1
ARG INCLUDE_LLAMA_SWAP=1
ARG INCLUDE_VLLM=1
# vLLM add-ons are opt-in (default 0), like SD: unused by the live config and
# vllm-omni's stable track lags vLLM's versioning.
ARG INCLUDE_VLLM_OMNI=0
ARG INCLUDE_VLLM_GGUF=0
ARG INCLUDE_SGLANG=1
ARG INCLUDE_STRATA=1
# SD is opt-in: default 0 keeps the historical image contents (no SD).
ARG INCLUDE_SD=0

# Builder base (CUDA devel + Vulkan SDK)
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

# Build audio.cpp

FROM builder-base AS audiocpp-build
ARG AUDIOCPP_COMMIT_HASH=main
ARG INCLUDE_AUDIOCPP=1
COPY install-audiocpp.sh /build/
# NOTE: cache id is deliberately bumped (audiocpp-sel) after switching audio.cpp
# back to upstream 0xShug0/audio.cpp@main with AUDIOCPP_DEPLOYMENT_BUILD=ON, so a
# stale build/ dir from the old fork/backend cannot be reused.
RUN --mount=type=cache,id=ccache,target=/ccache \
    --mount=type=cache,id=audiocpp-sel,target=/src/audio.cpp/build \
    if [ "$INCLUDE_AUDIOCPP" = "1" ]; then \
        BACKEND=cuda bash /build/install-audiocpp.sh "${AUDIOCPP_COMMIT_HASH}"; \
    else \
        echo "INCLUDE_AUDIOCPP=0 -> skipping audio.cpp build"; \
        mkdir -p /install/bin /install/share/audiocpp/model_specs; \
    fi

# Build llama.cpp (dual backend: CUDA + Vulkan, slowest build)

FROM builder-base AS llama-build
ARG LLAMA_COMMIT_HASH=master
ARG INCLUDE_LLAMA=1
COPY install-llama.sh /build/
RUN --mount=type=cache,id=ccache,target=/ccache \
    --mount=type=cache,id=llama,target=/src/llama.cpp/build \
    if [ "$INCLUDE_LLAMA" = "1" ]; then \
        bash /build/install-llama.sh "${LLAMA_COMMIT_HASH}"; \
    else \
        echo "INCLUDE_LLAMA=0 -> skipping llama.cpp build"; \
        mkdir -p /install/bin; \
    fi

# Download llama-swap release binary

FROM builder-base AS llama-swap-download
ARG LS_VERSION=latest
ARG INCLUDE_LLAMA_SWAP=1
COPY install-llama-swap.sh /build/
RUN if [ "$INCLUDE_LLAMA_SWAP" = "1" ]; then \
        bash /build/install-llama-swap.sh "${LS_VERSION}"; \
    else \
        echo "INCLUDE_LLAMA_SWAP=0 -> skipping llama-swap download"; \
        mkdir -p /install/bin && echo "disabled" > /install/llama-swap-version; \
    fi

# Install vLLM (CUDA only)
#
# Uses prebuilt wheels via uv — no source compilation needed.
# vLLM's kernels are precompiled; sm_86 (Ampere) is covered by default wheels.

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS vllm-build

ENV DEBIAN_FRONTEND=noninteractive
ARG INCLUDE_VLLM=1
ARG INCLUDE_VLLM_OMNI=0
ARG INCLUDE_VLLM_GGUF=0

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

# Install vLLM (+ optional vLLM-Omni / vLLM-GGUF-plugin) with the CUDA PyTorch wheel.
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
# vllm-omni / vllm-gguf-plugin are opt-in (INCLUDE_VLLM_OMNI /
# INCLUDE_VLLM_GGUF). The optional packages are appended to the SAME install
# via `set --` (the RUN shell is /bin/sh, no arrays) so dependency resolution
# stays in one pass. vllm-gguf-plugin lets vLLM serve GGUF models directly
# (repo:quant or a local .gguf + tokenizer).  Note: GGUF models do NOT support
# fp8 KV cache, so --kv-cache-dtype fp8 must not be used with GGUF models.
#
# INCLUDE_VLLM=0 leaves an empty (but valid) venv behind, so the runtime
# COPY --from below stays a no-op instead of failing.
RUN if [ "$INCLUDE_VLLM" = "1" ]; then \
        set -- "vllm==${VLLM_VERSION}"; \
        if [ "$INCLUDE_VLLM_OMNI" = "1" ]; then \
            set -- "$@" "vllm-omni==${VLLM_OMNI_VERSION}"; \
        fi; \
        if [ "$INCLUDE_VLLM_GGUF" = "1" ]; then \
            set -- "$@" vllm-gguf-plugin; \
        fi; \
        uv pip install "$@" \
            --extra-index-url https://download.pytorch.org/whl/cu126 \
            --index-strategy unsafe-best-match; \
    else \
        echo "INCLUDE_VLLM=0 -> skipping vLLM install (empty venv placeholder)"; \
    fi

# Install SGLang (CUDA only, separate venv)
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
ARG INCLUDE_SGLANG=1

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
#
# INCLUDE_SGLANG=0 leaves an empty (but valid) venv behind (see vllm-build).
RUN if [ "$INCLUDE_SGLANG" = "1" ]; then \
        uv pip install --prerelease=allow "sglang==${SGLANG_VERSION}"; \
    else \
        echo "INCLUDE_SGLANG=0 -> skipping SGLang install (empty venv placeholder)"; \
    fi

# Build Strata: native C++/CUDA engine (sm_86, Tesla A2 pair) + Python venv.
# No torch, no CUDA pip wheels - the engine links this image's CUDA libs, so
# the image delta is ~1 GB (vs ~30 GB for the SGLang venv). Compiled here like
# llama.cpp; the runtime only executes the binary.
FROM builder-base AS strata-build
ARG STRATA_COMMIT_HASH=v0.1.43.1
ARG INCLUDE_STRATA=1
COPY install-strata.sh /build/
# INCLUDE_STRATA=0 skips the apt deps + the whole build and only creates the
# placeholder paths the runtime COPY needs.
RUN if [ "$INCLUDE_STRATA" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            python3.12-venv unzip \
            && rm -rf /var/lib/apt/lists/* \
            && bash /build/install-strata.sh "${STRATA_COMMIT_HASH}"; \
    else \
        echo "INCLUDE_STRATA=0 -> skipping Strata build"; \
        mkdir -p /install/strata/.venv/bin; \
    fi

# Build stable-diffusion.cpp (opt-in via INCLUDE_SD=1, default off).
# Same recipe as install-sd.sh: CUDA build, binaries to /install/bin, shared
# libs to /install/lib (runtime needs ldconfig, done in the strata RUN below).

FROM builder-base AS sd-build
ARG SD_COMMIT_HASH=master
ARG INCLUDE_SD=0
COPY install-sd.sh /build/
RUN if [ "$INCLUDE_SD" = "1" ]; then \
        BACKEND=cuda bash /build/install-sd.sh "${SD_COMMIT_HASH}"; \
    else \
        echo "INCLUDE_SD=0 -> skipping stable-diffusion.cpp build"; \
        mkdir -p /install/bin /install/lib; \
    fi

# Runtime

FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/cuda/bin:/usr/local/bin:${PATH}"

# Component toggles (re-declared from the global scope) + version tracking
# args. Used by the conditional installs, the config post-processing and
# /versions.txt below. Also exported as ENV so apply-config-toggles.py can
# read them (and `docker inspect` shows what the image was built with).
ARG INCLUDE_LLAMA=1
ARG INCLUDE_AUDIOCPP=1
ARG INCLUDE_LLAMA_SWAP=1
ARG INCLUDE_VLLM=1
ARG INCLUDE_VLLM_OMNI=0
ARG INCLUDE_VLLM_GGUF=0
ARG INCLUDE_SGLANG=1
ARG INCLUDE_STRATA=1
ARG INCLUDE_SD=0
ENV INCLUDE_LLAMA=${INCLUDE_LLAMA} \
    INCLUDE_AUDIOCPP=${INCLUDE_AUDIOCPP} \
    INCLUDE_LLAMA_SWAP=${INCLUDE_LLAMA_SWAP} \
    INCLUDE_VLLM=${INCLUDE_VLLM} \
    INCLUDE_VLLM_OMNI=${INCLUDE_VLLM_OMNI} \
    INCLUDE_VLLM_GGUF=${INCLUDE_VLLM_GGUF} \
    INCLUDE_SGLANG=${INCLUDE_SGLANG} \
    INCLUDE_STRATA=${INCLUDE_STRATA} \
    INCLUDE_SD=${INCLUDE_SD}
ARG LLAMA_COMMIT_HASH=unknown
ARG AUDIOCPP_COMMIT_HASH=unknown
ARG STRATA_COMMIT_HASH=v0.1.43.1
ARG SD_COMMIT_HASH=master
ARG RUN_UID=0

# System packages + NVIDIA CUDA toolchain, in ONE apt RUN (used to be four
# separate apt-get update rounds).
#
# libvulkan1 = Vulkan loader; mesa-vulkan-drivers = Intel (ANV) + AMD (RADV)
# user-space Vulkan drivers, so the same llama.cpp dual-backend binary can
# use the Intel iGPU via /dev/dri in addition to NVIDIA via CUDA. Ships
# /usr/share/vulkan/icd.d/intel_icd.json alongside the NVIDIA ICD.
#
# The runtime only owns Intel iGPUs, so the AMD (RADV) user-space driver and
# its ICD manifest are removed to slim the image. Intel (ANV) + lavapipe
# (software) are kept.
#
# CUDA compiler toolchain (nvcc) for FlashInfer JIT
# vLLM's fp8 KV cache (--kv-cache-dtype fp8) relies on FlashInfer, which
# JIT-compiles CUDA kernels at runtime.  That needs nvcc + CUDA headers,
# which the runtime image does not ship.  Add NVIDIA's CUDA apt repo and
# install the CUDA 13.3 toolkit subset.
#   cuda-nvcc-13-3 pulls in cuda-cudart-dev-13-3, libnvvm-13-3,
#   cuda-cudart-13-3 and libnvptxcompiler-13-3 automatically; cuda-driver-dev
#   provides cuda.h for FlashInfer JIT compilation.
#   cuda-cudart-12-8 provides libcudart.so.12, which vLLM 0.27.1's pinned
#   torchaudio==2.11.0 (a CUDA 12 build) needs at import time; the CUDA 13.3
#   runtime image only ships libcudart.so.13.
#
# libatomic1 is only needed by the Strata engine, so it is guarded by
# INCLUDE_STRATA.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 python3 python3.12-dev gcc curl ca-certificates ffmpeg \
    libvulkan1 mesa-vulkan-drivers \
    python3-numpy python3-sentencepiece python3-pip \
    espeak-ng \
    && rm -f /usr/lib/x86_64-linux-gnu/libvulkan_radeon.so \
    && rm -f /usr/share/vulkan/icd.d/radeon_icd.json \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-nvcc-13-3 cuda-driver-dev-13-3 cuda-cudart-12-8 \
    && if [ "$INCLUDE_STRATA" = "1" ]; then \
           apt-get install -y --no-install-recommends libatomic1; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# CUDA stub drivers for container compatibility
COPY --from=builder-base /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so
COPY --from=builder-base /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1

# NCCL library (built against libnccl-dev in builder, need it at runtime)
COPY --from=builder-base /usr/lib/x86_64-linux-gnu/libnccl.so.2 /usr/lib/x86_64-linux-gnu/libnccl.so.2

# Create non-root user when RUN_UID != 0
RUN if [ "$RUN_UID" != "0" ]; then \
      groupadd --system --gid $RUN_UID llama-swap && \
      useradd --system --uid $RUN_UID --gid $RUN_UID \
        --home /app --shell /sbin/nologin llama-swap; \
    fi && \
    mkdir -p /etc/llama-swap/config && \
    chown -R ${RUN_UID}:${RUN_UID} /etc/llama-swap

WORKDIR /app

# Copy audio.cpp binaries + the model_specs catalog too, so audiocpp_cli/server
# can resolve model contracts from disk (the runtime searches for
# model_specs/<family>.json), independent of the deployment-build embedded
# fallback.
# Directory-CONTENTS copy (trailing slash): a disabled stage leaves
# /install/bin empty, which copies nothing instead of failing on the missing
# per-file sources.
COPY --from=audiocpp-build /install/bin/ /usr/local/bin/
COPY --from=audiocpp-build /install/share/audiocpp/ /usr/local/share/audiocpp/

# Copy llama.cpp binaries (statically linked, CUDA + Vulkan dual backend)
COPY --from=llama-build /install/bin/ /usr/local/bin/

# Install uv
RUN pip install uv --break-system-packages

# Copy llama-swap binary
COPY --from=llama-swap-download /install/bin/ /usr/local/bin/
COPY --from=llama-swap-download /install/llama-swap-version /tmp/

# Copy vLLM + vLLM-Omni venv (empty placeholder venv when INCLUDE_VLLM=0)
COPY --from=vllm-build /opt/vllm-venv /opt/vllm-venv
ENV PATH="/opt/vllm-venv/bin:${PATH}"
ENV CUDA_HOME="/usr/local/cuda"

# Copy SGLang venv (empty placeholder venv when INCLUDE_SGLANG=0)
COPY --from=sglang-build /opt/sglang-venv /opt/sglang-venv

# SGLang's flashinfer JIT-compiles kernels at runtime (e.g. the sampling
# kernel) and needs CUDA's full curand headers.  /usr/local/cuda/include/
# ships only a trimmed set.  nvidia-cu13 (a flashinfer dependency inside the
# venvs) bundles the complete curand*.h, so copy those over.
# Try BOTH venvs: a vLLM-only build (INCLUDE_SGLANG=0) used to end up with no
# curand headers at all, because the source was the sglang venv only.
# Guarded: if the path is absent (package-layout change) skip rather than fail.
RUN mkdir -p /usr/local/cuda/include && \
    for venv in /opt/vllm-venv /opt/sglang-venv; do \
        if [ -d "$venv/lib/python3.12/site-packages/nvidia/cu13/include" ]; then \
            cp "$venv/lib/python3.12/site-packages/nvidia/cu13/include/curand"*.h \
               /usr/local/cuda/include/ 2>/dev/null || true; \
        fi; \
    done && \
    echo "curand headers: $(ls /usr/local/cuda/include/curand*.h 2>/dev/null | wc -l)"

# Copy Strata (engine + venv + serve tree) built for sm_86, plus the one-time
# model-prep helper. The engine links this image's CUDA libs; libatomic1 is
# the only runtime lib the base image lacks (installed above when
# INCLUDE_STRATA=1). ldconfig picks up the freshly copied libnccl/stub/SD libs.
COPY --from=strata-build /install/strata /opt/strata
COPY strata-first-setup.sh /opt/strata/first-setup.sh

# Copy stable-diffusion.cpp binaries + shared libs (only when INCLUDE_SD=1;
# otherwise both source dirs are empty placeholders and these are no-ops).
COPY --from=sd-build /install/bin/ /usr/local/bin/
COPY --from=sd-build /install/lib/ /usr/local/lib/

RUN chmod +x /opt/strata/first-setup.sh && ldconfig
ENV PATH="/opt/strata/.venv/bin:${PATH}"

# Bake the default config, then comment out the entries whose component was
# left out of the build (a config referencing a binary the image does not
# ship would fail when llama-swap tries to spawn that model).
COPY config.example.yaml apply-config-toggles.py /tmp/
RUN cp /tmp/config.example.yaml /etc/llama-swap/config/config.yaml && \
    python3 /tmp/apply-config-toggles.py /etc/llama-swap/config/config.yaml && \
    rm -f /tmp/config.example.yaml /tmp/apply-config-toggles.py

# Version tracking (disabled components are reported as "disabled")
RUN echo "llama.cpp: ${LLAMA_COMMIT_HASH}" > /versions.txt && \
    echo "audio.cpp: ${AUDIOCPP_COMMIT_HASH}" >> /versions.txt && \
    echo "llama-swap: $(cat /tmp/llama-swap-version)" >> /versions.txt && \
    echo "cuda_version: 13.3.0" >> /versions.txt && \
    if [ "$INCLUDE_VLLM" = "1" ]; then \
        echo "vllm: $(/opt/vllm-venv/bin/python -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt; \
        if [ "$INCLUDE_VLLM_OMNI" = "1" ]; then \
            echo "vllm-omni: $(/opt/vllm-venv/bin/python -c 'import vllm_omni; print(vllm_omni.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt; \
        else \
            echo "vllm-omni: disabled (INCLUDE_VLLM_OMNI=0)" >> /versions.txt; \
        fi; \
        if [ "$INCLUDE_VLLM_GGUF" = "1" ]; then \
            echo "vllm-gguf-plugin: $(/opt/vllm-venv/bin/python -c 'import importlib.metadata as m; print(m.version("vllm-gguf-plugin"))' 2>/dev/null || echo 'installed')" >> /versions.txt; \
        else \
            echo "vllm-gguf-plugin: disabled (INCLUDE_VLLM_GGUF=0)" >> /versions.txt; \
        fi; \
    else \
        echo "vllm: disabled (INCLUDE_VLLM=0)" >> /versions.txt; \
        echo "vllm-omni: disabled (INCLUDE_VLLM=0)" >> /versions.txt; \
        echo "vllm-gguf-plugin: disabled (INCLUDE_VLLM=0)" >> /versions.txt; \
    fi && \
    if [ "$INCLUDE_SGLANG" = "1" ]; then \
        echo "sglang: $(/opt/sglang-venv/bin/python -c 'import sglang; print(sglang.__version__)' 2>/dev/null || echo 'installed')" >> /versions.txt; \
    else \
        echo "sglang: disabled (INCLUDE_SGLANG=0)" >> /versions.txt; \
    fi && \
    if [ "$INCLUDE_STRATA" = "1" ]; then \
        echo "strata: ${STRATA_COMMIT_HASH} (engine arch ${CMAKE_CUDA_ARCHITECTURES:-86})" >> /versions.txt; \
    else \
        echo "strata: disabled (INCLUDE_STRATA=0)" >> /versions.txt; \
    fi && \
    if [ "$INCLUDE_SD" = "1" ]; then \
        echo "stable-diffusion: ${SD_COMMIT_HASH}" >> /versions.txt; \
    else \
        echo "stable-diffusion: disabled (INCLUDE_SD=0)" >> /versions.txt; \
    fi && \
    echo "build_timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /versions.txt

RUN mkdir -p /models && chown ${RUN_UID}:${RUN_UID} /models && \
    chmod -R a+rX /opt/vllm-venv /opt/sglang-venv /opt/strata
WORKDIR /models
USER ${RUN_UID}
ENTRYPOINT ["llama-swap"]
CMD ["-config", "/etc/llama-swap/config/config.yaml", "-listen", "0.0.0.0:8080"]

# Build-time guard (second line of defense behind build-image.sh's
# verification). This is the LAST stage, so `-t` tags land here; it is
# `FROM runtime`, so the tagged image content is identical plus one thin
# check layer. Because the stage is part of the default build graph, a
# missing required binary FAILS THE BUILD ITSELF — with buildx --push,
# nothing is pushed unless this passes. This is the guard that would have
# prevented the 2026-10-19 empty-shell image from reaching the tracked tag.
# NOTE: keep the checks in sync with EXPECTED_BINARIES in build-image.sh.
FROM runtime AS verify
ARG INCLUDE_LLAMA=1
ARG INCLUDE_AUDIOCPP=1
ARG INCLUDE_LLAMA_SWAP=1
ARG INCLUDE_VLLM=1
RUN set -e; \
    if [ "$INCLUDE_LLAMA_SWAP" = "1" ]; then \
        command -v llama-swap >/dev/null || { echo "verify: llama-swap MISSING" >&2; exit 1; }; \
    fi; \
    if [ "$INCLUDE_LLAMA" = "1" ]; then \
        command -v llama-server >/dev/null || { echo "verify: llama-server MISSING" >&2; exit 1; }; \
        command -v llama-cli >/dev/null || { echo "verify: llama-cli MISSING" >&2; exit 1; }; \
    fi; \
    if [ "$INCLUDE_AUDIOCPP" = "1" ]; then \
        command -v audiocpp_server >/dev/null || { echo "verify: audiocpp_server MISSING" >&2; exit 1; }; \
        command -v audiocpp_cli >/dev/null || { echo "verify: audiocpp_cli MISSING" >&2; exit 1; }; \
    fi; \
    if [ "$INCLUDE_VLLM" = "1" ]; then \
        command -v vllm >/dev/null || { echo "verify: vllm MISSING" >&2; exit 1; }; \
    fi; \
    echo "verify: all required binaries present"
