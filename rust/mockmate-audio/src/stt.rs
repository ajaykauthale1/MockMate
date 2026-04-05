use anyhow::Result;
use async_trait::async_trait;
use std::io::Write as _;
use std::process::{Command, Stdio};

use mockmate_core::providers::SttProvider;

#[derive(Debug)]
/// whisper.cpp CLI-backed speech-to-text provider.
///
/// Writes PCM audio to a temporary WAV file, spawns `whisper-cli` (or `main`
/// from the whisper.cpp build), parses the plain-text output, and cleans up.
///
/// This approach requires no libclang / native bindings — only the whisper.cpp
/// binary and a GGML model file.
pub struct WhisperStt {
    whisper_bin: String,
    model_path: String,
}

impl WhisperStt {
    /// Create a new provider.  Returns `Err` if either path does not exist.
    pub fn new(whisper_bin: &str, model_path: &str) -> Result<Self> {
        anyhow::ensure!(
            std::path::Path::new(whisper_bin).exists(),
            "whisper binary not found: {whisper_bin}"
        );
        anyhow::ensure!(
            std::path::Path::new(model_path).exists(),
            "whisper model not found: {model_path}"
        );
        Ok(Self {
            whisper_bin: whisper_bin.to_string(),
            model_path: model_path.to_string(),
        })
    }

    /// Convert f32 LE PCM bytes to f32 samples.
    pub(crate) fn bytes_to_f32(pcm: &[u8]) -> Vec<f32> {
        pcm.chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect()
    }

    /// Write f32 samples (16 kHz mono) to a minimal WAV file in `buf`.
    fn write_wav(samples: &[f32], buf: &mut Vec<u8>) {
        let num_samples = samples.len() as u32;
        let sample_rate: u32 = 16_000;
        let num_channels: u16 = 1;
        let bits_per_sample: u16 = 16;
        let byte_rate = sample_rate * num_channels as u32 * (bits_per_sample / 8) as u32;
        let block_align = num_channels * (bits_per_sample / 8);
        let data_size = num_samples * 2; // 16-bit = 2 bytes per sample

        // RIFF header
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&(36 + data_size).to_le_bytes());
        buf.extend_from_slice(b"WAVE");
        // fmt chunk
        buf.extend_from_slice(b"fmt ");
        buf.extend_from_slice(&16u32.to_le_bytes()); // chunk size
        buf.extend_from_slice(&1u16.to_le_bytes());  // PCM format
        buf.extend_from_slice(&num_channels.to_le_bytes());
        buf.extend_from_slice(&sample_rate.to_le_bytes());
        buf.extend_from_slice(&byte_rate.to_le_bytes());
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&bits_per_sample.to_le_bytes());
        // data chunk
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&data_size.to_le_bytes());
        for &s in samples {
            // Standard signed 16-bit PCM: 1.0 → 32767, -1.0 → -32768.
            let i = (s * 32_768.0_f32).clamp(-32_768.0, 32_767.0) as i16;
            buf.extend_from_slice(&i.to_le_bytes());
        }
    }
}

#[async_trait]
impl SttProvider for WhisperStt {
    /// Transcribe f32 LE PCM bytes (16 kHz mono) to text.
    async fn transcribe(&self, pcm: &[u8]) -> Result<String> {
        let samples = Self::bytes_to_f32(pcm);
        let whisper_bin = self.whisper_bin.clone();
        let model_path = self.model_path.clone();

        tokio::task::spawn_blocking(move || {
            // Write to a temp WAV file
            let mut tmp = tempfile::NamedTempFile::new()?;
            let mut wav_bytes = Vec::new();
            Self::write_wav(&samples, &mut wav_bytes);
            tmp.write_all(&wav_bytes)?;
            let wav_path = tmp.path().to_path_buf();

            // Spawn whisper-cli
            let output = Command::new(&whisper_bin)
                .args([
                    "--model", &model_path,
                    "--file", wav_path.to_str().unwrap_or(""),
                    "--output-txt",
                    "--no-timestamps",
                    "--language", "en",
                ])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .output()
                .map_err(|e| anyhow::anyhow!("failed to spawn whisper ({whisper_bin}): {e}"))?;

            anyhow::ensure!(
                output.status.success(),
                "whisper exited with status {}",
                output.status
            );

            let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Ok(text)
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_binary_returns_err() {
        let r = WhisperStt::new("/nonexistent/whisper-cli", "/nonexistent/ggml-base.en.bin");
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("whisper binary not found"));
    }

    #[test]
    fn bytes_to_f32_round_trip() {
        let original = vec![0.0f32, 0.5, -0.5, 1.0, -1.0];
        let bytes: Vec<u8> = original.iter().flat_map(|f| f.to_le_bytes()).collect();
        let recovered = WhisperStt::bytes_to_f32(&bytes);
        assert_eq!(recovered.len(), original.len());
        for (a, b) in original.iter().zip(recovered.iter()) {
            assert!((a - b).abs() < f32::EPSILON);
        }
    }

    #[test]
    fn bytes_to_f32_empty() {
        assert!(WhisperStt::bytes_to_f32(&[]).is_empty());
    }

    #[test]
    fn bytes_to_f32_ignores_trailing_partial() {
        let bytes = vec![0u8; 5];
        assert_eq!(WhisperStt::bytes_to_f32(&bytes).len(), 1);
    }

    #[test]
    fn write_wav_has_riff_header() {
        let samples = vec![0.0f32; 100];
        let mut buf = Vec::new();
        WhisperStt::write_wav(&samples, &mut buf);
        assert_eq!(&buf[0..4], b"RIFF");
        assert_eq!(&buf[8..12], b"WAVE");
        assert_eq!(&buf[12..16], b"fmt ");
        assert_eq!(&buf[36..40], b"data");
    }

    #[test]
    fn write_wav_data_size_matches_samples() {
        let n = 200usize;
        let samples = vec![0.0f32; n];
        let mut buf = Vec::new();
        WhisperStt::write_wav(&samples, &mut buf);
        // data chunk size is at offset 40, little-endian u32
        let data_size = u32::from_le_bytes([buf[40], buf[41], buf[42], buf[43]]);
        assert_eq!(data_size as usize, n * 2); // 16-bit = 2 bytes each
    }

    #[test]
    fn write_wav_clamps_and_converts() {
        // Values outside [-1, 1] should be clamped, not wrap
        let samples = vec![2.0f32, -2.0, 0.0];
        let mut buf = Vec::new();
        WhisperStt::write_wav(&samples, &mut buf);
        let i0 = i16::from_le_bytes([buf[44], buf[45]]);
        let i1 = i16::from_le_bytes([buf[46], buf[47]]);
        let i2 = i16::from_le_bytes([buf[48], buf[49]]);
        assert_eq!(i0, i16::MAX); // clamped to 1.0 → 32767
        assert_eq!(i1, -32768);   // clamped to -1.0 → -32768
        assert_eq!(i2, 0);
    }
}
