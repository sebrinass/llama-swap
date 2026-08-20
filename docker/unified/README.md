# Unified Docker Container

These scripts create a custom llama-swap container that contains:

- llama-server for LLMs, rerank and embedding model support (CUDA + Vulkan dual backend, runs on NVIDIA/AMD/Intel GPUs)
- audiocpp_server for TTS and ASR
- vLLM + vLLM-Omni + vLLM-GGUF-plugin for OpenAI-compatible high-throughput serving
- SGLang (isolated venv) for agent-reasoning workloads
