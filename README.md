# MockMate

Offline-first mock interview app. Flutter UI + Rust backend via flutter_rust_bridge. Runs locally with Ollama (no cloud required).

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Flutter | SDK `^3.11.0-200.1.beta` | Dart 3.x |
| Rust | stable (1.76+) | `rustup` recommended |
| Ollama | latest | [ollama.com](https://ollama.com) |
| whisper-cli | any | e.g. `whisper.cpp` built from source |
| piper | any | for local TTS |
| flutter_rust_bridge_codegen | 2.x | `cargo install flutter_rust_bridge_codegen` |

---

## 1. Clone & enter repo

```sh
git clone <repo-url>
cd MockMate
```

## 2. Install Flutter dependencies

```sh
flutter pub get
```

## 3. Start Ollama and pull the default model

```sh
ollama serve
ollama pull qwen2.5:7b-instruct-q4_K_M
```

## 4. Add knowledge base files

Drop `.txt` files into `assets/kb/`. MockMate loads all files in that folder as the interview knowledge base.

```
assets/kb/your-topic.txt
```

## 5. Run

Flutter's native assets hook compiles Rust automatically on `flutter run`.

```sh
flutter run -d windows   # or macos / linux
```

On first launch the onboarding wizard will:
1. Check Ollama health
2. Pull the model if missing
3. Navigate to the chat screen

---

## Optional: BYOK cloud providers

Set API keys in the in-app **Settings** screen (gear icon). Supported:

- OpenAI (LLM)
- Anthropic (LLM)
- ElevenLabs (TTS)

---

## Optional: custom STT / TTS binaries

Pass paths via the bridge functions `init_whisper_stt(bin, model)` and `init_piper_tts(bin, voice)`, or set them in Settings.

---

## Run tests

```sh
# Rust
cargo test --manifest-path rust/Cargo.toml

# Flutter
flutter test
```

---

## Architecture

```
Flutter (Riverpod) ──FRB──► mockmate-bridge (cdylib)
                                  │
          ┌───────────────────────┼────────────────────────┐
          │               mockmate-core (traits)            │
     mockmate-llm      mockmate-audio    mockmate-tts
     mockmate-session  mockmate-viseme
```

All AI engines are Rust traits (`LlmProvider`, `TtsProvider`, `SttProvider`, `VadProvider`, `VisemeExtractor`) stored as `Arc<dyn Trait>` — hot-swappable at runtime.
