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

        // 4. TTS — use synthesise_with_visemes; Kokoro returns phoneme-driven
        //    visemes inline; other providers return an empty vec.
        let tts_event = self.state.tts.read().await
            .synthesise_with_visemes(&response_text).await?;
        let audio = tts_event.audio;

        // 5. Viseme — use phoneme-driven visemes when available, else FFT.
        let visemes = if tts_event.visemes.is_empty() {
            self.state.viseme.read().await.extract(&audio).await?
        } else {
            tts_event.visemes
        };

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

    // -----------------------------------------------------------------------
    // Integration: KB content + mode routing into LLM system prompt
    // -----------------------------------------------------------------------

    use mockmate_core::providers::InteractionMode;
    use std::sync::atomic::{AtomicU32, Ordering};
    use tokio::sync::Mutex as TokioMutex;

    /// LLM stub that records the system prompt it receives.
    struct CaptureLlm {
        captured_system: Arc<TokioMutex<String>>,
        reply: String,
    }

    #[async_trait]
    impl LlmProvider for CaptureLlm {
        async fn chat(&self, system: &str, _user: &str) -> AResult<mpsc::Receiver<AResult<String>>> {
            *self.captured_system.lock().await = system.to_string();
            let (tx, rx) = mpsc::channel(1);
            let reply = self.reply.clone();
            tokio::spawn(async move { let _ = tx.send(Ok(reply)).await; });
            Ok(rx)
        }
    }

    /// TTS stub that returns phoneme-driven visemes inline.
    struct PhonemeTts;

    #[async_trait]
    impl TtsProvider for PhonemeTts {
        async fn synthesise(&self, _: &str) -> AResult<Vec<u8>> { Ok(vec![]) }

        async fn synthesise_with_visemes(&self, _: &str) -> AResult<mockmate_core::providers::TtsPlaybackEvent> {
            Ok(mockmate_core::providers::TtsPlaybackEvent {
                audio: vec![],
                visemes: vec![
                    mockmate_core::providers::Viseme { id: 5, timestamp_ms: 0 },
                    mockmate_core::providers::Viseme { id: 7, timestamp_ms: 80 },
                ],
            })
        }
    }

    /// VisemeExtractor stub that counts how many times it was called.
    struct CountingViseme(Arc<AtomicU32>);

    #[async_trait]
    impl VisemeExtractor for CountingViseme {
        async fn extract(&self, _: &[u8]) -> AResult<Vec<Viseme>> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(vec![])
        }
    }

    #[tokio::test]
    async fn guide_mode_prompt_contains_kb_content() {
        let captured = Arc::new(TokioMutex::new(String::new()));
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("q".into())),
            Arc::new(CaptureLlm { captured_system: Arc::clone(&captured), reply: "a".into() }),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        state.set_knowledge_base("Rust ownership rules".into()).await;
        // Guide is the default mode — no need to set it.

        SessionManager::new(Arc::clone(&state))
            .process_audio(&[0.5f32; 512])
            .await
            .unwrap();

        let system = captured.lock().await.clone();
        assert!(system.contains("Guide mode"), "expected Guide mode in prompt");
        assert!(system.contains("Rust ownership rules"), "expected KB in prompt");
    }

    #[tokio::test]
    async fn test_mode_prompt_is_socratic() {
        let captured = Arc::new(TokioMutex::new(String::new()));
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("q".into())),
            Arc::new(CaptureLlm { captured_system: Arc::clone(&captured), reply: "hint".into() }),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        state.set_mode(InteractionMode::Test).await;

        SessionManager::new(Arc::clone(&state))
            .process_audio(&[0.5f32; 512])
            .await
            .unwrap();

        let system = captured.lock().await.clone();
        assert!(system.contains("Test mode"), "expected Test mode in prompt");
        assert!(
            system.contains("NEVER give the answer directly"),
            "expected Socratic instruction in prompt"
        );
    }

    #[tokio::test]
    async fn tts_phoneme_visemes_used_when_available() {
        let fft_calls = Arc::new(AtomicU32::new(0));
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("hi".into())),
            Arc::new(SingleTokenLlm("response".into())),
            Arc::new(PhonemeTts),
            Arc::new(CountingViseme(Arc::clone(&fft_calls))),
        );

        let result = SessionManager::new(state)
            .process_audio(&[0.5f32; 512])
            .await
            .unwrap();

        // Phoneme path: 2 visemes from PhonemeTts, FFT never called
        assert_eq!(result.visemes.len(), 2);
        assert_eq!(result.visemes[0].id, 5);
        assert_eq!(result.visemes[1].id, 7);
        assert_eq!(fft_calls.load(Ordering::SeqCst), 0, "FFT should not be called when TTS provides visemes");
    }

    #[tokio::test]
    async fn fft_fallback_called_when_tts_has_no_visemes() {
        let fft_calls = Arc::new(AtomicU32::new(0));
        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("hi".into())),
            Arc::new(SingleTokenLlm("response".into())),
            Arc::new(SilentTts), // default impl returns empty visemes
            Arc::new(CountingViseme(Arc::clone(&fft_calls))),
        );

        SessionManager::new(state)
            .process_audio(&[0.5f32; 512])
            .await
            .unwrap();

        assert_eq!(fft_calls.load(Ordering::SeqCst), 1, "FFT should be called exactly once as fallback");
    }

    #[tokio::test]
    async fn mode_switch_between_turns_uses_new_mode() {
        let captured = Arc::new(TokioMutex::new(Vec::<String>::new()));

        struct MultiCaptureLlm(Arc<TokioMutex<Vec<String>>>);
        #[async_trait]
        impl LlmProvider for MultiCaptureLlm {
            async fn chat(&self, system: &str, _: &str) -> AResult<mpsc::Receiver<AResult<String>>> {
                self.0.lock().await.push(system.to_string());
                let (tx, rx) = mpsc::channel(1);
                tokio::spawn(async move { let _ = tx.send(Ok("ok".to_string())).await; });
                Ok(rx)
            }
        }

        let state = make_state(
            Arc::new(AlwaysSpeechVad),
            Arc::new(EchoStt("q".into())),
            Arc::new(MultiCaptureLlm(Arc::clone(&captured))),
            Arc::new(SilentTts),
            Arc::new(NoViseme),
        );
        let mgr = SessionManager::new(Arc::clone(&state));

        // Turn 1: Guide
        mgr.process_audio(&[0.5f32; 512]).await.unwrap();

        // Switch to Test
        state.set_mode(InteractionMode::Test).await;

        // Turn 2: Test
        mgr.process_audio(&[0.5f32; 512]).await.unwrap();

        let prompts = captured.lock().await.clone();
        assert_eq!(prompts.len(), 2);
        assert!(prompts[0].contains("Guide mode"));
        assert!(prompts[1].contains("Test mode"));
    }
}
