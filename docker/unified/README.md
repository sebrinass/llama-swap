# Unified Docker Container

These scripts create a custom llama-swap container. Every component can be
left out of the build to shrink the image. The default set is llama.cpp +
llama-swap + vLLM + SGLang + Strata; everything marked "opt-in" below is off
unless you ask for it:

- llama-server for LLMs, rerank and embedding model support (CUDA + Vulkan dual backend, runs on NVIDIA/AMD/Intel GPUs) — `--no-llama`
- llama.cpp's llama-tts tool (opt-in, ~128 MB) — `--llamatts`
- audiocpp_server for TTS and ASR (opt-in) — `--audiocpp` / `--no-audiocpp`
- vLLM for OpenAI-compatible high-throughput serving — `--no-vllm` (~4.7 GB)
- SGLang (isolated venv) for agent-reasoning workloads — `--no-sglang` (~3.8 GB)
- Strata (Qwen3.8-Flash-Next engine) — `--no-strata` (~1 GB)
- the llama-swap binary itself (the image entrypoint) — `--no-llama-swap`
- stable-diffusion.cpp (off by default, opt in with `--sd`)
- the rootless variant, a second image that runs as an unprivileged user
  (off by default, opt in with `--rootless`; it re-chowns ~20 GB of venv
  files, which Docker copies into a full extra layer)

Two vLLM add-ons are opt-in as well (off by default):

- vLLM-Omni — `--vllm-omni`. Its version is auto-aligned to the vLLM
  major.minor line (vLLM 0.31.x -> vLLM-Omni 0.31.x, pre-releases included),
  because the two packages release on independent schedules and a stable
  omni that lags vLLM breaks with import errors. Override with `VLLM_OMNI_REF`.
- vllm-gguf-plugin (GGUF models served directly by vLLM) — `--vllm-gguf`

Example: `./build-image.sh --cuda --no-sglang --no-vllm` builds a ~3 GB image
with just llama.cpp + Strata. Full image: ~11 GB compressed.

Switches are also available as `INCLUDE_*` env vars (`INCLUDE_SGLANG=0
./build-image.sh --cuda`) and, for manually-triggered CI runs, as
workflow_dispatch checkboxes. Push/scheduled builds include the default set
and leave every opt-in component out (audio.cpp, llama-tts, SD, the vLLM
add-ons, the rootless variant).

At build time the baked-in config has the entries of disabled components
commented out automatically (matched by what the entry's cmd invokes, not by
its name), so the image config never references a binary that was left out.
A bind-mounted config is NOT touched — keep it in sync manually.
