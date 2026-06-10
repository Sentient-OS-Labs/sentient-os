https://developers.google.com/edge/litert-lm/overview

LiteRT-LM is a production-ready, open-source inference framework designed to
deliver high-performance, cross-platform LLM deployments on edge devices.

- **Cross-Platform Support:** Run on Android, iOS, Web, Desktop, and IoT (e.g. Raspberry Pi).
- **Hardware Acceleration:** Get peak performance and system stability by leveraging GPU and NPU accelerators across diverse hardware.
- **Multi-Modality:** Build with LLMs that have vision and audio support.
- **Tool Use:** Function calling support for agentic workflows with constrained decoding for improved accuracy.
- **Broad Model Support:** Run Gemma, Llama, Phi-4, Qwen and more.

## What's New ([v0.12.0](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.12.0))

- **Swift APIs** : Natively integrate LiteRT-LM into iOS applications with Metal GPU acceleration. See the [Swift Guide](https://developers.google.com/edge/litert-lm/swift).
- **Web JavaScript APIs** : Run models inside web browsers with high performance using web GPU/CPU. See the [JavaScript Guide](https://developers.google.com/edge/litert-lm/js).
- **LiteRT-LM CLI / Python API Update** : The command-line interface and Python API now supports NPU, besides CPU and GPU backends across Linux, macOS, and Windows. See the [CLI Guide](https://developers.google.com/edge/litert-lm/cli).
- **Community-Maintained Flutter APIs** : Build cross-platform Flutter applications using the community [flutter_gemma](https://github.com/DenisovAV/flutter_gemma) package. See the [Flutter Guide](https://developers.google.com/edge/litert-lm/flutter).

### On-Device GenAI Showcase

![Google AI Edge Gallery Screenshot](https://developers.google.com/edge/litert-lm/images/gallery_icon.jpg)

The Google AI Edge Gallery is an experimental app designed to showcase on-device
Generative AI capabilities running entirely offline using LiteRT-LM.

- **[Google Play](https://play.google.com/store/apps/details?id=com.google.ai.edge.gallery)**: Use LLMs locally on supported Android devices.
- **[App Store](https://apps.apple.com/us/app/google-ai-edge-gallery/id6749645337)**: Experience on-device AI on your iOS device.
- **[GitHub Source](https://github.com/google-ai-edge/gallery)**: View the source code for the gallery app to learn how to integrate LiteRT-LM inside your own projects.

## Featured Model: Gemma-4-E2B

- Model Size: 2.58 GB
- Additional technical details are in the
  [HuggingFace model card](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)

  | Platform (Device) | Backend | Prefill (tk/s) | Decode (tk/s) | Time to First Token (seconds) | Peak CPU Memory (MB) |
  |---|---|---|---|---|---|
  | Android (S26 Ultra) | CPU | 557 | 47 | 1.8 | 1733 |
  | Android (S26 Ultra) | GPU | 3808 | 52 | 0.3 | 676 |
  | iOS (iPhone 17 Pro) | CPU | 532 | 25 | 1.9 | 607 |
  | iOS (iPhone 17 Pro) | GPU | 2878 | 56 | 0.3 | 1450 |
  | Linux (Arm 2.3 \& 2.8 GHz, NVIDIA GeForce RTX 4090) | CPU | 260 | 35 | 4 | 1628 |
  | Linux (Arm 2.3 \& 2.8 GHz, NVIDIA GeForce RTX 4090) | GPU | 11234 | 143 | 0.1 | 913 |
  | macOS (MacBook Pro M4) | CPU | 901 | 42 | 1.1 | 736 |
  | macOS (MacBook Pro M4) | GPU | 7835 | 160 | 0.1 | 1623 |
  | Windows (Intel LunarLake) | CPU | 435 | 30 | 2.4 | 3505 |
  | Windows (Intel LunarLake) | GPU | 3751 | 48 | 0.3 | 3540 |
  | IoT (Raspberry Pi 5 16GB) | CPU | 133 | 8 | 7.8 | 1546 |

## Start Building

LiteRT-LM provides APIs for several programming languages and platforms to help
you build on-device AI applications quickly. Select a guide below to get
started:

| Language | Status | Best For... | Documentation |
|---|---|---|---|
| **CLI** | ✅ Stable | Getting started with LiteRT-LM in less than 1 min. | [CLI Guide](https://developers.google.com/edge/litert-lm/cli) |
| **Python** | ✅ Stable | Rapid prototyping, development, on desktop \& Raspberry Pi. | [Python Guide](https://developers.google.com/edge/litert-lm/python) |
| **Kotlin** | ✅ Stable | Native Android apps and JVM-based desktop tools. Optimized for Coroutines. | [Kotlin Guide](https://developers.google.com/edge/litert-lm/android) |
| **Swift** | 🚀 Early Preview | Native iOS and macOS integration with specialized Metal support. | [Swift Guide](https://developers.google.com/edge/litert-lm/swift) |
| **JavaScript (web)** | 🚀 Early Preview | Deploy models directly in web browsers with high performance. | [JavaScript Guide](https://developers.google.com/edge/litert-lm/js) |
| **Flutter** | 🚀 Community | Cross-platform Flutter apps using community `flutter_gemma`. | [Flutter Guide](https://developers.google.com/edge/litert-lm/flutter) |
| **C++** | ✅ Stable | High-performance, cross-platform core logic and embedded systems. | [C++ Guide](https://developers.google.com/edge/litert-lm/cpp) |

### Build from Source

If you want to customize LiteRT-LM or build it for a specific hardware
configuration, you can compile it directly from the source code. For
step-by-step instructions on how to set up your environment and build the
framework, refer to the
[LiteRT-LM Build and Run Guide](https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/build-and-run.md)
on GitHub.

### Supported Backends \& Platforms

| Acceleration | Android | iOS | macOS | Windows | Linux | IoT |
|---|---|---|---|---|---|---|
| **CPU** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **GPU** | ✅ | ✅ | ✅ | ✅ | ✅ | - |
| **NPU** | ✅ | - | - | 🚀 | - | - |

### Supported Models

The following table lists models supported by LiteRT-LM. For more detailed
performance numbers and model cards, visit the
[LiteRT Community on Hugging Face](https://huggingface.co/litert-community).

| Model | Type | Size (MB) | Details | Device | CPU Prefill (tk/s) | CPU Decode (tk/s) | GPU Prefill (tk/s) | GPU Decode (tk/s) |
|---|---|---|---|---|---|---|---|---|
| **Gemma4-E2B** | Chat | 2583 | [Model Card](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) | Samsung S26 Ultra | 557 | 47 | 3808 | 52 |
|   |   |   |   | iPhone 17 Pro | 532 | 25 | 2878 | 57 |
|   |   |   |   | MacBook Pro M4 | 901 | 42 | 7835 | 160 |
| **Gemma4-E4B** | Chat | 3654 | [Model Card](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | Samsung S26 Ultra | 195 | 18 | 1293 | 22 |
|   |   |   |   | iPhone 17 Pro | 159 | 10 | 1189 | 25 |
|   |   |   |   | MacBook Pro M4 | 277 | 27 | 2560 | 101 |
| **Gemma-3n-E2B** | Chat | 2965 | [Model Card](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm) | MacBook Pro M3 | 233 | 28 | - | - |
|   |   |   |   | Samsung S24 Ultra | 111 | 16 | 816 | 16 |
| **Gemma-3n-E4B** | Chat | 4235 | [Model Card](https://huggingface.co/google/gemma-3n-E4B-it-litert-lm) | MacBook Pro M3 | 170 | 20 | - | - |
|   |   |   |   | Samsung S24 Ultra | 74 | 9 | 548 | 9 |
| **Gemma3-1B** | Chat | 1005 | [Model Card](https://huggingface.co/litert-community/Gemma3-1B-IT) | Samsung S24 Ultra | 177 | 33 | 1191 | 24 |
| **FunctionGemma** | Base | 289 | [Model Card](https://huggingface.co/litert-community/functiongemma-270m-ft-mobile-actions) | Samsung S25 Ultra | 2238 | 154 | - | - |
| **phi-4-mini** | Chat | 3906 | [Model Card](https://huggingface.co/litert-community/Phi-4-mini-instruct) | Samsung S24 Ultra | 67 | 7 | 314 | 10 |
| **Qwen2.5-1.5B** | Chat | 1598 | [Model Card](https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct) | Samsung S25 Ultra | 298 | 34 | 1668 | 31 |
| **Qwen3-0.6B** | Chat | 586 | [Model Card](https://huggingface.co/litert-community/Qwen3-0.6B) | Vivo X300 Pro | 165 | 9 | 580 | 21 |
| **Qwen2.5-0.5B** | Chat | 521 | [Model Card](https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct) | Samsung S24 Ultra | 251 | 30 | - | - |

## Report Issues

If you encounter a bug or have a feature request, report at
[LiteRT-LM GitHub Issues](https://github.com/google-ai-edge/LiteRT-LM/issues/).