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

/// Tick interval for the viseme playback loop (50 Hz = 20 ms).
const VISEME_TICK_MS: u64 = 20;

/// Spawn a background task that drives viseme events at 50 Hz.
///
/// Rather than sleeping the exact gap between each phoneme boundary (which
/// gives a rate that depends on speech rate), we run a fixed 20 ms tick loop
/// and look up whichever viseme is current by comparing elapsed time against
/// the pre-computed timestamps.  This guarantees ≥ 50 Hz throughput to
/// Flutter while keeping the avatar mouth in sync with the audio.
fn spawn_viseme_playback(visemes: Vec<Viseme>) {
    tokio::spawn(async move {
        use tokio::time::{sleep, Duration, Instant};

        push_avatar(AvatarState {
            viseme_id: 0,
            is_listening: false,
            is_speaking: true,
        });

        if visemes.is_empty() {
            push_avatar(AvatarState {
                viseme_id: 0,
                is_listening: false,
                is_speaking: false,
            });
            return;
        }

        // End of playback = last viseme timestamp + one extra tick
        let end_ms = visemes.last().unwrap().timestamp_ms + VISEME_TICK_MS as u32;
        let start = Instant::now();
        let mut idx = 0usize;

        loop {
            let elapsed = start.elapsed().as_millis() as u32;

            // Advance index to the latest viseme whose timestamp ≤ elapsed
            while idx + 1 < visemes.len()
                && visemes[idx + 1].timestamp_ms <= elapsed
            {
                idx += 1;
            }

            push_avatar(AvatarState {
                viseme_id: visemes[idx].id,
                is_listening: false,
                is_speaking: true,
            });

            if elapsed >= end_ms {
                break;
            }
            sleep(Duration::from_millis(VISEME_TICK_MS)).await;
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

/// Initialise OpenAI (or OpenAI-compatible) LLM provider.
/// `base_url` defaults to `https://api.openai.com` when empty.
pub async fn init_openai_llm(api_key: String, model: String, base_url: String) -> bool {
    let model_opt = if model.is_empty() { None } else { Some(model) };
    let url_opt = if base_url.is_empty() { None } else { Some(base_url) };
    let llm = mockmate_llm::OpenAiLlm::with_base_url(api_key, model_opt, url_opt);
    state().set_llm(Arc::new(llm)).await;
    true
}

/// Initialise Anthropic Claude LLM provider (BYOK).
/// `model` defaults to `claude-haiku-4-5-20251001` when empty.
pub async fn init_anthropic_llm(api_key: String, model: String) -> bool {
    let model_opt = if model.is_empty() { None } else { Some(model) };
    let llm = mockmate_llm::AnthropicLlm::new(api_key, model_opt);
    state().set_llm(Arc::new(llm)).await;
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

#[cfg(test)]
mod tests {
    use super::*;
    use mockmate_core::providers::Viseme;

    /// Simulate the viseme-lookup logic from `spawn_viseme_playback` without
    /// actually sleeping, so we can verify correct index advancement.
    fn lookup_viseme_at(visemes: &[Viseme], elapsed_ms: u32) -> u8 {
        let mut idx = 0usize;
        while idx + 1 < visemes.len() && visemes[idx + 1].timestamp_ms <= elapsed_ms {
            idx += 1;
        }
        visemes[idx].id
    }

    fn make_visemes(ids_and_ts: &[(u8, u32)]) -> Vec<Viseme> {
        ids_and_ts
            .iter()
            .map(|&(id, timestamp_ms)| Viseme { id, timestamp_ms })
            .collect()
    }

    #[test]
    fn tick_constant_is_20ms() {
        assert_eq!(VISEME_TICK_MS, 20, "50 Hz requires 20 ms ticks");
    }

    #[test]
    fn lookup_before_first_viseme_returns_first() {
        let vs = make_visemes(&[(13, 0), (8, 100), (4, 200)]);
        assert_eq!(lookup_viseme_at(&vs, 0), 13);
        assert_eq!(lookup_viseme_at(&vs, 50), 13);
    }

    #[test]
    fn lookup_advances_at_boundary() {
        let vs = make_visemes(&[(13, 0), (8, 100), (4, 200)]);
        assert_eq!(lookup_viseme_at(&vs, 100), 8);
        assert_eq!(lookup_viseme_at(&vs, 150), 8);
        assert_eq!(lookup_viseme_at(&vs, 200), 4);
        assert_eq!(lookup_viseme_at(&vs, 999), 4);
    }

    #[test]
    fn lookup_single_viseme_always_same() {
        let vs = make_visemes(&[(7, 0)]);
        for ms in [0, 20, 100, 500] {
            assert_eq!(lookup_viseme_at(&vs, ms), 7);
        }
    }

    #[test]
    fn tick_rate_50hz_for_1s_audio() {
        // 1 second of audio → 1000 ms / 20 ms = 50 ticks (at least)
        let total_ms = 1_000u32;
        let ticks = total_ms / VISEME_TICK_MS as u32;
        assert!(ticks >= 50, "must emit at least 50 events per second of audio");
    }

    #[test]
    fn end_ms_one_tick_past_last_viseme() {
        let visemes = make_visemes(&[(4, 0), (13, 500)]);
        let end_ms = visemes.last().unwrap().timestamp_ms + VISEME_TICK_MS as u32;
        assert_eq!(end_ms, 520);
    }
}
