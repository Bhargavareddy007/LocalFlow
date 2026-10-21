# Third-party components

LocalFlow bundles or downloads the following. Their licenses apply to those parts.

| Component | Use | License |
| --- | --- | --- |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (libwhisper, libparakeet) | Speech recognition runtime | MIT |
| [ggml](https://github.com/ggml-org/ggml) | Tensor library, Metal backend | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (libllama) | Runtime for the optional polish model | MIT |
| libomp (LLVM OpenMP) | Threading, dependency of ggml | Apache 2.0 with LLVM exception |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA, GGML conversion by ggml-org | Default speech model (downloaded on first launch) | CC BY 4.0 |
| [Whisper large-v3-turbo](https://github.com/openai/whisper) by OpenAI, GGML conversion by ggerganov | Optional multilingual speech model | MIT |
| [Qwen2.5 1.5B Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) by Alibaba Cloud | Optional text polishing model | Apache 2.0 |

Model files are not part of this repository. The app downloads them from Hugging Face once and verifies them against pinned SHA-256 checksums.
