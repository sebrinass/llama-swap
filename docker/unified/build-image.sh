#!/bin/bash
#
# Build script for unified container with version pinning
#
# Usage:
#   ./build-image.sh --cuda                              # Build CUDA image
#   ./build-image.sh --cuda --no-cache                   # Build without cache
#   LLAMA_REF=b1234 ./build-image.sh --cuda             # Pin llama.cpp to a commit hash
#   LLAMA_REF=v1.2.3 ./build-image.sh --cuda            # Pin llama.cpp to a tag
#   AUDIOCPP_REF=release-0.1 ./build-image.sh --cuda    # Pin audio.cpp to a branch
#   LS_VERSION=170 ./build-image.sh --cuda              # Override llama-swap version
#

set -euo pipefail

BACKEND="cuda"
NO_CACHE=false

for arg in "$@"; do
    case $arg in
        --cuda)
            BACKEND="cuda"
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --help|-h)
            echo "Usage: ./build-image.sh [--cuda] [--no-cache]"
            echo ""
            echo "Options:"
            echo "  --cuda      Build the unified CUDA image (default)"
            echo "  --no-cache  Force rebuild without using Docker cache"
            echo "  --help, -h  Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  DOCKER_IMAGE_TAG     Set custom image tag (default: llama-swap:unified-cuda)"
            echo "  LLAMA_REF            Pin llama.cpp to a commit, tag, or branch"
            echo "  AUDIOCPP_REF         Pin audio.cpp to a commit, tag, or branch"
            echo "  LS_VERSION           Override llama-swap version (e.g., '170' or 'latest')"
            exit 0
            ;;
    esac
done

DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-llama-swap:unified-${BACKEND}}"
CACHE_TAG="${CACHE_TAG:-unified-${BACKEND}-cache}"

# Git repository URLs
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
AUDIOCPP_REPO="https://github.com/kigner/audio.cpp-webui.git"
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

# Resolve llama.cpp ref
if [[ -n "${LLAMA_REF:-}" ]]; then
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

# Resolve audio.cpp ref
if [[ -n "${AUDIOCPP_REF:-}" ]]; then
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

# Resolve llama-swap ref
if [[ -n "${LS_VERSION:-}" ]]; then
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

# Resolve latest vLLM, vLLM-Omni and SGLang versions from PyPI at build time.
# Injecting the version strings as build-args forces BuildKit to re-run the
# uv install layers whenever a version changes, avoiding stale cache hits
# (same pattern used for LLAMA_COMMIT_HASH / AUDIOCPP_COMMIT_HASH above).
# Versions are deliberately NOT locked so images pick up new releases.
VLLM_VERSION=""
VLLM_OMNI_VERSION=""
SGLANG_VERSION=""
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

echo "Resolving SGLang version from PyPI..."
if ! SGLANG_VERSION=$(curl -fsSL https://pypi.org/pypi/sglang/json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>&1); then
    echo "ERROR: Failed to resolve SGLang version from PyPI" >&2
    echo "  curl/python output: ${SGLANG_VERSION}" >&2
    exit 1
fi
echo "sglang: latest PyPI version: ${SGLANG_VERSION}"

echo ""
echo "=========================================="
echo "Starting Docker build..."
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${DOCKERFILE:-${SCRIPT_DIR}/Dockerfile}"

BUILD_ARGS=(
    --build-arg "LLAMA_COMMIT_HASH=${LLAMA_HASH}"
    --build-arg "AUDIOCPP_COMMIT_HASH=${AUDIOCPP_HASH}"
    --build-arg "LS_VERSION=${LS_HASH}"
    --build-arg "VLLM_VERSION=${VLLM_VERSION}"
    --build-arg "VLLM_OMNI_VERSION=${VLLM_OMNI_VERSION}"
    --build-arg "SGLANG_VERSION=${SGLANG_VERSION}"
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

DOCKER_BUILDKIT=1 docker buildx build --load "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"

echo ""
echo "=========================================="
echo "Verifying build artifacts..."
echo "=========================================="
echo ""

EXPECTED_BINARIES=(llama-server llama-cli audiocpp_server audiocpp_cli llama-swap vllm)

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

echo "All expected binaries verified: llama-server, llama-cli, audiocpp_server, audiocpp_cli, llama-swap, vllm"

# Static verification for the CUDA image (no GPU required).
# Confirms nvcc (fp8 KV cache / FlashInfer JIT), vLLM version, the
# kv-cache-dtype flag, vllm / flashinfer / gguf, and the SGLang version.
echo ""
echo "Running static verification (no GPU required)..."
# NOTE: avoid the `vllm` CLI here.  vLLM 0.27 runs device-type inference
# while building the CLI arg parser, which fails without a GPU ("Failed to
# infer device type").  Use direct Python imports / source greps instead.
if ! docker run --rm --entrypoint bash "${DOCKER_IMAGE_TAG}" -c '
    set -e
    echo "--- nvcc ---"
    nvcc --version | tail -1
    echo "--- vllm version ---"
    /opt/vllm-venv/bin/python -c "import vllm; print(vllm.__version__)"
    echo "--- kv-cache-dtype flag (vllm) ---"
    grep -rhoE -- "--kv-cache-dtype|kv_cache_dtype" /opt/vllm-venv/lib/python3.12/site-packages/vllm/ | sort -u
    echo "--- pip list (vllm/flashinfer/gguf) ---"
    /opt/vllm-venv/bin/pip list 2>/dev/null | grep -i -E "vllm|flashinfer|gguf"
    echo "--- flashinfer import ---"
    /opt/vllm-venv/bin/python -c "import flashinfer; print(flashinfer.__version__)"
    echo "--- sglang version ---"
    /opt/sglang-venv/bin/python -c "import sglang; print(sglang.__version__)"
    echo "--- kv-cache-dtype flag (sglang) ---"
    grep -rhoE -- "kv_cache_dtype|kv-cache-dtype" /opt/sglang-venv/lib/python3.12/site-packages/sglang/ | sort -u
    echo "--- sglang pip list ---"
    /opt/sglang-venv/bin/pip list 2>/dev/null | grep -i -E "sglang|torch|numba" | head -5
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
    chown -R 10001:10001 /etc/llama-swap /models /opt/vllm-venv /opt/sglang-venv
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
