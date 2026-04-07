# MockMate — Implementation Plan

## Overview

Cross-platform mock interview app (Windows / macOS / Linux) using Flutter for UI and Rust (via `flutter_rust_bridge`) for the backend engine. All subsystems are open source and designed as pluggable traits following SOLID principles.

---

## 1. SOLID Design Principles Applied

Every architectural decision maps to a SOLID principle:

| Principle | How it applies |
|---|---|
| **S** — Single Responsibility | Each crate owns exactly one concern: `mockmate-tts` only synthesizes audio, `mockmate-llm` only calls LLM APIs, `mockmate-viseme` only extracts visemes. The bridge crate (`mockmate-core`) only handles FRB wiring. |
| **O** — Open/Closed | Adding a new TTS engine (e.g. a future neural TTS) means adding a new `impl TtsProvider for MyTts` file and registering it — zero changes to `mockmate-core`, the audio pipeline, or Flutter. All providers are open for extension, closed for modification. |
| **L** — Liskov Substitution | Any `impl TtsProvider` can replace any other at `init_session()` time. The audio pipeline, viseme extractor, and Flutter UI are oblivious to which concrete provider is active. Same for `LlmProvider`, `SttProvider`, `VadProvider`. |
| **I** — Interface Segregation | Traits are narrow and focused. `VadProvider` has only `process_frame()` and `reset()` — it does not expose model loading or config. `TtsProvider` does not know about visemes (that concern belongs to `VisemeExtractor`). |
| **D** — Dependency Inversion | `mockmate-core`'s `AppState` holds `Arc<dyn TtsProvider>`, `Arc<dyn LlmProvider>` etc. — abstractions, never concrete types. The entire pipeline is wired at startup via `init_session(config)`, which reads the user's provider selection and injects the right implementations. |

**In practice:** swapping one TTS voice model for another, or Ollama → OpenAI for LLM, is a one-line config change at `init_session()`. No pipeline code changes. No Flutter changes.

---

## 2. Repository Structure

```
mockmate/
├── Cargo.toml                        # Rust workspace root
├── pubspec.yaml                      # Flutter root
├── flutter_rust_bridge.yaml          # FRB codegen config
├── build.rs                          # Top-level build script (FRB codegen trigger)
│
├── rust/
│   ├── Cargo.toml
│   │
│   ├── mockmate-core/                # Only crate with #[flutter_rust_bridge] annotations
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── bridge/
│   │       │   ├── api_audio.rs      # FRB audio functions/streams
│   │       │   ├── api_llm.rs        # FRB LLM functions/streams
│   │       │   ├── api_avatar.rs     # FRB viseme stream
│   │       │   └── api_session.rs    # FRB session/mode control
│   │       └── state.rs              # Global AppState (Arc<Mutex<...>>)
│   │
│   ├── mockmate-audio/               # cpal capture/playback, VAD, STT
│   │   └── src/
│   │       ├── capture.rs            # cpal mic ring buffer
│   │       ├── playback.rs           # cpal speaker output
│   │       ├── vad/
│   │       │   ├── traits.rs         # VadProvider trait
│   │       │   └── silero.rs         # Silero VAD via ort
│   │       └── stt/
│   │           ├── traits.rs         # SttProvider trait
│   │           └── whisper.rs        # whisper.cpp bindings
│   │
│   ├── mockmate-tts/                 # TTS provider abstractions + implementations
│   │   └── src/
│   │       ├── traits.rs             # TtsProvider trait
│   │       └── kokoro.rs             # Kokoro TTS via ONNX (Apache 2.0) — primary TTS engine
│   │
│   ├── mockmate-llm/                 # LLM provider abstractions + implementations
│   │   └── src/
│   │       ├── traits.rs             # LlmProvider trait
│   │       ├── ollama.rs             # Ollama localhost:11434 client
│   │       ├── openai.rs             # OpenAI BYOK client
│   │       └── anthropic.rs          # Anthropic BYOK client
│   │
│   ├── mockmate-viseme/              # Viseme extraction from audio
│   │   └── src/
│   │       ├── traits.rs             # VisemeExtractor trait
│   │       └── fft_extractor.rs      # rustfft-based implementation
│   │
│   └── mockmate-session/             # Mode logic, prompt construction, KV cache state
│       └── src/
│           ├── session.rs            # InterviewSession + mode FSM
│           ├── prompt_builder.rs     # XML system prompt construction
│           └── knowledge_base.rs     # KB loading + chunking
│
├── lib/                              # Flutter source root
│   ├── main.dart
│   └── src/
│       ├── bridge/                   # Generated FRB Dart bindings (auto, do not edit)
│       │   └── frb_generated.dart
│       ├── providers/                # Riverpod providers
│       │   ├── session_provider.dart
│       │   ├── audio_provider.dart
│       │   └── avatar_provider.dart
│       ├── services/
│       │   ├── bridge_service.dart   # Wraps FRB calls with error handling
│       │   └── settings_service.dart # Persists BYOK keys, model paths
│       ├── ui/
│       │   ├── screens/
│       │   │   ├── onboarding_screen.dart
│       │   │   ├── interview_screen.dart
│       │   │   └── settings_screen.dart
│       │   ├── widgets/
│       │   │   ├── avatar_canvas.dart       # CustomPainter for 2D avatar
│       │   │   ├── waveform_widget.dart     # Mic input visualizer
│       │   │   ├── transcript_panel.dart    # Scrolling Q&A log
│       │   │   └── mode_toggle.dart         # Guide / Test switcher
│       │   └── theme/
│       │       ├── app_theme.dart
│       │       └── painters/skeuomorph_painter.dart
│       └── models/
│           ├── viseme_frame.dart
│           ├── interview_message.dart
│           └── session_config.dart
│
├── assets/
│   ├── knowledge/                    # Bundled knowledge base files (.md / .txt)
│   ├── models/
│   │   ├── silero_vad.onnx           # VAD model (bundled, ~2MB)
│   │   └── whisper-tiny.en.bin       # Whisper model (bundled, ~40MB)
│   └── avatar/
│       ├── sprites/                  # PNG per viseme ID (0–21)
│       └── rive/avatar.riv           # Optional skeletal animation
│
├── test/
│   ├── rust/                         # Rust unit + integration tests
│   └── flutter/                      # Widget + integration tests
│
└── docs/
    ├── idea.md
    └── plan.md                       # This file
```

**Key structural decision:** `mockmate-core` is the only crate with FRB annotations. All other crates are pure Rust libraries — fully testable without Flutter.

---

## 2. Core Rust Trait Abstractions

All traits are `Send + Sync + 'static` and use `async_trait`. This enables `Arc<dyn Trait>` storage in `AppState` for trivial provider swapping.

### 2.1 TtsProvider

```rust
// rust/mockmate-tts/src/traits.rs

pub struct TtsChunk {
    pub pcm: Vec<f32>,      // PCM f32 24kHz mono
    pub viseme_id: u8,       // 0=silence, 1–21=ARPABET-mapped
    pub offset_ms: u32,
}

#[async_trait]
pub trait TtsProvider: Send + Sync {
    async fn speak(
        &self,
        text: &str,
        voice_id: &str,
        tx: tokio::sync::mpsc::Sender<TtsChunk>,
    ) -> Result<()>;

    async fn list_voices(&self) -> Result<Vec<String>>;
    async fn warm_up(&self) -> Result<()>;
    fn provider_name(&self) -> &'static str;
}
```

| Implementation | Notes |
|---|---|
| `KokoroTts` | pure ONNX via `ort` (Apache 2.0); primary TTS — no subprocess, no platform binary, reuses existing `ort` dependency from Silero VAD |

### 2.2 LlmProvider

```rust
// rust/mockmate-llm/src/traits.rs

pub struct ChatMessage { pub role: String, pub content: String }
pub struct LlmConfig { pub temperature: f32, pub max_tokens: u32, pub model_id: String }

#[async_trait]
pub trait LlmProvider: Send + Sync {
    async fn chat_stream(
        &self,
        messages: &[ChatMessage],
        config: &LlmConfig,
        tx: tokio::sync::mpsc::Sender<String>,
    ) -> Result<()>;

    async fn chat_once(&self, messages: &[ChatMessage], config: &LlmConfig) -> Result<String>;
    async fn list_models(&self) -> Result<Vec<String>>;
    fn provider_name(&self) -> &'static str;
    fn supports_streaming(&self) -> bool { true }
}
```

| Implementation | Notes |
|---|---|
| `OllamaProvider` | `localhost:11434/api/chat`, manages `ollama serve` subprocess |
| `OpenAiProvider` | SSE streaming, BYOK API key |
| `AnthropicProvider` | SSE streaming, BYOK API key |

### 2.3 SttProvider

```rust
// rust/mockmate-audio/src/stt/traits.rs

pub struct TranscriptSegment {
    pub text: String, pub start_ms: u32, pub end_ms: u32, pub confidence: f32,
}

#[async_trait]
pub trait SttProvider: Send + Sync {
    async fn transcribe(&self, pcm_16k: &[f32]) -> Result<Vec<TranscriptSegment>>;
    async fn transcribe_stream(
        &self,
        audio_rx: tokio::sync::mpsc::Receiver<Vec<f32>>,
        tx: tokio::sync::mpsc::Sender<TranscriptSegment>,
    ) -> Result<()>;
    fn provider_name(&self) -> &'static str;
}
```

| Implementation | Notes |
|---|---|
| `WhisperStt` | `whisper-rs` bindings; 30s windows with 5s overlap for streaming |

### 2.4 VadProvider

```rust
// rust/mockmate-audio/src/vad/traits.rs
// Synchronous — runs in the hot audio callback loop, must stay under 5ms/frame

pub enum VadEvent {
    SpeechStart,
    SpeechEnd { duration_ms: u32 },
    Silence,
}

pub trait VadProvider: Send + Sync {
    fn process_frame(&mut self, frame: &[f32]) -> Result<Option<VadEvent>>;
    fn reset(&mut self);
    fn provider_name(&self) -> &'static str;
}
```

| Implementation | Notes |
|---|---|
| `SileroVad` | `ort` + `silero_vad.onnx`; stateful `h`/`c` tensors between frames |

### 2.5 VisemeExtractor

```rust
// rust/mockmate-viseme/src/traits.rs

pub struct VisemeFrame {
    pub viseme_id: u8, pub intensity: f32, pub offset_ms: u32, pub duration_ms: u32,
}

pub trait VisemeExtractor: Send + Sync {
    fn extract(&self, pcm: &[f32], sample_rate: u32, offset_ms: u32) -> Result<Vec<VisemeFrame>>;
    fn window_size(&self) -> usize;
}
```

| Implementation | Notes |
|---|---|
| `FftVisemeExtractor` | `rustfft` STFT over 20ms windows; F1/F2 formant → viseme lookup table; fallback for providers without phoneme output |

**Note:** Kokoro emits phoneme alignment data natively alongside audio. Use that for `TtsChunk.viseme_id` directly — far more accurate than FFT. `FftVisemeExtractor` is the fallback only for future TTS providers that do not emit phoneme data.

---

## 3. Flutter Rust Bridge API Surface

All bridge functions live in `rust/mockmate-core/src/bridge/`.

### Session Control (`api_session.rs`)

```rust
pub async fn init_session(config: SessionConfig) -> Result<()>;
pub async fn set_mode(mode: InterviewMode) -> Result<()>;
pub async fn load_knowledge_base(path: String) -> Result<KnowledgeBaseInfo>;
pub fn get_session_state() -> SessionStateSnapshot;
pub async fn shutdown_session() -> Result<()>;
pub async fn check_ollama_status() -> OllamaStatus;
pub fn pull_model(model_id: String) -> Stream<DownloadProgress>;
pub async fn validate_api_key(provider: ApiProvider, key: String) -> Result<bool>;
```

### LLM / Conversation (`api_llm.rs`)

```rust
pub fn send_message(text: String) -> Stream<LlmToken>;
pub fn cancel_generation();
pub fn get_conversation_history() -> Vec<ChatMessage>;
pub fn clear_history();

pub struct LlmToken { pub text: String, pub is_final: bool }
```

### Audio / TTS (`api_audio.rs`)

```rust
pub fn start_audio_pipeline() -> Stream<AudioPipelineEvent>;
pub fn stop_audio_pipeline();
pub fn speak_text(text: String, voice_id: String) -> Stream<TtsPlaybackEvent>;
pub fn interrupt_speech();
pub fn get_audio_levels() -> Stream<AudioLevel>;

pub enum AudioPipelineEvent {
    MicLevel { rms: f32 },
    SpeechDetected,
    SpeechEnded,
    TranscriptPartial { text: String },
    TranscriptFinal { text: String, confidence: f32 },
    UserInterrupted,
    Error { message: String },
}

pub struct TtsPlaybackEvent {
    pub viseme_id: u8, pub intensity: f32, pub offset_ms: u32, pub is_complete: bool,
}
```

### Avatar State (`api_avatar.rs`)

```rust
pub fn avatar_state_stream() -> Stream<AvatarState>;

pub struct AvatarState {
    pub viseme_id: u8, pub intensity: f32, pub expression: AvatarExpression, pub is_speaking: bool,
}

pub enum AvatarExpression { Neutral, Listening, Thinking, Speaking, Surprised }
```

`mockmate-core` merges the TTS viseme stream and VAD expression state machine into this single stream. Flutter subscribes once and renders whatever arrives.

---

## 4. Flutter Architecture

### State Management — Riverpod v2

| Provider | Type | Purpose |
|---|---|---|
| `sessionConfigProvider` | `StateNotifierProvider` | Mode, KB selection, provider choices, BYOK keys |
| `audioStreamProvider` | `StreamProvider` | Wraps `startAudioPipeline()` |
| `avatarStateStreamProvider` | `StreamProvider` | Wraps `avatarStateStream()` |
| `llmResponseStreamProvider` | `StreamProvider.family` | Fresh per user turn |
| `conversationProvider` | `StateNotifierProvider` | Accumulates transcript |
| `onboardingProvider` | `StateNotifierProvider` | Ollama status, model downloads, first-run state |

### Screens

**`OnboardingScreen`** — Wizard: (1) Check Ollama → (2) Pull model → (3) Select KB → (4) BYOK keys (optional). Skipped on subsequent launches if config is valid.

**`InterviewScreen`** — Three zones: `AvatarCanvas` (top 40%), `TranscriptPanel` (middle 40%), `InputControls` (bottom 20%). Listens on `audioStreamProvider` for `UserInterrupted` events.

**`SettingsScreen`** — BYOK key fields (`flutter_secure_storage`), TTS voice selector, model selector, theme toggle.

### Key Widgets

**`AvatarCanvas`** — `StreamSubscription<AvatarState>` + two render modes:
- **Sprite mode:** `AnimatedSwitcher` swapping `assets/avatar/sprites/viseme_{id}.png`
- **Rive mode:** `RiveAnimation.asset()` with `StateMachineController`, sets `viseme_id` + `intensity` inputs per event

**`WaveformWidget`** — `StreamBuilder<AudioLevel>`, `CustomPainter` with quadratic bezier path. Color transitions grey→amber via `ColorTween`.

**`TranscriptPanel`** — `ListView.builder` backed by `conversationProvider`. Auto-scrolls. Shows `ThreeDotsPulse` typing indicator while LLM stream is active.

### Bridge Service Layer

`lib/src/services/bridge_service.dart` wraps every FRB call with:
- Error boundary (`FfiException` → typed `AppError`)
- Logging via `dart:developer`
- Retry logic for transient network errors (BYOK providers)

---

## 5. Phased Build Order

### Phase 0 — Scaffolding (Week 1)

1. `flutter_rust_bridge_codegen create` to initialize project structure
2. Rust workspace with empty member crates
3. Verify codegen round-trip with a `ping() -> String` function
4. GitHub Actions CI matrix: `[windows-latest, macos-latest, ubuntu-latest]`

**Unblocks:** Everything.

### Phase 1 — Talk Engine / TTS (Weeks 2–3)

The system must be able to speak before anything else. No LLM, no mic — just text in, audio out.

1. `KokoroTts` implementation via `ort` (pure ONNX — reuses the same ONNX Runtime already needed for Silero VAD, no new deps)
2. cpal playback in `mockmate-audio/src/playback.rs`
3. Bridge: `speak_text(text, voice_id) -> Stream<TtsPlaybackEvent>` and `interrupt_speech()`
4. `TtsPlaybackEvent.viseme_id` field present but unused — set to `0` as placeholder for now
5. Minimal Flutter UI: text field → triggers `speak_text()` → plays audio. No avatar yet.
6. Verify audio output on all three platforms (WASAPI / CoreAudio / ALSA)

**Unblocks:** Phase 3 (VAD kill switch needs active TTS to interrupt), Phase 4 (BYOK TTS).

### Phase 2 — LLM Pipeline (Weeks 4–5)

1. `OllamaProvider` (pure HTTP, no native deps — lowest risk LLM start)
2. `InterviewSession` + `PromptBuilder` for Guide and Test/Socratic modes
3. `KnowledgeBase` loader from `assets/knowledge/`
4. Bridge: `send_message() -> Stream<LlmToken>`, `set_mode()`, `load_knowledge_base()`
5. Wire LLM token stream → TTS: as tokens arrive, buffer sentences and pass to `speak_text()`
6. Flutter UI: text input + transcript panel + mode toggle. No avatar, no mic — keyboard-driven loop.

**Unblocks:** Phase 3 (LLM cancellation via VAD), Phase 4 (BYOK LLM providers).

### Phase 3 — Audio Input + VAD Kill Switch (Weeks 6–7)

1. cpal capture ring buffer
2. Silero VAD integration (`ort` + bundled ONNX) — **highest risk phase**
3. Kill switch state machine in `AppState`: VAD `SpeechStart` while TTS playing → cancel TTS + LLM streams
4. `WhisperStt` with bundled `whisper-tiny.en.bin`
5. Full hands-free loop: mic → VAD → (kill switch OR STT) → `send_message()` → LLM → TTS
6. Bridge: `start_audio_pipeline() -> Stream<AudioPipelineEvent>`
7. Flutter: `WaveformWidget` for mic level; `TranscriptPanel` receives `TranscriptFinal` events

**Unblocks:** Phase 4 (fully automated hands-free conversation).

### Phase 4 — BYOK Providers + Onboarding (Weeks 8–9)

1. `OpenAiProvider`, `AnthropicProvider` (BYOK LLM — user supplies own API key)
2. `OnboardingScreen`: Ollama health check + model pull progress + BYOK key entry
4. `SettingsScreen`: provider selection, voice selector, model selector
5. `validate_api_key()` bridge function
6. Wire provider selection from settings into `AppState` at `init_session()`

**Unblocks:** Phase 5 (FFT viseme path needed when TTS provider has no native phoneme output).

### Phase 5 — Viseme + Avatar (Weeks 10–11)

All conversation mechanics are solid by this point. Viseme and avatar are pure presentation layer.

1. `FftVisemeExtractor` — `rustfft` STFT over 20ms windows; F1/F2 formant → viseme lookup table
2. Wire viseme extraction into the TTS pipeline; populate `TtsPlaybackEvent.viseme_id` for real
3. Use Kokoro's native phoneme alignment output instead of FFT for accurate viseme timing
4. `AvatarCanvas` widget: sprite mode with production 2D art per viseme ID (0–21)
5. Optional: Rive skeletal animation via `RiveAnimation.asset()` + `StateMachineController`
6. `avatar_state_stream()` bridge: merge TTS viseme stream + VAD expression state machine
7. Profile for 60fps rendering and 50Hz viseme event throughput
8. Full skeuomorphic `CustomPainter` theme + `InterviewScreen` final layout
9. Cross-platform packaging: `flutter build windows`, `flutter build macos`, `flutter build linux`

---

## 6. Testing Strategy

### Rust Unit Tests (per crate)

| Crate | What to test |
|---|---|
| `mockmate-tts` | `KokoroTts::speak()` produces non-empty PCM; `TtsChunk` sequence covers full input duration |
| `mockmate-viseme` | Golden file: sine waves at vowel formants → expected viseme IDs; window boundary handling |
| `mockmate-llm` | `wiremock-rs` mocks for Ollama + OpenAI; streaming token assembly; cancellation via dropped receiver |
| `mockmate-audio` (VAD) | Silence → no `SpeechStart`; speech clip → `SpeechStart` + `SpeechEnd`; speech-while-speaking → `UserInterrupted` |
| `mockmate-session` | Guide mode prompt contains `<KNOWLEDGE_BASE>` tags; Test mode has Socratic instructions; hash prevents unnecessary rebuilds |

### Rust Integration Tests

- Full pipeline with mock providers: `MockLlmProvider` → `MockTtsProvider` → `FftVisemeExtractor` → valid `AvatarState` stream
- Kill switch mid-generation: assert both LLM and TTS streams terminate cleanly

### Flutter Widget Tests

- `AvatarCanvas` renders correct sprite per viseme ID
- `TranscriptPanel` auto-scrolls on new message
- `ModeToggle` calls `BridgeService.setMode()` on tap (`mockito` stub)
- `OnboardingScreen` shows progress bar for `DownloadProgress` events

### End-to-End Tests (scheduled CI, not every PR)

- Inject pre-recorded WAV as simulated mic input into ring buffer via test seam
- Assert STT transcript, LLM context, and TTS non-silent output

---

## 7. Technical Risks and Mitigations

### Risk 1: `ort` cross-platform build

**Problem:** ONNX Runtime shared libraries differ per platform; must be bundled or downloaded.

**Mitigation:** Use `ort`'s `download-binaries` feature. Pin to ONNX Runtime 1.18. Cache binary in CI.

---

### Risk 2: Silero VAD latency (must be < 5ms per 30ms frame)

**Problem:** ONNX inference on CPU-only may exceed budget.

**Mitigation:** Run in `tokio::task::spawn_blocking`. Pre-allocate all tensors at startup. Measure on reference hardware (i5-8250U, no GPU). Fallback: RMS energy-based VAD (compute RMS of 30ms frame, threshold at -40dBFS) as a feature-flag option.

---

### Risk 3: `whisper-rs` crate maintenance

**Problem:** Community crate; may lag upstream or fail on MSVC (Windows).

**Mitigation:** Pin to specific commit. Test MSVC build in CI Phase 3. The `SttProvider` trait allows swapping to `vosk-rs` or cloud STT (Deepgram BYOK) with zero changes elsewhere.

---

### Risk 4: FRB Stream backpressure (viseme at ~50 events/sec)

**Problem:** Slow Flutter frame may cause channel fill and Rust blocking.

**Mitigation:** Bounded channel with capacity 200 (~4s buffer). Rust: treat `tx.send()` error as cancellation. Flutter: discard viseme frames > 100ms late.

---

### Risk 5: Kokoro ONNX model size and first-run download

**Problem:** Kokoro voice model weights (~300MB per voice) cannot be bundled in the app binary. First run requires a download, and offline-first is a stated goal.

**Mitigation:** Bundle a single default voice (smallest Kokoro ONNX voice, ~80MB) in `assets/models/` for true offline first-run. Additional voices are downloaded on demand via the onboarding wizard. Show a clear progress indicator and allow the user to proceed with the bundled voice if the download fails.

---

### Risk 6: Ollama not installed

**Problem:** Most users won't have Ollama.

**Mitigation:** `OnboardingScreen` detects absence, shows "Install Ollama" button (OS browser). App falls back to BYOK mode if API key is present. "Demo mode" with canned responses if neither is configured.

---

### Risk 7: `rustfft` viseme accuracy

**Problem:** FFT formant analysis is noisy; may not drive convincing lip sync.

**Mitigation:** Apply exponential moving average smoothing on `intensity` (alpha=0.4). Kokoro emits phoneme alignment data natively — prefer that over FFT. `FftVisemeExtractor` is only the fallback for future no-phoneme TTS providers.

---

### Risk 8: 2000-line KB exceeds small model context windows

**Problem:** ~30K tokens; exceeds Gemma 3 1B (8K) and is tight for Qwen 2.5 3B (32K).

**Mitigation:** `KnowledgeBase::chunk_for_model()` selects top-K relevant chunks via TF-IDF against user query (pure Rust, no vector DB). Default recommended model: `qwen2.5:7b-instruct-q4_K_M` (~4.5GB, 128K context). Surface as recommended in onboarding with "lite" options for 4GB VRAM.

---

## 8. Critical Files (Implementation Priority)

| File | Why critical |
|---|---|
| `rust/mockmate-core/src/state.rs` | `AppState` holds all `Arc<dyn Trait>` provider handles and the VAD kill switch `CancellationToken` — nearly every module touches this |
| `rust/mockmate-core/src/bridge/api_audio.rs` | FRB bridge for VAD kill switch, TTS playback, and `TtsPlaybackEvent` stream driving viseme sync |
| `rust/mockmate-audio/src/vad/silero.rs` | Highest-risk file: stateful ONNX inference in the hot audio path with `h`/`c` tensor management |
| `rust/mockmate-session/src/prompt_builder.rs` | XML system prompt construction + KV cache hash invalidation — directly determines LLM response latency |
| `lib/src/ui/widgets/avatar_canvas.dart` | Primary user-facing deliverable; sprite vs. Rive mode decision and the `StreamBuilder<AvatarState>` rendering loop |

---

## Phase 7 — AI-Conducted Coding Interview UI

> Build this before Phase 8. Ship the product before packaging it.

### Goal

The AI **conducts** the coding interview as the interviewer — not an assistant on the side. It asks the question via TTS + avatar, gives Socratic hints (never the solution), tracks time, runs all hidden test cases when the session ends, and delivers a structured evaluation report.

**Future hooks (not in v7 scope but architecture must not block):** voice clarity scoring, pronunciation feedback, stress/affect detection via avatar, attention-to-detail patterns.

### Interview Session Flow

```
1. START
   ├─ AI reads question aloud (TTS + avatar) + displays in left panel
   ├─ Timer starts (configurable: 20 / 30 / 45 min)
   └─ AI: "Take your time. Ask me when you have clarifying questions."

2. ACTIVE CODING
   ├─ Candidate codes in middle panel
   ├─ Candidate messages AI → AI responds as interviewer:
   │    - Clarifying questions → answered directly
   │    - Hint requests → 3 Socratic levels only:
   │        L1: nudge toward approach ("think about O(1) lookup")
   │        L2: name the data structure/algorithm
   │        L3: pseudocode outline — never actual code
   │    - AI proactively asks: "What's the time complexity?" / "Any edge cases?"
   └─ Timer visible in AppBar, turns red at 5 min remaining

3. TIME UP (or early submit)
   ├─ CodeExecutor runs all hidden test cases
   └─ AI receives: question + code + test results → generates evaluation report

4. EVALUATION REPORT
   ├─ Test results: X/Y passed, per-case pass/fail table
   ├─ Correctness score + approach quality (optimal? trade-offs?)
   ├─ Code quality (naming, structure, edge cases handled)
   ├─ Communication score (clarifying questions, thinking aloud, hint usage)
   ├─ Overall: Strong Hire / Hire / No Hire / Strong No Hire
   └─ [Future] Voice/affect/pronunciation notes placeholder
```

### New Files

```
assets/questions/
  two_sum.json
  reverse_linked_list.json
  valid_parentheses.json

lib/src/interview/
  models/
    interview_question.dart      # InterviewQuestion + TestCase (visible + hidden)
    execution_result.dart        # { stdout, stderr, exitCode, timedOut, elapsed }
    runtime_info.dart            # { language, installed, version, executablePath }
    interview_session.dart       # { question, startedAt, messages, codeSnapshots }
    evaluation_report.dart       # { testResults, scores, aiNarrative, recommendation }
  services/
    runtime_detector.dart        # detect installed runtimes per language + platform
    runtime_installer.dart       # download + silent install missing runtimes
    code_executor.dart           # write temp → compile → run → ExecutionResult
    interview_conductor.dart     # builds AI system prompt + evaluation prompt
  interview_provider.dart        # sessionState, timer, messages, runResults, report
  interview_page.dart            # 3-panel scaffold + timer in AppBar
  widgets/
    question_panel.dart          # left: title, difficulty, description, examples
    code_panel.dart              # middle: CodeField + language selector + runtime chip
    interviewer_panel.dart       # right: AvatarWidget + transcript + mic/text input
    session_timer.dart           # countdown chip, red at 5 min
    evaluation_report_view.dart  # full-screen report after session ends
    runtime_status_chip.dart     # "Python 3.11 ✓" or "JDK 21 — Install"
    runtime_install_dialog.dart  # download progress bar dialog
    difficulty_badge.dart
    language_selector.dart
```

### 3-Panel Layout

```
┌──────────────┬──────────────────────┬──────────────────┐
│  Question    │   Code Editor        │  AI Interviewer  │
│  (300px)     │   (flex 3)           │  (flex 2)        │
│              │                      │                  │
│  title       │  [lang] [runtime ✓]  │  [AvatarWidget]  │
│  difficulty  │                      │  conversation    │
│  description │  CodeField           │  transcript      │
│  examples    │                      │                  │
│  constraints │                      │  [text] [🎙]     │
└──────────────┴──────────────────────┴──────────────────┘
                    [timer]  [Submit Early]   ← AppBar
```

**InterviewerPanel** reuses `AvatarWidget`, `bridge.chat()` with the interviewer system prompt, and `bridge.processAudioTurn()` for voice. No new Rust bridge functions needed.

### AI System Prompt (`interview_conductor.dart`)

```dart
String buildInterviewerPrompt(InterviewQuestion q) => '''
You are a senior software engineer conducting a coding interview at a top tech company.

QUESTION YOU HAVE GIVEN THE CANDIDATE:
${q.title} (${q.difficulty})
${q.description}

EXPECTED SOLUTIONS (for your reference only — never share):
${q.solutionNotes}

YOUR ROLE:
- Guide, never solve. Never write or dictate code.
- Hint levels: L1 → approach nudge, L2 → name the algorithm, L3 → pseudocode only.
- Ask probing questions: time complexity, edge cases, alternative approaches.
- Track communication: is candidate thinking aloud, asking good questions?
''';
```

**Evaluation prompt** (sent when timer expires or candidate submits):

```dart
String buildEvaluationPrompt(
  InterviewQuestion q, String code, String language,
  List<TestCaseResult> results, List<String> conversationSummary,
) => '''
Session ended. Evaluate the candidate.
CODE (${language}): ${code}
TEST RESULTS:
${results.map((r) => '${r.label}: ${r.passed ? "PASS" : "FAIL"} | expected: ${r.expected} | got: ${r.actual}').join('\n')}
CONVERSATION: ${conversationSummary.join('\n')}

Structured evaluation:
1. Test Score: X/${results.length}
2. Correctness analysis
3. Approach (optimal? trade-offs?)
4. Code quality (naming, structure, edge cases)
5. Communication score
6. Overall: Strong Hire / Hire / No Hire / Strong No Hire
7. Top 3 improvement areas
''';
```

### Question JSON Format

```json
{
  "id": "two-sum",
  "title": "Two Sum",
  "difficulty": "easy",
  "tags": ["array", "hash-table"],
  "description": "Given nums and target, return indices of two numbers that add up to target.",
  "examples": [{ "input": "nums=[2,7,11,15], target=9", "output": "[0,1]" }],
  "constraints": ["2 <= nums.length <= 10^4"],
  "starter_code": {
    "python": "def twoSum(self, nums, target):\n    pass",
    "javascript": "var twoSum = function(nums, target) {};",
    "java": "public int[] twoSum(int[] nums, int target) {}",
    "go": "func twoSum(nums []int, target int) []int {}",
    "cpp": "vector<int> twoSum(vector<int>& nums, int target) {}"
  },
  "hidden_tests": [
    { "label": "TC1", "stdin": "4\n2 7 11 15\n9", "expected_stdout": "0 1" },
    { "label": "TC2", "stdin": "2\n3 3\n6",        "expected_stdout": "0 1" }
  ],
  "solution_notes": "Optimal: HashMap O(n). Brute: nested loops O(n²)."
}
```

> `hidden_tests` and `solution_notes` are never shown in the UI.

### Runtime Detection + Auto-Install (IntelliJ-style)

Language change → `RuntimeDetector.detect(lang)` runs in background → chip shows result:
- `"Python 3.11 ✓"` (green) → Run enabled
- `"JDK 21 — Install"` (amber, tappable) → `RuntimeInstallDialog` → silent install

**Silent install per platform:**
```
Python 3.11  → python.org .exe      /quiet
JDK 21       → Temurin .msi         /quiet
Node 20 LTS  → nodejs.org .msi      /quiet
Go 1.22      → go.dev .msi          /quiet
C++ (MinGW)  → portable .7z extract → {appSupport}/mingw64
```

### Code Executor (`code_executor.dart`)

Real compilation + execution via `dart:io` Process. No Rust changes.

```
Python:  python3 tempfile.py     < stdin   (10s timeout)
JS:      node tempfile.js        < stdin
Java:    javac + java -cp tmpDir < stdin
Go:      go run tempfile.go      < stdin
C++:     g++ -o a.out + ./a.out  < stdin
```

### Session State Machine

```dart
enum SessionState { notStarted, active, submitting, evaluating, complete }
```

### Existing File Changes

| File | Change |
|------|--------|
| `lib/main.dart` | `nextPage: ChatPage()` → `nextPage: HomeScreen()` |
| `lib/src/chat/chat_page.dart` | Extract `_MessageBubble` → `lib/src/chat/widgets/message_bubble.dart` |
| `pubspec.yaml` | Add `flutter_code_editor: ^0.3.2`, `flutter_highlight: ^0.7.0`, `assets/questions/` |

**`HomeScreen`:** two buttons — "General Interview" → `ChatPage`, "Coding Interview" → `InterviewPage`.

### Build Steps (7A → 7G)

| Step | Work |
|------|------|
| 7A | Question JSON + `InterviewQuestion` / `ExecutionResult` / `RuntimeInfo` models |
| 7B | `RuntimeDetector` + `RuntimeInstaller` |
| 7C | `CodeExecutor` — compile + run per language |
| 7D | `InterviewConductor` — system + evaluation prompts |
| 7E | 3-panel `InterviewPage` + all panel widgets |
| 7F | `SessionTimer` + state machine + `EvaluationReportView` |
| 7G | `HomeScreen` + wire `main.dart` |

---

## Phase 8 — One-Click Distribution (Installer + Sidecar)

> Built after Phase 7. Installer scope is clearer once all runtime dependencies are known.

### Goal

User downloads one installer. App detects/installs Ollama automatically, shows a curated model catalog, downloads piper + whisper on first run. Zero terminal usage.

### New Rust Crate: `mockmate-sidecar`

`rust/mockmate-sidecar/src/ollama_sidecar.rs`:

```rust
pub async fn is_ollama_running(base_url: &str) -> bool
pub async fn start_ollama(bin_path: &str) -> Result<bool>  // spawn + poll 8s
pub fn stop_ollama()                                         // kill child + wait
pub fn get_status() -> String                                // "running"|"stopped"|"error:…"
```

- `OnceLock<Mutex<Option<Child>>>` holds process handle
- Windows: `CREATE_NO_WINDOW` (no console popup)
- Ollama already running externally → skip spawn, return `Ok(true)`

**Bridge additions** (`rust/mockmate-bridge/src/bridge.rs`):
```rust
pub async fn start_ollama_sidecar(bin_path: String) -> bool
pub fn stop_ollama_sidecar()
pub fn get_sidecar_status() -> String
```
Requires FRB codegen re-run.

### Updated Onboarding Wizard

1. `llmModeStep` — "Run Locally (Ollama)" vs "Cloud API (BYOK)"
2. If local → `ollamaDetectStep`:
   - Running → skip to step 4
   - Installed, not running → start sidecar → skip to step 4
   - Not installed → **"Install Ollama"** button → download + run platform installer → poll until healthy
3. `modelCatalogStep` — model cards with VRAM bar + "Free for Enterprise" badge (Apache 2.0/MIT):

| Model | Vendor | License | VRAM |
|-------|--------|---------|------|
| gemma3:4b | Google | Apache 2.0 ✓ | 3.0 GB |
| gemma3:12b | Google | Apache 2.0 ✓ | 8.0 GB |
| phi4-mini | Microsoft | MIT ✓ | 3.5 GB |
| qwen2.5:7b-instruct-q4_K_M | Alibaba | Apache 2.0 ✓ | 4.5 GB |
| mistral:7b | Mistral AI | Apache 2.0 ✓ | 4.5 GB |
| llama3.2:3b | Meta | Meta Community | 2.5 GB |

4. `installProgressStep` — pull model + download piper + whisper with per-item progress bars
5. → `HomeScreen`

If BYOK → existing Settings screen, no Ollama needed.

### AppConfig (`{appSupportDir}/mockmate_config.json`)

```json
{
  "llm_mode": "local",
  "ollama_bin_path": "/usr/local/bin/ollama",
  "ollama_model": "gemma3:4b",
  "whisper_bin_path": "{appSupport}/bin/whisper-cli",
  "whisper_model_path": "{appSupport}/models/ggml-base.en.bin",
  "piper_bin_path": "{appSupport}/bin/piper",
  "piper_model_path": "{appSupport}/models/en_US-lessac-medium.onnx"
}
```

### Inno Setup (`installer/windows/mockmate.iss`)

- Installs Flutter app bundle to `{pf}\MockMate`
- Does NOT bundle Ollama, models, or runtimes — handled by first-run wizard
- Writes uninstall registry key

### `pubspec.yaml` additions
```yaml
path_provider: ^2.1.4
http: ^1.2.0
```

### Build Steps (8A → 8E)

| Step | Work |
|------|------|
| 8A | `AppConfig` + `ConfigService` |
| 8B | `mockmate-sidecar` Rust crate + 3 bridge fns + FRB codegen |
| 8C | `OllamaInstaller` + `ModelCatalog` + updated wizard steps |
| 8D | Inno Setup `.iss` |
| 8E | Integration tests: sidecar lifecycle + full session flow |
