use std::sync::Arc;
use tokio::sync::Mutex;

use crate::providers::{
    InteractionMode, LlmProvider, SttProvider, TtsProvider, VadProvider, VisemeExtractor,
};

/// Central application state shared across the Rust runtime.
/// All provider fields are `Arc<dyn Trait>` for trivial hot-swapping.
pub struct AppState {
    pub llm: Arc<dyn LlmProvider>,
    pub stt: Arc<dyn SttProvider>,
    pub tts: Arc<dyn TtsProvider>,
    pub vad: Arc<dyn VadProvider>,
    pub viseme: Arc<dyn VisemeExtractor>,

    /// Currently loaded knowledge base text.
    pub knowledge_base: Mutex<String>,

    /// Current interaction mode (Guide or Test).
    pub mode: Mutex<InteractionMode>,
}

impl AppState {
    pub fn new(
        llm: Arc<dyn LlmProvider>,
        stt: Arc<dyn SttProvider>,
        tts: Arc<dyn TtsProvider>,
        vad: Arc<dyn VadProvider>,
        viseme: Arc<dyn VisemeExtractor>,
    ) -> Self {
        Self {
            llm,
            stt,
            tts,
            vad,
            viseme,
            knowledge_base: Mutex::new(String::new()),
            mode: Mutex::new(InteractionMode::Guide),
        }
    }

    pub async fn set_knowledge_base(&self, kb: String) {
        *self.knowledge_base.lock().await = kb;
    }

    pub async fn set_mode(&self, mode: InteractionMode) {
        *self.mode.lock().await = mode;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use async_trait::async_trait;
    use crate::providers::{Viseme};

    struct StubTts;
    struct StubLlm;
    struct StubStt;
    struct StubVad;
    struct StubViseme;

    #[async_trait]
    impl TtsProvider for StubTts {
        async fn synthesise(&self, _text: &str) -> Result<Vec<u8>> {
            Ok(vec![])
        }
    }

    #[async_trait]
    impl LlmProvider for StubLlm {
        async fn chat(
            &self,
            _system: &str,
            _user: &str,
        ) -> Result<tokio::sync::mpsc::Receiver<Result<String>>> {
            let (tx, rx) = tokio::sync::mpsc::channel(1);
            drop(tx);
            Ok(rx)
        }
    }

    #[async_trait]
    impl SttProvider for StubStt {
        async fn transcribe(&self, _pcm: &[u8]) -> Result<String> {
            Ok(String::new())
        }
    }

    #[async_trait]
    impl VadProvider for StubVad {
        async fn is_speech(&self, _pcm_chunk: &[f32]) -> Result<bool> {
            Ok(false)
        }
    }

    #[async_trait]
    impl VisemeExtractor for StubViseme {
        async fn extract(&self, _pcm: &[u8]) -> Result<Vec<Viseme>> {
            Ok(vec![])
        }
    }

    fn make_state() -> AppState {
        AppState::new(
            Arc::new(StubLlm),
            Arc::new(StubStt),
            Arc::new(StubTts),
            Arc::new(StubVad),
            Arc::new(StubViseme),
        )
    }

    #[tokio::test]
    async fn default_mode_is_guide() {
        let state = make_state();
        assert_eq!(*state.mode.lock().await, InteractionMode::Guide);
    }

    #[tokio::test]
    async fn set_mode_switches_to_test() {
        let state = make_state();
        state.set_mode(InteractionMode::Test).await;
        assert_eq!(*state.mode.lock().await, InteractionMode::Test);
    }

    #[tokio::test]
    async fn set_mode_roundtrip() {
        let state = make_state();
        state.set_mode(InteractionMode::Test).await;
        state.set_mode(InteractionMode::Guide).await;
        assert_eq!(*state.mode.lock().await, InteractionMode::Guide);
    }

    #[tokio::test]
    async fn default_knowledge_base_is_empty() {
        let state = make_state();
        assert!(state.knowledge_base.lock().await.is_empty());
    }

    #[tokio::test]
    async fn set_knowledge_base_persists() {
        let state = make_state();
        state.set_knowledge_base("Rust ownership rules".to_string()).await;
        assert_eq!(*state.knowledge_base.lock().await, "Rust ownership rules");
    }

    #[tokio::test]
    async fn set_knowledge_base_overwrites() {
        let state = make_state();
        state.set_knowledge_base("first".to_string()).await;
        state.set_knowledge_base("second".to_string()).await;
        assert_eq!(*state.knowledge_base.lock().await, "second");
    }

    #[test]
    fn interaction_mode_eq_and_copy() {
        let a = InteractionMode::Guide;
        let b = a; // Copy
        assert_eq!(a, b);
        assert_ne!(InteractionMode::Guide, InteractionMode::Test);
    }
}
