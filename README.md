# MockMate

AI mock interview coach that runs entirely on your machine. Ask it questions, practice coding interviews, get evaluated — no cloud required, no data leaves your device.

---

## What it does

**General Interview** — conversational practice with a knowledge base you supply. The AI asks questions, listens to your answers, gives Socratic hints, and adapts to your level.

**Coding Interview** — the AI acts as the interviewer. It reads you a coding question aloud, watches you code in a 3-panel editor (question / code / interviewer), answers clarifying questions with hints only (never the solution), runs all hidden test cases when time is up, and delivers a structured evaluation report (test score, approach quality, communication, hire/no-hire recommendation).

---

## Quick start (Windows)

1. **Download** `MockMateSetup.exe` from [Releases](../../releases) and run it.
2. **Launch MockMate.** The setup wizard opens automatically on first run.
3. **Choose "Run Locally (Ollama)"** — the wizard detects Ollama, installs it if missing, lets you pick a model, and pulls it. Takes a few minutes on first run.
4. **Start practicing.**

That's it. No terminal, no manual installs.

---

## Manual install (build from source)

### Requirements

| Tool | Version |
|------|---------|
| Flutter | SDK `^3.11.0-200.1.beta` |
| Rust | stable 1.76+ (`rustup`) |

Ollama, Whisper, and Piper are detected and installed by the in-app wizard — you don't need to install them manually.

### Steps

```sh
git clone <repo-url>
cd MockMate
flutter pub get
flutter run -d windows   # or macos / linux
```

Rust compiles automatically on `flutter run` via Flutter's native assets hook.

---

## First-run wizard

The wizard walks you through 4 steps:

| Step | What happens |
|------|-------------|
| **Mode** | Choose local Ollama or cloud API (BYOK) |
| **Ollama** | Detected automatically; installed silently if missing |
| **Model** | Pick from 6 curated models (Apache 2.0 / MIT); pulled via Ollama |
| **Installing** | Pull progress shown; navigates to home when done |

If you choose **Cloud API**, the wizard skips to the app immediately — enter your API key in Settings.

---

## Supported models (local)

| Model | VRAM | License | Notes |
|-------|------|---------|-------|
| gemma3:4b | 3.0 GB | Apache 2.0 | Recommended — fast, 128 K context |
| gemma3:12b | 8.0 GB | Apache 2.0 | Better quality |
| phi4-mini | 3.5 GB | MIT | Compact |
| qwen2.5:7b-instruct-q4_K_M | 4.5 GB | Apache 2.0 | Great for long knowledge bases |
| mistral:7b | 4.5 GB | Apache 2.0 | Strong reasoning |
| llama3.2:3b | 2.5 GB | Meta Community | Lightest option |

---

## Adding your own knowledge base

Drop `.txt` or `.md` files into `assets/kb/`. MockMate loads all files in that folder as the interview context.

```
assets/kb/system-design.txt
assets/kb/behavioral-questions.md
```

---

## Cloud API (BYOK)

Open **Settings** (gear icon) and paste your key. Supported:

| Provider | Used for |
|----------|----------|
| OpenAI | LLM (GPT-4o, etc.) |
| Anthropic | LLM (Claude) |
| ElevenLabs | TTS voice |

---

## Run tests

```sh
# Rust (all crates including sidecar)
cargo test --manifest-path rust/Cargo.toml

# Flutter
flutter test
```

---

## Building the Windows installer

Requires [Inno Setup 6+](https://jrsoftware.org/isinfo.php).

```sh
flutter build windows --release
iscc installer\windows\mockmate.iss
# Output: installer\windows\output\MockMateSetup-1.0.0.exe
```
