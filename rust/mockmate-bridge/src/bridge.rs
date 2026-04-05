use std::sync::OnceLock;

use mockmate_core::{prompt::build_system_prompt, providers::InteractionMode, state::AppState};
use mockmate_llm::OllamaLlm;

// ---------------------------------------------------------------------------
// Global state — lazily initialised on first bridge call.
// Providers not yet implemented (audio/STT/TTS) use no-op stubs.
// ---------------------------------------------------------------------------

static APP_STATE: OnceLock<AppState> = OnceLock::new();

fn state() -> &'static AppState {
    APP_STATE.get_or_init(|| {
        use std::sync::Arc;
        use anyhow::Result;
        use async_trait::async_trait;
        use mockmate_core::providers::{TtsProvider, SttProvider, VadProvider, VisemeExtractor, Viseme};

        struct StubTts;
        struct StubStt;
        struct StubVad;
        struct StubViseme;

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
        #[async_trait]
        impl VisemeExtractor for StubViseme {
            async fn extract(&self, _: &[u8]) -> Result<Vec<Viseme>> { Ok(vec![]) }
        }

        AppState::new(
            Arc::new(OllamaLlm::new(None, None)),
            Arc::new(StubStt),
            Arc::new(StubTts),
            Arc::new(StubVad),
            Arc::new(StubViseme),
        )
    })
}

// ---------------------------------------------------------------------------
// FRB-exposed functions
// ---------------------------------------------------------------------------

/// Load (or replace) the knowledge base text in Rust AppState.
/// Flutter reads assets/kb/*.txt and passes the concatenated content here.
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
    let llm = OllamaLlm::new(None, None);
    llm.health_check().await.unwrap_or(false)
}

/// Send a user message and get the full LLM response using the current KB + mode.
/// Builds the system prompt from AppState (KB + InteractionMode) then calls Ollama.
/// Returns the concatenated response string, or an error message prefixed with "error:".
pub async fn chat(user_message: String) -> String {
    let s = state();
    let kb = s.knowledge_base.lock().await.clone();
    let mode = *s.mode.lock().await;
    let system = build_system_prompt(mode, &kb);

    match s.llm.chat(&system, &user_message).await {
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

/// Pull the default model from Ollama. Streams status strings back to Flutter.
/// Returns each status line; Flutter polls until "success" or an error.
/// For simplicity in Phase 1, this collects all status lines and returns them.
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
