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
