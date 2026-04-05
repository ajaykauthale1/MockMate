use anyhow::Result;
use async_trait::async_trait;
use ort::{session::Session, value::Tensor};
use tokio::sync::Mutex;

use mockmate_core::providers::VadProvider;

/// Number of samples per VAD chunk at 16 kHz (32 ms).
pub const VAD_CHUNK_SAMPLES: usize = 512;
/// Default speech probability threshold.
pub const DEFAULT_THRESHOLD: f32 = 0.5;
/// Silero VAD v4 LSTM hidden-state size.
const H_SIZE: usize = 2 * 1 * 64; // [2, batch=1, 64] flattened

struct SileroInner {
    session: Session,
    /// LSTM hidden state h, shape [2, 1, 64], stored flat.
    h: Vec<f32>,
    /// LSTM cell state c, shape [2, 1, 64], stored flat.
    c: Vec<f32>,
}

impl SileroInner {
    fn new(session: Session) -> Self {
        Self {
            session,
            h: vec![0.0f32; H_SIZE],
            c: vec![0.0f32; H_SIZE],
        }
    }

    fn reset(&mut self) {
        self.h.fill(0.0);
        self.c.fill(0.0);
    }
}

/// Silero VAD v4 running via ONNX Runtime.
///
/// Stateful: LSTM hidden state is preserved across successive `is_speech` calls
/// so consecutive 32-ms chunks form a coherent sequence.
pub struct SileroVad {
    inner: Mutex<SileroInner>,
    threshold: f32,
}

impl SileroVad {
    /// Load the Silero VAD v4 ONNX model from `model_path`.
    pub fn new(model_path: &str) -> Result<Self> {
        Self::new_with_threshold(model_path, DEFAULT_THRESHOLD)
    }

    pub fn new_with_threshold(model_path: &str, threshold: f32) -> Result<Self> {
        let session = Session::builder()?.commit_from_file(model_path)?;
        Ok(Self {
            inner: Mutex::new(SileroInner::new(session)),
            threshold,
        })
    }

    /// Reset LSTM state (call between utterances).
    pub async fn reset(&self) {
        self.inner.lock().await.reset();
    }
}

#[async_trait]
impl VadProvider for SileroVad {
    /// Run VAD on exactly [`VAD_CHUNK_SAMPLES`] f32 samples at 16 kHz.
    async fn is_speech(&self, pcm_chunk: &[f32]) -> Result<bool> {
        anyhow::ensure!(
            pcm_chunk.len() == VAD_CHUNK_SAMPLES,
            "VAD expects exactly {VAD_CHUNK_SAMPLES} samples, got {}",
            pcm_chunk.len()
        );

        let mut guard = self.inner.lock().await;

        let input_t = Tensor::<f32>::from_array((
            vec![1i64, VAD_CHUNK_SAMPLES as i64],
            pcm_chunk.to_vec(),
        ))?;
        let sr_t = Tensor::<i64>::from_array((vec![1i64], vec![16_000i64]))?;
        let h_t =
            Tensor::<f32>::from_array((vec![2i64, 1, 64], guard.h.clone()))?;
        let c_t =
            Tensor::<f32>::from_array((vec![2i64, 1, 64], guard.c.clone()))?;

        let outputs = guard.session.run(ort::inputs![
            "input" => input_t,
            "sr"    => sr_t,
            "h"     => h_t,
            "c"     => c_t,
        ])?;

        let (_, prob_data) = outputs["output"].try_extract_tensor::<f32>()?;
        let prob = prob_data[0];

        let (_, hn_data) = outputs["hn"].try_extract_tensor::<f32>()?;
        let (_, cn_data) = outputs["cn"].try_extract_tensor::<f32>()?;
        // Clone before dropping outputs — outputs borrows from guard.session.
        let hn_vec = hn_data.to_vec();
        let cn_vec = cn_data.to_vec();
        drop(outputs);

        guard.h = hn_vec;
        guard.c = cn_vec;

        Ok(prob >= self.threshold)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_model_returns_err() {
        let result = SileroVad::new("/nonexistent/silero_vad.onnx");
        assert!(result.is_err());
    }

    #[test]
    fn custom_threshold_nonexistent_still_errors() {
        let result = SileroVad::new_with_threshold("/nonexistent/model.onnx", 0.7);
        assert!(result.is_err());
    }

    #[test]
    fn vad_chunk_samples_constant() {
        assert_eq!(VAD_CHUNK_SAMPLES, 512);
    }

    #[test]
    fn default_threshold_is_half() {
        assert!((DEFAULT_THRESHOLD - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn h_size_matches_silero_dims() {
        // [2, 1, 64] → 128 elements
        assert_eq!(H_SIZE, 128);
    }

    #[tokio::test]
    async fn wrong_chunk_size_check() {
        // Without a real model we can't instantiate, but we can verify
        // the size constant mismatch that would trigger the ensure!.
        assert_ne!(256, VAD_CHUNK_SAMPLES);
        assert_ne!(1024, VAD_CHUNK_SAMPLES);
    }
}
