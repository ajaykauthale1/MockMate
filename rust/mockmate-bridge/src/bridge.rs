use std::sync::{Arc, Mutex, OnceLock};

use crate::frb_generated::StreamSink;
use mockmate_core::{
    prompt::build_system_prompt,
    providers::{InteractionMode, Viseme},
    state::AppState,
};
use mockmate_llm::OllamaLlm;
use mockmate_viseme::FftVisemeExtractor;

// ---------------------------------------------------------------------------
// AvatarState stream — unified VAD + TTS viseme events for the Flutter avatar
// ---------------------------------------------------------------------------

/// Snapshot of avatar animation state pushed to Flutter on every change.
pub struct AvatarState {
    /// Current mouth-shape viseme (0 = closed / idle).
    pub viseme_id: u8,
    /// `true` while VAD detects the user speaking.
    pub is_listening: bool,
    /// `true` while the AI's TTS audio is (notionally) playing.
    pub is_speaking: bool,
}

static AVATAR_SINK: OnceLock<Mutex<Option<StreamSink<AvatarState>>>> = OnceLock::new();

fn avatar_sink() -> &'static Mutex<Option<StreamSink<AvatarState>>> {
    AVATAR_SINK.get_or_init(|| Mutex::new(None))
}

fn push_avatar(state: AvatarState) {
    if let Ok(guard) = avatar_sink().lock() {
        if let Some(sink) = guard.as_ref() {
            let _ = sink.add(state);
        }
    }
}

/// Subscribe to avatar state events.
///
/// Call once from Flutter on startup.  The stream emits an [`AvatarState`]
/// whenever VAD or TTS state changes.  Viseme events are timed to match the
/// synthesised audio duration so the avatar mouth is synchronised with
/// playback without a separate timer on the Dart side.
pub fn avatar_state_stream(sink: StreamSink<AvatarState>) {
    *avatar_sink().lock().unwrap() = Some(sink);
}

/// Spawn a background task that emits per-viseme states at their timestamps.
fn spawn_viseme_playback(visemes: Vec<Viseme>) {
    tokio::spawn(async move {
        use tokio::time::{sleep, Duration};

        push_avatar(AvatarState {
            viseme_id: 0,
            is_listening: false,
            is_speaking: true,
        });

        let mut prev_ms = 0u32;
        for v in &visemes {
            let delay = v.timestamp_ms.saturating_sub(prev_ms);
            if delay > 0 {
                sleep(Duration::from_millis(u64::from(delay))).await;
            }
            push_avatar(AvatarState {
                viseme_id: v.id,
                is_listening: false,
                is_speaking: true,
            });
            prev_ms = v.timestamp_ms;
        }

        push_avatar(AvatarState {
            viseme_id: 0,
            is_listening: false,
            is_speaking: false,
        });
    });
}

// ---------------------------------------------------------------------------
// Global state — Arc<AppState> so it can be cheaply shared with SessionManager.
// STT and VAD start as no-op stubs; Flutter calls init_* to upgrade them.
// TTS starts as a stub; init_piper_tts / init_elevenlabs_tts upgrades it.
// Viseme uses FftVisemeExtractor immediately (no model needed).
// ---------------------------------------------------------------------------

static APP_STATE: OnceLock<Arc<AppState>> = OnceLock::new();

fn state() -> &'static Arc<AppState> {
    APP_STATE.get_or_init(|| {
        use anyhow::Result;
        use async_trait::async_trait;
        use mockmate_core::providers::{SttProvider, TtsProvider, VadProvider};

        struct StubTts;
        struct StubStt;
        struct StubVad;

        #[async_trait]
        impl TtsProvider for StubTts {
            async fn synthesise(&self, _: &str) -> Result<Vec<u8>> { Ok(vec![]) }
        }
        #[async_trait]
        impl SttProvider for StubStt {
            async fn transcribe(&self, _: &[u8]) -> Result<String> { Ok(String::new()) }
        }
        #[async_trait]
        impl VadProvider for StubVad {
            async fn is_speech(&self, _: &[f32]) -> Result<bool> { Ok(false) }
        }

        Arc::new(AppState::new(
            Arc::new(OllamaLlm::new(None, None)),
            Arc::new(StubStt),
            Arc::new(StubTts),
            Arc::new(StubVad),
            Arc::new(FftVisemeExtractor::new(16_000)),
        ))
    })
}

// ---------------------------------------------------------------------------
// Phase 2 bridge functions
// ---------------------------------------------------------------------------

/// Load (or replace) the knowledge base text in Rust AppState.
pub async fn load_knowledge_base(text: String) {
    state().set_knowledge_base(text).await;
}

/// Switch interaction mode. `is_test = true` → Test/Tutor, false → Guide.
pub async fn set_interaction_mode(is_test: bool) {
    let mode = if is_test { InteractionMode::Test } else { InteractionMode::Guide };
    state().set_mode(mode).await;
}

/// Check whether Ollama is running and the default model is available.
pub async fn ollama_health_check() -> bool {
    OllamaLlm::new(None, None).health_check().await.unwrap_or(false)
}

/// Send a user message and get the full LLM response using the current KB + mode.
pub async fn chat(user_message: String) -> String {
    let s = state();
    let kb = s.knowledge_base.lock().await.clone();
    let mode = *s.mode.lock().await;
    let system = build_system_prompt(mode, &kb);

    match s.llm.read().await.chat(&system, &user_message).await {
        Err(e) => format!("error: {e}"),
        Ok(mut rx) => {
            let mut response = String::new();
            while let Some(result) = rx.recv().await {
                match result {
                    Ok(token) => response.push_str(&token),
                    Err(e) => {
                        response.push_str(&format!("\nerror: {e}"));
                        break;
                    }
                }
            }
            response
        }
    }
}

/// Pull the default Ollama model, returning all status lines.
pub async fn ollama_pull_model() -> Vec<String> {
    let llm = OllamaLlm::new(None, None);
    match llm.pull_model().await {
        Err(_) => vec!["error: could not connect to Ollama".to_string()],
        Ok(mut rx) => {
            let mut statuses = Vec::new();
            while let Some(result) = rx.recv().await {
                match result {
                    Ok(s) => statuses.push(s),
                    Err(e) => {
                        statuses.push(format!("error: {e}"));
                        break;
                    }
                }
            }
            statuses
        }
    }
}

// ---------------------------------------------------------------------------
// Phase 3 — provider initialisation
// ---------------------------------------------------------------------------

/// Initialise the Whisper STT provider.
/// `whisper_bin` = path to whisper-cli executable; `model_path` = GGML model.
/// Returns `true` on success, `false` if either path is invalid.
pub async fn init_whisper_stt(whisper_bin: String, model_path: String) -> bool {
    match mockmate_audio::WhisperStt::new(&whisper_bin, &model_path) {
        Ok(stt) => { state().set_stt(Arc::new(stt)).await; true }
        Err(e) => { tracing::error!("init_whisper_stt: {e}"); false }
    }
}

/// Initialise the Silero VAD provider.
/// Returns `true` on success.
pub async fn init_silero_vad(model_path: String) -> bool {
    match mockmate_audio::SileroVad::new(&model_path) {
        Ok(vad) => { state().set_vad(Arc::new(vad)).await; true }
        Err(e) => { tracing::error!("init_silero_vad: {e}"); false }
    }
}

/// Initialise Kokoro-82M TTS (ONNX-native, no subprocess for inference).
///
/// * `model_path`  — path to `kokoro-v0_19.onnx`
/// * `style_path`  — raw binary file of exactly 1 024 bytes (256 × f32 LE),
///                   one speaker embedding extracted from `voices.bin`
/// * `espeak_bin`  — path to the `espeak-ng` executable (used for phonemisation)
pub async fn init_kokoro_tts(model_path: String, style_path: String, espeak_bin: String) -> bool {
    match mockmate_tts::KokoroTts::new(&model_path, &style_path, &espeak_bin) {
        Ok(tts) => { state().set_tts(Arc::new(tts)).await; true }
        Err(e) => { tracing::error!("init_kokoro_tts: {e}"); false }
    }
}

/// Initialise Piper TTS.
/// `piper_bin` = path to the piper executable; `model_path` = ONNX model.
pub async fn init_piper_tts(piper_bin: String, model_path: String) -> bool {
    state().set_tts(Arc::new(mockmate_tts::PiperTts::new(piper_bin, model_path))).await;
    true
}

/// Initialise ElevenLabs TTS (BYOK).
pub async fn init_elevenlabs_tts(api_key: String, voice_id: String) -> bool {
    state().set_tts(Arc::new(mockmate_tts::ElevenLabsTts::new(api_key, voice_id))).await;
    true
}

// ---------------------------------------------------------------------------
// Phase 3 — audio pipeline bridge functions
// ---------------------------------------------------------------------------

/// Transcribe f32 LE PCM bytes (16 kHz mono) to text.
pub async fn transcribe_audio(pcm_bytes: Vec<u8>) -> String {
    match state().stt.read().await.transcribe(&pcm_bytes).await {
        Ok(text) => text,
        Err(e) => format!("error: {e}"),
    }
}

/// Synthesise text to f32 LE PCM bytes using the current TTS provider.
pub async fn synthesise_text(text: String) -> Vec<u8> {
    state().tts.read().await.synthesise(&text).await.unwrap_or_default()
}

/// Extract viseme frames from f32 LE PCM bytes.
/// Returns JSON-serialised `Vec<Viseme>`, or `"[]"` on error.
pub async fn extract_visemes(pcm_bytes: Vec<u8>) -> String {
    match state().viseme.read().await.extract(&pcm_bytes).await {
        Ok(v) => serde_json::to_string(&v).unwrap_or_else(|_| "[]".to_string()),
        Err(e) => { tracing::error!("extract_visemes: {e}"); "[]".to_string() }
    }
}

/// Run the full audio turn pipeline: VAD → STT → LLM → TTS → Viseme.
/// Returns JSON: `{ transcript, response, visemes }` or `{ error }`.
///
/// Also drives the [`avatar_state_stream`]: pushes `is_listening` at the start
/// and hands off to `spawn_viseme_playback` on success so the avatar animates
/// without any Flutter-side timer.
pub async fn process_audio_turn(pcm_bytes: Vec<u8>) -> String {
    use mockmate_session::SessionManager;

    let samples: Vec<f32> = pcm_bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();

    push_avatar(AvatarState { viseme_id: 0, is_listening: true, is_speaking: false });

    let mgr = SessionManager::new(Arc::clone(state()));
    match mgr.process_audio(&samples).await {
        Ok(r) => {
            spawn_viseme_playback(r.visemes.clone());

            let visemes_json =
                serde_json::to_string(&r.visemes).unwrap_or_else(|_| "[]".to_string());
            serde_json::json!({
                "transcript": r.transcript,
                "response":   r.response_text,
                "visemes":    visemes_json,
            })
            .to_string()
        }
        Err(e) => {
            push_avatar(AvatarState { viseme_id: 0, is_listening: false, is_speaking: false });
            serde_json::json!({ "error": e.to_string() }).to_string()
        }
    }
}
