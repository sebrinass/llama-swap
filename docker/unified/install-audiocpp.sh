#!/bin/bash
# Install audio.cpp - clone, build, and install binaries
# Usage: BACKEND=cuda|vulkan ./install-audiocpp.sh <commit_hash_or_branch>
set -e

COMMIT_HASH="${1:-release-0.1}"
BACKEND="${BACKEND:-cuda}"

mkdir -p /install/bin

# Clone and checkout (init-based so cache-mounted /src/audio.cpp/build dir doesn't break clone)
echo "=== Cloning audio.cpp at ${COMMIT_HASH} ==="
mkdir -p /src/audio.cpp
cd /src/audio.cpp
if [ ! -d .git ]; then
    git init
    git remote add origin https://github.com/kigner/audio.cpp-webui.git
fi
git fetch --depth=1 origin "${COMMIT_HASH}"
git checkout FETCH_HEAD

# Common cmake flags
CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DENGINE_ENABLE_LLAMAFILE=ON
    -DENGINE_ENABLE_OPENMP=ON
    -DENGINE_BUILD_EXAMPLES=OFF
    -DENGINE_BUILD_TESTS=OFF
    -DENGINE_BUILD_WARMBENCH=OFF
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
)

if [ "$BACKEND" = "cuda" ]; then
    CMAKE_FLAGS+=(
        -DENGINE_ENABLE_CUDA=ON
        -DENGINE_ENABLE_CUDA_GRAPHS=ON
        -DENGINE_ENABLE_VULKAN=OFF
        -DENGINE_ENABLE_NATIVE_CPU=OFF
        "-DCMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES:?CMAKE_CUDA_ARCHITECTURES must be set}"
        "-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler"
        "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath-link,/usr/local/cuda/lib64/stubs -lcuda"
    )
elif [ "$BACKEND" = "vulkan" ]; then
    CMAKE_FLAGS+=(
        -DENGINE_ENABLE_CUDA=OFF
        -DENGINE_ENABLE_VULKAN=ON
        -DENGINE_ENABLE_NATIVE_CPU=OFF
    )
fi

TARGETS=(audiocpp_cli audiocpp_server)

rm -rf build/CMakeCache.txt build/CMakeFiles 2>/dev/null || true

echo "=== Building audio.cpp for ${BACKEND} ==="
cmake -S . -B build "${CMAKE_FLAGS[@]}"
cmake --build build --config Release -j"$(nproc)" --target "${TARGETS[@]}"

for bin in "${TARGETS[@]}"; do
    if [ ! -f "build/bin/$bin" ]; then
        echo "FATAL: $bin not found in build/bin/" >&2
        exit 1
    fi
    cp "build/bin/$bin" "/install/bin/"
done
echo "=== audio.cpp build complete ==="
ls -la /install/bin/
