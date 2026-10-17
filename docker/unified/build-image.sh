#!/bin/bash
#
# Build script for unified container with version pinning
#
# Usage:
#   ./build-image.sh --cuda                              # Build CUDA image
#   ./build-image.sh --cuda --no-cache                   # Build without cache
#   LLAMA_REF=b1234 ./build-image.sh --cuda             # Pin llama.cpp to a commit hash
#   LLAMA_REF=v1.2.3 ./build-image.sh --cuda            # Pin llama.cpp to a tag
#   AUDIOCPP_REF=main ./build-image.sh --cuda           # Pin audio.cpp to a branch
#   LS_VERSION=170 ./build-image.sh --cuda              # Override llama-swap version
#

set -euo pipefail

BACKEND="cuda"
NO_CACHE=false

# Component toggles: 1 = build into the image, 0 = skip.
# Defaults keep every component in (historical image contents). The matching
# INCLUDE_* env vars seed the defaults, CLI flags override them.
INCLUDE_LLAMA="${INCLUDE_LLAMA:-1}"
INCLUDE_AUDIOCPP="${INCLUDE_AUDIOCPP:-1}"
INCLUDE_LLAMA_SWAP="${INCLUDE_LLAMA_SWAP:-1}"
INCLUDE_VLLM="${INCLUDE_VLLM:-1}"
INCLUDE_SGLANG="${INCLUDE_SGLANG:-1}"
INCLUDE_STRATA="${INCLUDE_STRATA:-1}"
# SD is opt-in (default off): nothing is built unless explicitly requested.
INCLUDE_SD="${INCLUDE_SD:-0}"

for arg in "$@"; do
    case $arg in
        --cuda)
            BACKEND="cuda"
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --no-llama)
            INCLUDE_LLAMA=0
            ;;
        --no-audiocpp)
            INCLUDE_AUDIOCPP=0
            ;;
        --no-llama-swap)
            INCLUDE_LLAMA_SWAP=0
            ;;
        --no-vllm)
            INCLUDE_VLLM=0
            ;;
        --no-sglang)
            INCLUDE_SGLANG=0
            ;;
        --no-strata)
            INCLUDE_STRATA=0
            ;;
        --sd)
            INCLUDE_SD=1
            ;;
        --help|-h)
            echo "Usage: ./build-image.sh [--cuda] [--no-cache] [--no-llama] [--no-audiocpp] [--no-llama-swap] [--no-vllm] [--no-sglang] [--no-strata] [--sd]"
            echo ""
            echo "Options:"
            echo "  --cuda      Build the unified CUDA image (default)"
            echo "  --no-cache  Force rebuild without using Docker cache"
            echo "  --help, -h  Show this help message"
            echo ""
            echo "Component switches (default: every component included, except SD):"
            echo "  --no-llama       Skip llama.cpp (CUDA+Vulkan build, slowest stage)"
            echo "  --no-audiocpp    Skip audio.cpp (TTS/ASR binaries + model_specs)"
            echo "  --no-llama-swap  Skip the llama-swap binary (image loses its entrypoint!)"
            echo "  --no-vllm        Skip vLLM + vLLM-Omni + vllm-gguf-plugin (~4.7 GB)"
            echo "  --no-sglang      Skip SGLang (~3.8 GB)"
            echo "  --no-strata      Skip Strata engine + venv (~1 GB)"
            echo "  --sd             Opt IN to stable-diffusion.cpp (off by default)"
            echo ""
            echo "Environment variables:"
            echo "  DOCKER_IMAGE_TAG     Set custom image tag (default: llama-swap:unified-cuda)"
            echo "  LLAMA_REF            Pin llama.cpp to a commit, tag, or branch"
            echo "  AUDIOCPP_REF         Pin audio.cpp to a commit, tag, or branch"
            echo "  LS_VERSION           Override llama-swap version (e.g., '170' or 'latest')"
            echo "  INCLUDE_VLLM=0       Same as --no-vllm (likewise for the other components)"
            exit 0
            ;;
    esac
done

DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-llama-swap:unified-${BACKEND}}"
CACHE_TAG="${CACHE_TAG:-unified-${BACKEND}-cache}"

# Git repository URLs
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
AUDIOCPP_REPO="https://github.com/0xShug0/audio.cpp.git"
LLAMA_SWAP_REPO="https://github.com/mostlygeek/llama-swap.git"

# Resolve a git ref (commit hash, tag, or branch) to a full commit hash.
# Requires only: git, network access to the remote.
resolve_ref() {
    local repo_url="$1"
    local ref="$2"

    # Full 40-char SHA — use as-is
    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "${ref}"
        return
    fi

    # Try tag then branch (exact match)
    local hash
    hash=$(git ls-remote "${repo_url}" "refs/tags/${ref}" "refs/heads/${ref}" 2>/dev/null | head -1 | cut -f1)
    if [[ -n "${hash}" ]]; then
        echo "${hash}"
        return
    fi

    # Short hash (7+ chars): scan all refs for a SHA with this prefix
    if [[ "${ref}" =~ ^[0-9a-f]{7,}$ ]]; then
        hash=$(git ls-remote "${repo_url}" 2>/dev/null | grep "^${ref}" | head -1 | cut -f1)
        if [[ -n "${hash}" ]]; then
            echo "${hash}"
            return
        fi
    fi

    echo "ERROR: Could not resolve ref '${ref}' for ${repo_url}" >&2
    if [[ "${ref}" =~ ^[0-9a-f]+$ && ${#ref} -lt 7 ]]; then
        echo "  Short hashes must be at least 7 characters (got ${#ref})." >&2
    else
        echo "  Tried: tag, branch, git ls-remote prefix match" >&2
    fi
    echo "  Use a full 40-char SHA, a tag name, a branch name, or a 7+ char short hash." >&2
    return 1
}

# Resolve HEAD of a repo without needing to know the default branch name.
get_latest_hash() {
    git ls-remote "${1}" HEAD 2>/dev/null | head -1 | cut -f1
}

echo "=========================================="
echo "llama-swap Unified Build (${BACKEND})"
echo "=========================================="
echo ""

# Resolve llama.cpp ref (skipped entirely when the component is disabled)
if [[ "$INCLUDE_LLAMA" != "1" ]]; then
    echo "llama.cpp: skipped (INCLUDE_LLAMA=0)"
    LLAMA_HASH="disabled"
elif [[ -n "${LLAMA_REF:-}" ]]; then
    LLAMA_HASH=$(resolve_ref "${LLAMA_REPO}" "${LLAMA_REF}") || exit 1
    echo "llama.cpp: ${LLAMA_REF} -> ${LLAMA_HASH}"
else
    LLAMA_HASH=$(get_latest_hash "${LLAMA_REPO}")
    if [[ -z "${LLAMA_HASH}" ]]; then
        echo "ERROR: Could not determine latest commit for llama.cpp" >&2
        exit 1
    fi
    echo "llama.cpp: latest HEAD: ${LLAMA_HASH}"
fi

# Resolve audio.cpp ref (skipped entirely when the component is disabled)
if [[ "$INCLUDE_AUDIOCPP" != "1" ]]; then
    echo "audio.cpp: skipped (INCLUDE_AUDIOCPP=0)"
    AUDIOCPP_HASH="disabled"
elif [[ -n "${AUDIOCPP_REF:-}" ]]; then
    AUDIOCPP_HASH=$(resolve_ref "${AUDIOCPP_REPO}" "${AUDIOCPP_REF}") || exit 1
    echo "audio.cpp: ${AUDIOCPP_REF} -> ${AUDIOCPP_HASH}"
else
    AUDIOCPP_HASH=$(get_latest_hash "${AUDIOCPP_REPO}")
    if [[ -z "${AUDIOCPP_HASH}" ]]; then
        echo "ERROR: Could not determine latest commit for audio.cpp" >&2
        exit 1
    fi
    echo "audio.cpp: latest HEAD: ${AUDIOCPP_HASH}"
fi

# Resolve llama-swap ref (skipped entirely when the component is disabled)
if [[ "$INCLUDE_LLAMA_SWAP" != "1" ]]; then
    echo "llama-swap: skipped (INCLUDE_LLAMA_SWAP=0)"
    LS_HASH="disabled"
elif [[ -n "${LS_VERSION:-}" ]]; then
    LS_HASH=$(resolve_ref "${LLAMA_SWAP_REPO}" "${LS_VERSION}") || exit 1
    echo "llama-swap: ${LS_VERSION} -> ${LS_HASH}"
else
    LS_HASH=$(get_latest_hash "${LLAMA_SWAP_REPO}")
    if [[ -z "${LS_HASH}" ]]; then
        echo "ERROR: Could not determine latest commit for llama-swap" >&2
        exit 1
    fi
    echo "llama-swap: latest HEAD: ${LS_HASH}"
fi

# Resolve Strata ref. Default "latest": follow Strata's newest GitHub release so
# the 3-day cron automatically picks up upstream fixes (the slow conversation
# checkpoint replay #2316, the coarse-restore #2228, ...). Pin an exact tag via
# STRATA_REF / the workflow's strata_ref input whenever a build must be
# reproducible - Strata ships daily and a broken release can slip in.
STRATA_REPO="https://github.com/Niko1221/Strata.git"
STRATA_REF="${STRATA_REF:-latest}"
if [[ "$INCLUDE_STRATA" != "1" ]]; then
    echo "strata: skipped (INCLUDE_STRATA=0)"
    STRATA_HASH="disabled"
else
    if [[ "${STRATA_REF}" == "latest" || "${STRATA_REF}" == "release" ]]; then
        STRATA_REF=$(curl -fsSL https://api.github.com/repos/Niko1221/Strata/releases/latest \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])') || {
            echo "ERROR: could not resolve the latest Strata release tag" >&2; exit 1; }
    fi
    STRATA_HASH=$(resolve_ref "${STRATA_REPO}" "${STRATA_REF}") || exit 1
    echo "strata: ${STRATA_REF} -> ${STRATA_HASH}"
fi

# Resolve latest vLLM, vLLM-Omni and SGLang versions from PyPI at build time.
# Injecting the version strings as build-args forces BuildKit to re-run the
# uv install layers whenever a version changes, avoiding stale cache hits
# (same pattern used for LLAMA_COMMIT_HASH / AUDIOCPP_COMMIT_HASH above).
# Versions are deliberately NOT locked so images pick up new releases.
# Disabled components skip the lookup entirely.
VLLM_VERSION=""
VLLM_OMNI_VERSION=""
SGLANG_VERSION=""
if [[ "$INCLUDE_VLLM" != "1" ]]; then
    echo "vllm: skipped (INCLUDE_VLLM=0)"
    VLLM_VERSION="disabled"
    VLLM_OMNI_VERSION="disabled"
else
    echo "Resolving vLLM version from PyPI..."
    if ! VLLM_VERSION=$(curl -fsSL https://pypi.org/pypi/vllm/json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>&1); then
        echo "ERROR: Failed to resolve vLLM version from PyPI" >&2
        echo "  curl/python output: ${VLLM_VERSION}" >&2
        exit 1
    fi
    echo "vllm: latest PyPI version: ${VLLM_VERSION}"

    echo "Resolving vLLM-Omni version from PyPI..."
    if ! VLLM_OMNI_VERSION=$(curl -fsSL https://pypi.org/pypi/vllm-omni/json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>&1); then
        echo "ERROR: Failed to resolve vLLM-Omni version from PyPI" >&2
        echo "  curl/python output: ${VLLM_OMNI_VERSION}" >&2
        exit 1
    fi
    echo "vllm-omni: latest PyPI version: ${VLLM_OMNI_VERSION}"
fi

if [[ "$INCLUDE_SGLANG" != "1" ]]; then
    echo "sglang: skipped (INCLUDE_SGLANG=0)"
    SGLANG_VERSION="disabled"
else
    echo "Resolving SGLang version from PyPI..."
    if ! SGLANG_VERSION=$(curl -fsSL https://pypi.org/pypi/sglang/json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>&1); then
        echo "ERROR: Failed to resolve SGLang version from PyPI" >&2
        echo "  curl/python output: ${SGLANG_VERSION}" >&2
        exit 1
    fi
    echo "sglang: latest PyPI version: ${SGLANG_VERSION}"
fi

echo ""
echo "=========================================="
echo "Starting Docker build..."
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${DOCKERFILE:-${SCRIPT_DIR}/Dockerfile}"

echo "Components:"
for pair in "llama.cpp:${INCLUDE_LLAMA}" \
            "audio.cpp:${INCLUDE_AUDIOCPP}" \
            "llama-swap:${INCLUDE_LLAMA_SWAP}" \
            "vLLM(+Omni+GGUF):${INCLUDE_VLLM}" \
            "SGLang:${INCLUDE_SGLANG}" \
            "Strata:${INCLUDE_STRATA}" \
            "stable-diffusion.cpp:${INCLUDE_SD}"; do
    name="${pair%%:*}"
    val="${pair##*:}"
    if [ "$val" = "1" ]; then
        echo "  $name: included"
    else
        echo "  $name: SKIPPED"
    fi
done
echo ""

BUILD_ARGS=(
    --build-arg "LLAMA_COMMIT_HASH=${LLAMA_HASH}"
    --build-arg "AUDIOCPP_COMMIT_HASH=${AUDIOCPP_HASH}"
    --build-arg "LS_VERSION=${LS_HASH}"
    --build-arg "VLLM_VERSION=${VLLM_VERSION}"
    --build-arg "VLLM_OMNI_VERSION=${VLLM_OMNI_VERSION}"
    --build-arg "SGLANG_VERSION=${SGLANG_VERSION}"
    --build-arg "STRATA_COMMIT_HASH=${STRATA_HASH}"
    --build-arg "INCLUDE_LLAMA=${INCLUDE_LLAMA}"
    --build-arg "INCLUDE_AUDIOCPP=${INCLUDE_AUDIOCPP}"
    --build-arg "INCLUDE_LLAMA_SWAP=${INCLUDE_LLAMA_SWAP}"
    --build-arg "INCLUDE_VLLM=${INCLUDE_VLLM}"
    --build-arg "INCLUDE_SGLANG=${INCLUDE_SGLANG}"
    --build-arg "INCLUDE_STRATA=${INCLUDE_STRATA}"
    --build-arg "INCLUDE_SD=${INCLUDE_SD}"
    -t "${DOCKER_IMAGE_TAG}"
    -f "${DOCKERFILE}"
)

if [[ "$NO_CACHE" == true ]]; then
    BUILD_ARGS+=(--no-cache)
    echo "Note: Building without cache"
elif [[ "${GITHUB_ACTIONS:-}" == "true" && "${ACT:-}" != "true" ]]; then
    CACHE_REF="ghcr.io/${GITHUB_REPOSITORY:-sebrinass/llama-swap}:${CACHE_TAG}"
    BUILD_ARGS+=(
        --cache-from "type=registry,ref=${CACHE_REF}"
        --cache-to "type=registry,ref=${CACHE_REF},mode=max"
    )
    echo "Note: Using registry cache (${CACHE_REF})"
fi

# In CI the target tag is a registry ref (e.g. ghcr.io/...). `--load` would
# materialize the full ~16GB image in the local docker daemon ON TOP of the
# buildx cache (~20GB), which exceeds the runner's disk. Push directly from
# the build cache instead, then prune the cache and pull the image back for
# verification. Local builds (no registry in the tag) keep using `--load`.
if [[ "${DOCKER_IMAGE_TAG}" == */* ]]; then
    echo "Registry tag detected: building and pushing directly (avoids --load disk peak)"
    DOCKER_BUILDKIT=1 docker buildx build --push "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"
    echo "Freeing build cache before pulling image for verification..."
    docker buildx prune -af
    docker pull "${DOCKER_IMAGE_TAG}"
else
    echo "Local tag detected: building with --load"
    DOCKER_BUILDKIT=1 docker buildx build --load "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"
fi

echo ""
echo "=========================================="
echo "Verifying build artifacts..."
echo "=========================================="
echo ""

# Only check binaries for components that were actually built in.
EXPECTED_BINARIES=(llama-swap)
[[ "$INCLUDE_LLAMA" == "1" ]] && EXPECTED_BINARIES+=(llama-server llama-cli)
[[ "$INCLUDE_AUDIOCPP" == "1" ]] && EXPECTED_BINARIES+=(audiocpp_server audiocpp_cli)
[[ "$INCLUDE_VLLM" == "1" ]] && EXPECTED_BINARIES+=(vllm)

MISSING_BINARIES=()
for binary in "${EXPECTED_BINARIES[@]}"; do
    if ! docker run --rm --entrypoint which "${DOCKER_IMAGE_TAG}" "${binary}" >/dev/null 2>&1; then
        MISSING_BINARIES+=("${binary}")
    fi
  done

if [[ ${#MISSING_BINARIES[@]} -gt 0 ]]; then
    echo "ERROR: Build succeeded but the following binaries are missing:"
    for binary in "${MISSING_BINARIES[@]}"; do
        echo "  - ${binary}"
    done
    echo ""
    echo "Try running with --no-cache flag:"
    echo "  ./build-image.sh --no-cache"
    exit 1
fi

echo "All expected binaries verified: ${EXPECTED_BINARIES[*]}"

# Static verification for the CUDA image (no GPU required).
# Confirms nvcc (fp8 KV cache / FlashInfer JIT), vLLM version, the
# kv-cache-dtype flag, vllm / flashinfer / gguf, and the SGLang version.
echo ""
echo "Running static verification (no GPU required)..."
# NOTE: avoid the `vllm` CLI here.  vLLM 0.27 runs device-type inference
# while building the CLI arg parser, which fails without a GPU ("Failed to
# infer device type").  Use direct Python imports / source greps instead.
# Component toggles are passed into the container so the per-component checks
# below can be skipped for components that were not built.
if ! docker run --rm --entrypoint bash \
    -e INCLUDE_VLLM="$INCLUDE_VLLM" -e INCLUDE_SGLANG="$INCLUDE_SGLANG" -e INCLUDE_STRATA="$INCLUDE_STRATA" \
    "${DOCKER_IMAGE_TAG}" -c '
    set -e
    echo "--- nvcc ---"
    nvcc --version | tail -1
    if [ "$INCLUDE_VLLM" = "1" ]; then
        echo "--- vllm version ---"
        /opt/vllm-venv/bin/python -c "import vllm; print(vllm.__version__)"
        echo "--- kv-cache-dtype flag (vllm) ---"
        grep -rhoE -- "--kv-cache-dtype|kv_cache_dtype" /opt/vllm-venv/lib/python3.12/site-packages/vllm/ | sort -u
        echo "--- pip list (vllm/flashinfer/gguf) ---"
        /opt/vllm-venv/bin/pip list 2>/dev/null | grep -i -E "vllm|flashinfer|gguf"
        echo "--- flashinfer import ---"
        /opt/vllm-venv/bin/python -c "import flashinfer; print(flashinfer.__version__)"
    else
        echo "vllm: disabled (INCLUDE_VLLM=0)"
    fi
    if [ "$INCLUDE_SGLANG" = "1" ]; then
        echo "--- sglang version ---"
        /opt/sglang-venv/bin/python -c "import sglang; print(sglang.__version__)"
        echo "--- kv-cache-dtype flag (sglang) ---"
        grep -rhoE -- "kv_cache_dtype|kv-cache-dtype" /opt/sglang-venv/lib/python3.12/site-packages/sglang/ | sort -u
        echo "--- sglang pip list ---"
        /opt/sglang-venv/bin/pip list 2>/dev/null | grep -i -E "sglang|torch|numba" | head -5
    else
        echo "sglang: disabled (INCLUDE_SGLANG=0)"
    fi
    echo "--- curand headers in /usr/local/cuda/include (flashinfer JIT) ---"
    if [ "$INCLUDE_VLLM" = "1" ] || [ "$INCLUDE_SGLANG" = "1" ]; then
        if ! ls /usr/local/cuda/include/curand.h >/dev/null 2>&1; then
            echo "ERROR: curand.h missing (flashinfer sampling JIT will fail)" >&2
            exit 1
        fi
        echo "curand.h present; count: $(ls /usr/local/cuda/include/curand*.h 2>/dev/null | wc -l)"
    else
        echo "no python engine enabled, curand check skipped"
    fi
    echo "--- vulkan ICDs (nvidia + intel) ---"
    ls /usr/share/vulkan/icd.d/
    ls /usr/share/vulkan/icd.d/ | grep -iE "nvidia|intel"
    echo "--- AMD (radeon) must be absent ---"
    if ls /usr/share/vulkan/icd.d/ | grep -iq "radeon\|amd"; then
        echo "ERROR: AMD vulkan ICD present, expected removed" >&2
        exit 1
    fi
    if ls /usr/lib/x86_64-linux-gnu/libvulkan_radeon.so >/dev/null 2>&1; then
        echo "ERROR: libvulkan_radeon.so present, expected removed" >&2
        exit 1
    fi
    echo "AMD vulkan driver removed OK"
    echo "--- strata ---"
    if [ "$INCLUDE_STRATA" = "1" ]; then
        test -x /opt/strata/engine/strata && echo "strata engine present: $(/opt/strata/engine/strata --version 2>/dev/null | head -1 || echo ok)"
        /opt/strata/.venv/bin/python -c "import numpy, jinja2, yaml, requests, tqdm, PIL" && echo "strata venv ok"
    else
        echo "strata: disabled (INCLUDE_STRATA=0)"
    fi
    echo "--- libvulkan_intel.so linked deps ---"
    if ldd /usr/lib/x86_64-linux-gnu/libvulkan_intel.so | grep -qi "not found"; then
        echo "ERROR: libvulkan_intel.so has missing shared library deps" >&2
        exit 1
    fi
    echo "Vulkan ICD check OK"
'; then
    echo "ERROR: Static verification failed for ${DOCKER_IMAGE_TAG}" >&2
    exit 1
fi
echo "Static verification passed."

echo ""
echo "=========================================="
echo "Building rootless image..."
echo "=========================================="
echo ""

ROOTLESS_TAG="${DOCKER_IMAGE_TAG}-rootless"
DOCKER_BUILDKIT=1 docker build -t "${ROOTLESS_TAG}" - <<EOF
FROM ${DOCKER_IMAGE_TAG}
USER root
RUN groupadd --system --gid 10001 llama-swap && \\
    useradd --system --uid 10001 --gid 10001 \\
      --home /app --shell /sbin/nologin llama-swap && \\
    chown -R 10001:10001 /etc/llama-swap /models /opt/vllm-venv /opt/sglang-venv /opt/strata
USER 10001
EOF

echo "Rootless image built: ${ROOTLESS_TAG}"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Image tags:"
echo "  ${DOCKER_IMAGE_TAG}"
echo "  ${ROOTLESS_TAG}"
echo ""
echo "Built with:"
echo "  llama.cpp:            ${LLAMA_HASH}"
echo "  audio.cpp:            ${AUDIOCPP_HASH}"
echo "  llama-swap:           $(docker run --rm --entrypoint cat "${DOCKER_IMAGE_TAG}" /versions.txt | grep llama-swap | cut -d' ' -f2-)"
echo ""
echo "Run with:"
echo "  docker run -it --rm --gpus all ${DOCKER_IMAGE_TAG}"
