use std::sync::Arc;

use anyhow::Result;
use mockmate_core::{prompt::build_system_prompt, providers::Viseme, state::AppState};

/// Full result of one conversational turn.
#[derive(Debug)]
pub struct SessionResult {
    /// Transcript produced by the STT provider.
    pub transcript: String,
    /// Full LLM response text.
    pub response_text: String,
    /// TTS audio bytes (f32 LE PCM, provider's native sample rate).
    pub audio: Vec<u8>,
    /// Viseme frames extracted from the TTS audio.
    pub visemes: Vec<Viseme>,
}

/// Orchestrates the full audio→STT→LLM→TTS→Viseme pipeline.
pub struct SessionManager {
    state: Arc<AppState>,
}

impl SessionManager {
    pub fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }

    /// Convert f32 samples to f32 LE PCM bytes.
    fn f32_to_bytes(samples: &[f32]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    /// Run a complete turn:
    /// 1. VAD — bail early if no speech detected.
    /// 2. STT — transcribe the audio.
    /// 3. LLM — generate a response (current KB + mode).
    /// 4. TTS — synthesise the response.
    /// 5. Viseme — extract mouth-shape frames from the TTS audio.
    pub async fn process_audio(&self, pcm_f32: &[f32]) -> Result<SessionResult> {
        // 1. VAD
        let speech = self.state.vad.read().await.is_speech(pcm_f32).await?;
        anyhow::ensure!(speech, "no speech detected");

        // 2. STT
        let pcm_bytes = Self::f32_to_bytes(pcm_f32);
        let transcript = self.state.stt.read().await.transcribe(&pcm_bytes).await?;
        anyhow::ensure!(!transcript.trim().is_empty(), "empty transcript");

        // 3. LLM
        let kb = self.state.knowledge_base.lock().await.clone();
        let mode = *self.state.mode.lock().await;
        let system = build_system_prompt(mode, &kb);

        let mut rx = self.state.llm.read().await.chat(&system, &transcript).await?;
        let mut response_text = String::new();
        while let Some(chunk) = rx.recv().await {
            response_text.push_str(&chunk?);
        }

        // 4. TTS
        let audio = self.state.tts.read().await.synthesise(&response_text).await?;

        // 5. Viseme
        let visemes = self.state.viseme.read().await.extract(&audio).await?;

        Ok(SessionResult {
            transcript,
            response_text,
            audio,
            visemes,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result as AResult;
    use async_trait::async_trait;
    use mockmate_core::providers::{
        LlmProvider, SttProvider, TtsProvider, VadProvider, VisemeExtractor,
    };
    use tokio::sync::mpsc;

    // ----- stub providers -----

    struct AlwaysSpeechVad;
    struct NoSpeechVad;
    struct EchoStt(String);
    struct SingleTokenLlm(String);
    struct SilentTts;
    struct NoViseme;
    struct ErrorStt;

    #[async_trait]
    impl VadProvider for AlwaysSpeechVad {
        async fn is_speech(&self, _: &[f32]) -> AResult<bool> { Ok(true) }
    }
    #[async_trait]
    impl VadProvider for NoSpeechVad {
        async fn is_speech(&self, _: &[f32]) -> AResult<bool> { Ok(false) }
    }
    #[async_trait]
    impl SttProvider for EchoStt {
        async fn transcribe(&self, _: &[u8]) -> AResult<String> { Ok(self.0.clone()) }
    }
    #[async_trait]
    impl SttProvider for ErrorStt {
        async fn transcribe(&self, _: &[u8]) -> AResult<String> {
            Err(anyhow::anyhow!("stt error"))
        }
    }
    #[async_trait]
    impl LlmProvider for SingleTokenLlm {
        async fn chat(&self, _: &str, _: &str) -> AResult<mpsc::Receiver<AResult<String>>> {
            let (tx, rx) = mpsc::channel(1);
            let token = self.0.clone();
            tokio::spawn(async move {
                let _ = tx.send(Ok(token)).await;
            });
            Ok(rx)
        }
    }
    #[async_trait]
    impl TtsProvider for SilentTts {
        async fn synthesise(&self, _: &str) -> AResult<Vec<u8>> { Ok(vec![]) }
    }
    #[async_trait]
    impl VisemeExtractor for NoViseme {
        async fn extract(&self, _: &[u8]) -> AResult<Vec<Viseme>> { Ok(vec![]) }
    }

    fn make_state(
        vad: Arc<dyn VadProvider>,
        stt: Arc<dyn SttProvider>,
        llm: Arc<dyn LlmProvider>,
        tts: Arc<dyn TtsProvider>,
        viseme: Arc<dyn VisemeExtractor>,
    ) -> Arc<AppState> {
        Arc::new(AppState::new(llm, stt, tts, vad, viseme))
    }

    fn default_state() -> Arc<AppState> {
        make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("hello".to_string())),
            Arc::new(SingleTokenLlm("response".to_string())),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        )
    }

    #[tokio::test]
    async fn happy_path_returns_result() {
        let mgr = SessionManager::new(default_state());
        let result = mgr.process_audio(&[0.5f32; 512]).await.unwrap();
        assert_eq!(result.transcript, "hello");
        assert_eq!(result.response_text, "response");
        assert!(result.audio.is_empty()); // SilentTts returns []
        assert!(result.visemes.is_empty());
    }

    #[tokio::test]
    async fn no_speech_returns_err() {
        let state = make_state(
            Arc::new(NoSpeechVad),
            Arc::new(EchoStt("x".into())),
            Arc::new(SingleTokenLlm("y".into())),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        let mgr = SessionManager::new(state);
        let err = mgr.process_audio(&[0.0f32; 512]).await.unwrap_err();
        assert!(err.to_string().contains("no speech detected"));
    }

    #[tokio::test]
    async fn empty_transcript_returns_err() {
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt(String::new())), // empty transcript
            Arc::new(SingleTokenLlm("y".into())),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        let mgr = SessionManager::new(state);
        let err = mgr.process_audio(&[0.5f32; 512]).await.unwrap_err();
        assert!(err.to_string().contains("empty transcript"));
    }

    #[tokio::test]
    async fn stt_error_propagates() {
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(ErrorStt),
            Arc::new(SingleTokenLlm("y".into())),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        let mgr = SessionManager::new(state);
        let err = mgr.process_audio(&[0.5f32; 512]).await.unwrap_err();
        assert!(err.to_string().contains("stt error"));
    }

    #[tokio::test]
    async fn f32_to_bytes_round_trip() {
        let samples = vec![0.0f32, 0.5, -0.5, 1.0];
        let bytes = SessionManager::f32_to_bytes(&samples);
        let recovered: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        assert_eq!(samples, recovered);
    }

    #[tokio::test]
    async fn set_provider_hot_swap() {
        // Verify AppState::set_stt swaps in a new provider mid-session.
        let state = default_state();
        state.set_stt(Arc::new(EchoStt("swapped".to_string()))).await;
        let mgr = SessionManager::new(Arc::clone(&state));
        let result = mgr.process_audio(&[0.5f32; 512]).await.unwrap();
        assert_eq!(result.transcript, "swapped");
    }
}
