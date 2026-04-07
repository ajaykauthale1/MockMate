# Project Overview: Local-First Conversational 2D AI Avatar

## 1. The Problem Statement
The goal is to build a high-performance, real-time conversational AI avatar application that can act as an interactive domain expert based on a bundled 2000-line knowledge base.

**Core Constraints & Requirements:**
* **Hardware Bottleneck:** Must run flawlessly on mid-range consumer hardware (e.g., 6GB VRAM limit like an RTX 2060) without memory overflow or throttling.
* **Offline-First Mandate:** The primary execution path must be 100% local, ensuring total privacy and zero API costs, with fallback options for cloud-based "Bring Your Own Key" (BYOK) configurations.
* **Cross-Platform UI:** The application must run natively on Windows, macOS, and Linux from a single codebase while maintaining a highly aesthetic, modern minimalist, skeuomorphic design.
* **Real-Time Interruption:** The avatar must behave like a human on a phone call. If the user interrupts, the app must instantly detect human speech, silence the avatar, and listen.
* **Dual-Mode Expertise:** The system must utilize the 2000-line context document in two distinct ways without requiring complex RAG/Vector DB pipelines:
    1.  **Guide Mode:** Answering specific and general questions accurately.
    2.  **Test/Tutor Mode:** Utilizing Socratic prompting to quiz the user, providing hints instead of direct answers.

---

## 2. The Architecture
To achieve bare-metal performance, hardware abstraction, and pixel-perfect UI, the application utilizes a triad architecture: a Flutter frontend, a native Rust backend, and an Ollama sidecar.

### A. The Presentation Layer (Flutter)
* **Framework:** Flutter (compiled to native OS binaries, avoiding heavy Electron/Chromium wrappers).
* **Role:** Handles all visual rendering, skeuomorphic canvas painting, and UI state management.
* **Avatar Sync:** Uses `StreamBuilder` to receive real-time viseme (mouth shape) data from the backend to instantly swap 2D sprites or drive a skeletal Rive animation.

### B. The Core Engine (Rust + `flutter_rust_bridge`)
* **Framework:** Native Rust, connected to Flutter via zero-copy memory transfers using `flutter_rust_bridge`.
* **Role:** Acts as the high-performance nervous system, bypassing garbage collection pauses to guarantee sub-millisecond audio and state execution.
* **Input Audio Pipeline:**
    * **Capture:** `cpal` taps directly into OS audio (WASAPI/CoreAudio/ALSA) for microphone input.
    * **Intelligence (VAD):** Silero VAD runs via the `ort` (ONNX Runtime) crate to detect human speech and trigger the "Interruption Kill Switch."
    * **Transcription:** Captured audio buffers are passed to `whisper.cpp` (Rust bindings) for local, offline Speech-to-Text.
* **Output Audio Pipeline:**
    * **Generation:** Utilizes local offline TTS engines (Kokoro/Piper) or standard HTTP clients for BYOK APIs (ElevenLabs).
    * **Viseme Calculation:** Streams the generated TTS byte array through `rustfft` to analyze audio frequencies and calculate accurate mouth shapes *before* playback.
    * **Playback:** Routes the audio to the speakers via `cpal`.

### C. The AI Brain (Ollama Sidecar)
* **Framework:** Ollama running as an independent background process.
* **Role:** Hosts the quantized Small Language Model (e.g., Qwen 2.5 3B, Gemma 4).
* **Why Sidecar?** Decoupling the LLM from the main application binary prevents compiling CUDA, Metal, and ROCm bindings directly into the app, keeping the install size small and hardware acceleration automated.
* **Prompt Strategy:** Injects the 2000-line knowledge base into strict XML tags within the system prompt, leveraging Ollama's KV Caching to ensure the RTX 2060 only calculates the massive context once, yielding sub-300ms response times for subsequent queries.

---

## 3. Phased Development Plan

### Phase 1: Foundation and Sidecar Architecture
* **Repository Setup:** Initialize the project using the `flutter_rust_bridge_codegen` template.
* **Asset Pipeline:** Bundle the 2000-line text files (`assets/`) and configure Flutter to pass these strings across the bridge upon user selection.
* **The Sidecar Bridge:** Write the Rust HTTP clients to interface with the local Ollama REST API (`http://localhost:11434`).
* **Onboarding UI:** Build the Flutter setup wizard to guide the user through installing the Ollama dependency and downloading the required model.

### Phase 2: Core AI Bridge and Dual Mode Logic
* **State Management:** Implement a thread-safe `Mutex` in Rust to hold the active knowledge base string and the current interaction mode.
* **Prompt Engineering:** Construct the strict XML system prompts for both modes:
    * *Guide Mode:* Instructs the SLM to pull facts from the `<KNOWLEDGE_BASE>`.
    * *Test Mode:* Socratic instructions forcing the SLM to withhold answers, evaluate user input, and provide hints.
* **Execution Logic:** Wire the Rust backend to dynamically build the JSON payload and execute the chat completion, ensuring the prompt array is wiped and rebuilt cleanly on mode/document swaps (accepting a 2-second KV cache reload).

### Phase 3: The Native Audio & Intelligence Pipeline (Critical Path)
* **Microphone Capture:** Implement `cpal` to maintain a continuous ring buffer of microphone input.
* **VAD Kill Switch:** Integrate Silero VAD to constantly analyze the buffer. If speech is detected while the avatar is talking: instantly drop the TTS playback buffer, send a cancel signal to the Ollama HTTP request, and emit a state change event to Flutter.
* **Offline Transcription:** Pass the completed speech buffer to the local `whisper.cpp` instance for text conversion.
* **Audio Generation & Analysis:** Pipe the LLM's text output into the TTS engine, route the resulting audio through `rustfft` to extract visemes, and send both the audio and viseme data back across the bridge.

### Phase 4: Flutter UI and 2D Avatar Sync
* **Visual Presentation:** Develop the cross-platform UI with the required modern, minimalist, skeuomorphic aesthetic using custom painters.
* **Animation Sync:** Consume the live viseme data stream from Rust to animate the 2D avatar perfectly in time with the generated audio.
* **Reactive State:** Listen for the VAD `user_speaking` event to instantly swap the avatar's visual state from "Talking" to a neutral "Listening" expression, completing the illusion of real-time presence.