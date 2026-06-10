https://developers.google.com/edge/litert-lm/swift

The Swift API of LiteRT-LM lets you integrate large language models natively
into **iOS and macOS** applications. Features like **multi-modality** , **tool
use** , and **GPU acceleration** (via Metal) are fully supported.

## Introduction

Here is an example of using the Swift API to initialize a model and send a
message:

    import LiteRTLM

    // 1. Initialize the Engine with your model
    let config = try EngineConfig(
      modelPath: "path/to/model.litertlm",
      backend: .gpu, // Use .cpu() for CPU execution
      cacheDir: NSTemporaryDirectory()
    )
    let engine = Engine(engineConfig: config)
    try await engine.initialize()

    // 2. Start a new Conversation
    let conversation = try await engine.createConversation()

    // 3. Send a message and print the response
    let response = try await conversation.sendMessage(Message("What is the capital of France?"))
    print(response.toString)

## Getting Started

This section provides instructions on how to integrate the LiteRT-LM Swift API
into your application.

### Swift Package Manager (SPM)

You can integrate LiteRT-LM into your Xcode project using Swift Package Manager.

1. Open your project in Xcode and navigate to **File \> Add Package
   Dependencies...**
2. Enter the package repository URL: `https://github.com/google-ai-edge/LiteRT-LM`
3. Select the **LiteRTLM** library to add it to your application target.

> [!NOTE]
> **Note:** If you see an error like `no such module LiteRTLM` after adding the package: 1. Click your project in the project navigator. 2. Select your app target. 3. Go to the **General** tab. 4. Navigate to **Frameworks, Libraries, and Embedded Content** . 5. Click the **`+`** button. 6. Select **LiteRTLM Package** -\> **LiteRTLM** . 7. Click **Add**.

> [!TIP]
> **Tip:** If your physical device's iOS version is lower than the deployment target set in Xcode, you can change it by going to the **General** tab, and under **Minimum Deployments** (or **Deployment Info**), change the iOS version to match your device's version.

If you are developing a package using `Package.swift`, add it to your
dependencies:

    dependencies: [
      .package(url: "https://github.com/google-ai-edge/LiteRT-LM", from: "0.12.0")
    ]

*** ** * ** ***

## Core API Guide

This section details the fundamental components and workflows for using the
LiteRT-LM Swift API, including engine initialization, conversation management,
and sending messages.

### Initialize the Engine

The `Engine` handles model loading, resource allocation, and lifecycle
management.

    import LiteRTLM

    let engineConfig = try EngineConfig(
      modelPath: "path/to/your/model.litertlm",
      backend: .gpu, // Use .gpu for Metal hardware acceleration
      maxNumTokens: 512, // Size of the KV-cache
      cacheDir: NSTemporaryDirectory() // Writable directory for compilation cache
    )

    let engine = Engine(engineConfig: engineConfig)
    try await engine.initialize()

### Create a Conversation

A `Conversation` manages chat history, system instructions, and sampler
configurations.

    // Configure custom sampling parameters
    let samplerConfig = try SamplerConfig(
      topK: 40,
      topP: 0.95,
      temperature: 0.7
    )

    // Create the conversation config with system instructions
    let config = ConversationConfig(
      systemMessage: Message("You are a helpful assistant."),
      samplerConfig: samplerConfig
    )

    let conversation = try await engine.createConversation(with: config)

### Send Messages

You can interact with the model synchronously or asynchronously (streaming).

#### Synchronous Example

    let response = try await conversation.sendMessage(Message("Hello!"))
    print(response.toString)

#### Asynchronous (Streaming) Example

    let message = Message("Tell me a long story.")

    for try await chunk in conversation.sendMessageStream(message) {
      // Output response chunks in real-time
      print(chunk.toString, terminator: "")
    }
    print()

*** ** * ** ***

## Multi-Modality

To use vision or audio features, make sure to configure the specialized backends
during engine initialization.

> [!NOTE]
> **Note:** Multi-modality requires models with multimodal support, such as [Gemma 4](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm).

    let engineConfig = try EngineConfig(
      modelPath: "path/to/multimodal_model.litertlm",
      backend: .gpu,
      visionBackend: .cpu(), // Enable CPU vision executor
      audioBackend: .cpu(), // Enable CPU audio executor
      cacheDir: NSTemporaryDirectory()
    )
    let engine = Engine(engineConfig: engineConfig)
    try await engine.initialize()

### Image Input (Vision)

Provide an image as a path or raw bytes:

    let imagePath = Bundle.main.path(forResource: "scenery", ofType: "jpg")!

    let message = Message(contents: [
      Content.imageFile(imagePath),
      Content.text("Describe this image.")
    ])

    let response = try await conversation.sendMessage(message)
    print(response.toString)

### Audio Input

Provide an audio path:

    let audioPath = Bundle.main.path(forResource: "recording", ofType: "wav")!

    let message = Message(contents: [
      Content.audioFile(audioPath),
      Content.text("Transcribe this recording.")
    ])

    let response = try await conversation.sendMessage(message)
    print(response.toString)

*** ** * ** ***

## 🔴 New: Multi-Token Prediction (MTP)

Multi-Token Prediction (MTP) is a performance optimization that significantly
accelerates decode speeds. It is universally recommended for all tasks using
GPU/Metal backends.

To use MTP, enable speculative decoding in experimental flags before
initializing the engine.

    import LiteRTLM

    // Opt into experimental APIs to configure MTP
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableSpeculativeDecoding = true

    let engineConfig = try EngineConfig(
      modelPath: "path/to/model.litertlm",
      backend: .gpu,
      cacheDir: NSTemporaryDirectory()
    )
    let engine = Engine(engineConfig: engineConfig)
    try await engine.initialize()

*** ** * ** ***

## Define and Use Tools

> [!NOTE]
> **Note:** This requires models with tool support, such as [Gemma 4](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm).

You can define Swift structures as tools that the model can automatically call
to execute logic.

1. Conform to the `Tool` protocol.
2. Declare parameters using the `@ToolParam` property wrapper.
3. Implement the `run()` method.

    import LiteRTLM

    // 1. Define your custom tool
    struct GetCurrentWeatherTool: Tool {
      static let name = "get_current_weather"
      static let description = "Get the current weather for a location."

      @ToolParam(description: "The city and state, e.g. San Francisco, CA")
      var location: String

      @ToolParam(description: "The temperature unit to use (celsius or fahrenheit)")
      var unit: String = "celsius"

      func run() async throws -> Any {
        // Call your weather API here
        return [
          "location": location,
          "temperature": "22",
          "unit": unit,
          "condition": "sunny"
        ]
      }
    }

    // 2. Register the tool in your conversation configuration
    let config = ConversationConfig(
      tools: [GetCurrentWeatherTool()]
    )

    let conversation = try await engine.createConversation(with: config)

    // 3. The model will invoke the tool automatically if needed
    let response = try await conversation.sendMessage(Message("What is the weather in Paris right now?"))
    print(response.toString)