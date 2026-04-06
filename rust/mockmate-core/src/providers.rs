use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

/// A single viseme frame: mouth-shape id + timestamp in milliseconds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Viseme {
    pub id: u8,
    pub timestamp_ms: u32,
}

/// Interaction mode passed to the LLM for prompt switching.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InteractionMode {
    /// Answer factual questions from the knowledge base.
    Guide,
    /// Socratic tutor — withhold answers, give hints.
    Test,
}

// ---------------------------------------------------------------------------
// Traits
// ---------------------------------------------------------------------------

/// Bundles TTS audio with phoneme-derived viseme frames.
///
/// Providers that support phoneme extraction (e.g. `KokoroTts`) populate
/// `visemes` directly from the IPA sequence.  Others return an empty `visemes`
/// vec; `SessionManager` then falls back to `FftVisemeExtractor`.
#[derive(Debug)]
pub struct TtsPlaybackEvent {
    /// Raw PCM audio (f32 LE, provider's native sample rate).
    pub audio: Vec<u8>,
    /// Phoneme-driven viseme frames.  Empty when the provider does not support
    /// inline phoneme extraction.
    pub visemes: Vec<Viseme>,
}

/// Provides text-to-speech synthesis.
/// Implementors: PiperTts, KokoroTts, ElevenLabsTts (BYOK).
#[async_trait]
pub trait TtsProvider: Send + Sync {
    /// Synthesise `text` and return raw PCM audio bytes (f32 LE, 24 kHz mono).
    async fn synthesise(&self, text: &str) -> Result<Vec<u8>>;

    /// Synthesise `text` and return audio **plus** phoneme-aligned visemes.
    ///
    /// The default implementation calls [`synthesise`] and returns an empty
    /// viseme list.  Providers with phoneme access (e.g. `KokoroTts`) should
    /// override this to populate `visemes` without a separate FFT pass.
    async fn synthesise_with_visemes(&self, text: &str) -> Result<TtsPlaybackEvent> {
        let audio = self.synthesise(text).await?;
        Ok(TtsPlaybackEvent { audio, visemes: vec![] })
    }
}

/// Provides large-language-model completions.
/// Implementors: OllamaLlm, OpenAiLlm (BYOK).
#[async_trait]
pub trait LlmProvider: Send + Sync {
    /// Stream a chat completion given a system prompt and user message.
    /// Each yielded `String` is a token chunk.
    async fn chat(
        &self,
        system: &str,
        user: &str,
    ) -> Result<tokio::sync::mpsc::Receiver<Result<String>>>;
}

/// Provides speech-to-text transcription.
/// Implementors: WhisperStt.
#[async_trait]
pub trait SttProvider: Send + Sync {
    /// Transcribe PCM audio bytes to text.
    async fn transcribe(&self, pcm: &[u8]) -> Result<String>;
}

/// Provides voice-activity detection.
/// Implementors: SileroVad.
#[async_trait]
pub trait VadProvider: Send + Sync {
    /// Returns `true` if speech is detected in the given PCM chunk.
    async fn is_speech(&self, pcm_chunk: &[f32]) -> Result<bool>;
}

/// Extracts viseme frames from TTS audio.
/// Implementors: FftVisemeExtractor (rustfft fallback), PiperPhonemeExtractor.
#[async_trait]
pub trait VisemeExtractor: Send + Sync {
    /// Extract viseme frames from raw PCM audio.
    async fn extract(&self, pcm: &[u8]) -> Result<Vec<Viseme>>;
}
