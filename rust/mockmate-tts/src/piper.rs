use anyhow::Result;
use async_trait::async_trait;
use std::io::Write as _;
use std::process::{Command, Stdio};

use mockmate_core::providers::TtsProvider;

/// Piper TTS via subprocess.
///
/// Spawns the piper binary with `--output-raw`, writes text to stdin, and
/// reads raw i16 LE PCM from stdout.  The samples are converted to f32 LE
/// before returning (TtsProvider contract).  Sample rate is model-dependent
/// (typically 22 050 Hz for Piper v1 models).
pub struct PiperTts {
    piper_bin: String,
    model_path: String,
}

impl PiperTts {
    pub fn new(piper_bin: impl Into<String>, model_path: impl Into<String>) -> Self {
        Self {
            piper_bin: piper_bin.into(),
            model_path: model_path.into(),
        }
    }

    fn i16_le_bytes_to_f32_le_bytes(raw: &[u8]) -> Vec<u8> {
        raw.chunks_exact(2)
            .flat_map(|b| {
                let sample = i16::from_le_bytes([b[0], b[1]]) as f32 / 32_768.0;
                sample.to_le_bytes()
            })
            .collect()
    }
}

#[async_trait]
impl TtsProvider for PiperTts {
    async fn synthesise(&self, text: &str) -> Result<Vec<u8>> {
        let text = text.to_string();
        let piper_bin = self.piper_bin.clone();
        let model_path = self.model_path.clone();

        tokio::task::spawn_blocking(move || {
            let mut child = Command::new(&piper_bin)
                .args(["--model", &model_path, "--output-raw"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| anyhow::anyhow!("failed to spawn piper ({piper_bin}): {e}"))?;

            child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("piper stdin not available"))?
                .write_all(text.as_bytes())?;

            let output = child.wait_with_output()?;
            anyhow::ensure!(
                output.status.success(),
                "piper exited with status {}",
                output.status
            );

            Ok(Self::i16_le_bytes_to_f32_le_bytes(&output.stdout))
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_binary_returns_err() {
        let tts = PiperTts::new("/nonexistent/piper", "model.onnx");
        let result = tts.synthesise("hello").await;
        assert!(result.is_err());
    }

    #[test]
    fn i16_to_f32_zero() {
        let raw = 0i16.to_le_bytes().to_vec();
        let out = PiperTts::i16_le_bytes_to_f32_le_bytes(&raw);
        let f = f32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        assert!((f - 0.0).abs() < f32::EPSILON);
    }

    #[test]
    fn i16_to_f32_max() {
        let raw = i16::MAX.to_le_bytes().to_vec();
        let out = PiperTts::i16_le_bytes_to_f32_le_bytes(&raw);
        let f = f32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        // i16::MAX / 32768.0 ≈ 0.9999694
        assert!((f - (i16::MAX as f32 / 32_768.0)).abs() < 1e-6);
    }

    #[test]
    fn i16_to_f32_min() {
        let raw = i16::MIN.to_le_bytes().to_vec();
        let out = PiperTts::i16_le_bytes_to_f32_le_bytes(&raw);
        let f = f32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        assert!((f - (i16::MIN as f32 / 32_768.0)).abs() < 1e-6);
    }

    #[test]
    fn i16_to_f32_ignores_trailing_byte() {
        let raw = vec![0u8; 5]; // 2 complete i16s + 1 leftover byte
        let out = PiperTts::i16_le_bytes_to_f32_le_bytes(&raw);
        assert_eq!(out.len(), 2 * 4); // 2 f32s = 8 bytes
    }

    #[test]
    fn construction_stores_paths() {
        let tts = PiperTts::new("/usr/bin/piper", "/models/en_US-amy-low.onnx");
        assert_eq!(tts.piper_bin, "/usr/bin/piper");
        assert_eq!(tts.model_path, "/models/en_US-amy-low.onnx");
    }
}
