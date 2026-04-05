use anyhow::Result;
use async_trait::async_trait;
use serde::Serialize;

use mockmate_core::providers::TtsProvider;

const DEFAULT_MODEL: &str = "eleven_turbo_v2_5";
/// ElevenLabs output format that returns raw i16 LE PCM at 24 kHz mono.
const OUTPUT_FORMAT: &str = "pcm_24000";

/// ElevenLabs BYOK TTS provider.
///
/// Calls the `/v1/text-to-speech/{voice_id}/stream` endpoint with
/// `output_format = "pcm_24000"`, converts the returned i16 LE bytes to
/// f32 LE, and returns them (TtsProvider contract, 24 kHz mono).
pub struct ElevenLabsTts {
    client: reqwest::Client,
    api_key: String,
    voice_id: String,
    model_id: String,
}

impl ElevenLabsTts {
    pub fn new(api_key: impl Into<String>, voice_id: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            api_key: api_key.into(),
            voice_id: voice_id.into(),
            model_id: DEFAULT_MODEL.to_string(),
        }
    }

    pub fn with_model(mut self, model_id: impl Into<String>) -> Self {
        self.model_id = model_id.into();
        self
    }

    fn i16_le_bytes_to_f32_le_bytes(raw: &[u8]) -> Vec<u8> {
        raw.chunks_exact(2)
            .flat_map(|b| {
                let s = i16::from_le_bytes([b[0], b[1]]) as f32 / 32_768.0;
                s.to_le_bytes()
            })
            .collect()
    }
}

#[async_trait]
impl TtsProvider for ElevenLabsTts {
    async fn synthesise(&self, text: &str) -> Result<Vec<u8>> {
        #[derive(Serialize)]
        struct Body<'a> {
            text: &'a str,
            model_id: &'a str,
            output_format: &'a str,
        }

        let url = format!(
            "https://api.elevenlabs.io/v1/text-to-speech/{}/stream",
            self.voice_id
        );

        let resp = self
            .client
            .post(&url)
            .header("xi-api-key", &self.api_key)
            .json(&Body {
                text,
                model_id: &self.model_id,
                output_format: OUTPUT_FORMAT,
            })
            .send()
            .await?;

        anyhow::ensure!(
            resp.status().is_success(),
            "ElevenLabs API error: {}",
            resp.status()
        );

        let raw = resp.bytes().await?;
        Ok(Self::i16_le_bytes_to_f32_le_bytes(&raw))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn construction_stores_fields() {
        let tts = ElevenLabsTts::new("key-abc", "voice-xyz");
        assert_eq!(tts.api_key, "key-abc");
        assert_eq!(tts.voice_id, "voice-xyz");
        assert_eq!(tts.model_id, DEFAULT_MODEL);
    }

    #[test]
    fn with_model_overrides() {
        let tts = ElevenLabsTts::new("k", "v").with_model("eleven_multilingual_v2");
        assert_eq!(tts.model_id, "eleven_multilingual_v2");
    }

    #[test]
    fn i16_to_f32_silence() {
        let raw = vec![0u8; 4]; // two i16 zeros
        let out = ElevenLabsTts::i16_le_bytes_to_f32_le_bytes(&raw);
        assert_eq!(out.len(), 8);
        let f0 = f32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        let f1 = f32::from_le_bytes([out[4], out[5], out[6], out[7]]);
        assert!((f0).abs() < f32::EPSILON);
        assert!((f1).abs() < f32::EPSILON);
    }

    #[test]
    fn i16_to_f32_positive_peak() {
        let raw = i16::MAX.to_le_bytes().to_vec();
        let out = ElevenLabsTts::i16_le_bytes_to_f32_le_bytes(&raw);
        let f = f32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        assert!((f - (i16::MAX as f32 / 32_768.0)).abs() < 1e-6);
    }

    #[tokio::test]
    async fn invalid_key_returns_err() {
        // Real network call with invalid key — ElevenLabs returns 401.
        // Only runs if network is available; skip gracefully otherwise.
        let tts = ElevenLabsTts::new("invalid-key", "21m00Tcm4TlvDq8ikWAM");
        let result = tts.synthesise("hello").await;
        // Either a network error or a non-2xx response → always Err.
        assert!(result.is_err());
    }
}
