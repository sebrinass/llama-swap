# Unified Docker Container

These scripts create a custom llama-swap container. Every component can be
left out of the build to shrink the image (default: all included):

- llama-server for LLMs, rerank and embedding model support (CUDA + Vulkan dual backend, runs on NVIDIA/AMD/Intel GPUs) — `--no-llama`
- audiocpp_server for TTS and ASR — `--no-audiocpp`
- vLLM + vLLM-Omni + vLLM-GGUF-plugin for OpenAI-compatible high-throughput serving — `--no-vllm` (~4.7 GB)
- SGLang (isolated venv) for agent-reasoning workloads — `--no-sglang` (~3.8 GB)
- Strata (Qwen3.8-Flash-Next engine) — `--no-strata` (~1 GB)
- the llama-swap binary itself (the image entrypoint) — `--no-llama-swap`
- stable-diffusion.cpp (off by default, opt in with `--sd`)

Example: `./build-image.sh --cuda --no-sglang --no-vllm` builds a ~3 GB image
with just llama.cpp + audio.cpp + Strata. Full image: ~11 GB compressed.

Switches are also available as `INCLUDE_*` env vars (`INCLUDE_SGLANG=0
./build-image.sh --cuda`) and, for manually-triggered CI runs, as
workflow_dispatch checkboxes. Push/scheduled builds always include everything
(and never SD).

At build time the baked-in config has the entries of disabled components
commented out automatically, so the image config never references a binary
that was left out. A bind-mounted config is NOT touched — keep it in sync
manually.
