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
done

done
