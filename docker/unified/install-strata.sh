#!/bin/bash
# Install Strata - clone, build the engine (sm_86, Tesla A2 pair) and its venv.
#
# Strata is a native C++/CUDA engine plus a thin Python server: unlike vLLM /
# SGLang it needs no torch and no CUDA pip wheels - the engine links this
# image's CUDA libs, so the image delta is ~1 GB. The build follows Strata's
# own Dockerfile (same cmake flags, same BUILD.json), so a later `setup.py`
# run inside the runtime container recognises the engine and skips recompiling.
#
# Usage: ./install-strata.sh <commit_hash_or_tag>   (default: v0.1.43.1)
# Env:   CMAKE_CUDA_ARCHITECTURES (from the image, default 86 = sm_86/A2/3060/3090)
#        STRATA_BUILD_VISION=1 also builds the image encoder (default 0: text only)
set -e

STRATA_REF="${1:-v0.1.43.1}"
STRATA_REPO="https://github.com/Niko1221/Strata.git"
# llama.cpp commit Strata's engine builds against (LLAMA_CPP_COMMIT in Strata's
# setup.py); the engine cmake needs the ggml sources via -DSTRATA_GGML_DIR.
LLAMA_CPP_COMMIT="3cf03257f219afbe7334045ff7c6a06ac68c627d"

STRATA_ARCH="${CMAKE_CUDA_ARCHITECTURES:-86}"
STRATA_VISION="${STRATA_BUILD_VISION:-0}"
export NVCC="$(command -v nvcc)"

echo "=== Strata ${STRATA_REF} (arch ${STRATA_ARCH}, vision ${STRATA_VISION}) ==="

# --- source (init-based fetch so a cached /src/Strata dir doesn't break clone) ---
mkdir -p /src/Strata
cd /src/Strata
if [ ! -d .git ]; then
    git init
    git remote add origin "${STRATA_REPO}"
fi
git fetch --depth=1 origin "${STRATA_REF}"
git checkout -f FETCH_HEAD

# --- llama.cpp sources at the pinned commit (engine builds against ggml) ---
mkdir -p /src/llama.cpp-strata
cd /src/llama.cpp-strata
if [ ! -d .git ]; then
    git init
    git remote add origin https://github.com/ggml-org/llama.cpp.git
fi
git fetch --depth=1 origin "${LLAMA_CPP_COMMIT}"
git checkout -f FETCH_HEAD

# --- the server's venv (Strata's pinned requirements) ---
cd /src/Strata
python3 -m venv .venv
.venv/bin/pip install --no-cache-dir --upgrade pip
.venv/bin/pip install --no-cache-dir -r requirements.txt

# --- engine + vision encoder, exactly the way Strata's Dockerfile builds them ---
.venv/bin/python - <<'PYEOF'
import json, os, pathlib, shutil, sys
sys.path.insert(0, ".")
import setup

llama = "/src/llama.cpp-strata"
arch = os.environ["STRATA_ARCH"]
nvcc = os.environ["NVCC"]
vision = "gpu" if os.environ.get("STRATA_VISION") == "1" else "none"

setup.cmake_build(setup.ROOT, setup.ROOT / "build", "strata",
    ["-DSTRATA_ENABLE_CUDA=ON", "-DSTRATA_BUILD_TESTS=OFF",
     f"-DCMAKE_CUDA_ARCHITECTURES={arch}", f"-DCMAKE_CUDA_COMPILER={nvcc}",
     f"-DSTRATA_GGML_DIR={llama}"], None, "build-strata.bat")
if vision != "none":
    setup.cmake_build(setup.ROOT / "tools" / "vision", setup.ROOT / "build-vision", "strata-vision",
        [f"-DLLAMA_DIR={llama}", "-DSTRATA_VISION_CUDA=ON", "-DSTRATA_PORTABLE=OFF",
         f"-DCMAKE_CUDA_ARCHITECTURES={arch}", f"-DCMAKE_CUDA_COMPILER={nvcc}"], None, "build-vision.bat")

eng = setup.ROOT / "engine"
eng.mkdir(exist_ok=True)
shutil.copy2(setup.ROOT / "build" / setup.EXE, eng / setup.EXE)
if vision != "none":
    shutil.copy2(setup.ROOT / "build-vision" / "bin" / setup.VEXE, eng / setup.VEXE)
bindir = pathlib.Path(nvcc).parent
meta = {"source": "local", "version": setup.source_version(),
        "archs": [int(a.split("-")[0]) for a in arch.split(";") if a.split("-")[0].isdigit()], "vision": vision,
        "cuda_dirs": [str(d) for d in (bindir, bindir / "x64", bindir.parent / "lib64") if d.is_dir()],
        "src": setup.source_hash(setup.ENGINE_SOURCES),
        "vision_src": setup.source_hash(setup.VISION_SOURCES) if vision != "none" else None}
(eng / "BUILD.json").write_text(json.dumps(meta, indent=1))
print(f"engine staged: {eng / setup.EXE} (vision: {vision})")
PYEOF

# --- stage the install tree (build dirs are build-time only) ---
rm -rf /src/Strata/build /src/Strata/build-vision
mkdir -p /install/strata
cp -a /src/Strata/. /install/strata/
echo "=== Strata build complete ==="
ls -la /install/strata/engine/
