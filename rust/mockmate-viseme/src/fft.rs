use anyhow::Result;
use async_trait::async_trait;
use rustfft::{num_complex::Complex, FftPlanner};

use mockmate_core::providers::{Viseme, VisemeExtractor};

/// Analysis window size in samples (25 ms at 16 kHz).
const WINDOW_SIZE: usize = 400;
/// Hop between successive windows (10 ms at 16 kHz).
const HOP_SIZE: usize = 160;
/// RMS below this level is treated as silence (viseme 0).
const SILENCE_RMS: f32 = 0.01;

/// FFT-based viseme extractor (no external model required).
///
/// Applies a short-time FFT with a Hann window, computes the spectral
/// centroid of each frame, and maps it to one of 8 viseme buckets based
/// on dominant frequency region.  Suitable as a real-time fallback when
/// phoneme-accurate data from Piper is unavailable.
///
/// Viseme IDs follow the Preston Blair / Sycamore Studios set:
/// 0 = silence, 4 = T/D/N, 6 = CH/SH, 7 = S/Z, 8 = R,
/// 11 = OW, 12 = AW, 13 = AH (open vowel).
pub struct FftVisemeExtractor {
    sample_rate: u32,
}

impl FftVisemeExtractor {
    pub fn new(sample_rate: u32) -> Self {
        Self { sample_rate }
    }

    /// Convert f32 LE bytes to f32 samples.
    fn bytes_to_f32(pcm: &[u8]) -> Vec<f32> {
        pcm.chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect()
    }

    /// Weighted mean frequency of the magnitude spectrum.
    fn spectral_centroid(magnitudes: &[f32], sample_rate: u32) -> f32 {
        let freq_res = sample_rate as f32 / (2 * magnitudes.len()) as f32;
        let weighted: f32 = magnitudes
            .iter()
            .enumerate()
            .map(|(i, &m)| i as f32 * freq_res * m)
            .sum();
        let total: f32 = magnitudes.iter().sum();
        if total < 1e-10 { 0.0 } else { weighted / total }
    }

    /// Map RMS + spectral centroid to a viseme ID.
    fn centroid_to_viseme(centroid_hz: f32, rms: f32) -> u8 {
        if rms < SILENCE_RMS {
            return 0; // silence
        }
        match centroid_hz as u32 {
            0..=300 => 13,       // AH  – open vowel, low centroid
            301..=600 => 12,     // AW
            601..=1000 => 11,    // OW
            1001..=1500 => 8,    // R
            1501..=2000 => 4,    // T/D/N
            2001..=3000 => 9,    // L
            3001..=4000 => 7,    // S/Z sibilant
            _ => 6,              // CH/SH – very high frequency
        }
    }
}

#[async_trait]
impl VisemeExtractor for FftVisemeExtractor {
    async fn extract(&self, pcm: &[u8]) -> Result<Vec<Viseme>> {
        if pcm.is_empty() {
            return Ok(vec![]);
        }

        let samples = Self::bytes_to_f32(pcm);
        if samples.len() < WINDOW_SIZE {
            return Ok(vec![]);
        }

        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(WINDOW_SIZE);
        let ms_per_hop =
            (HOP_SIZE as f32 / self.sample_rate as f32 * 1000.0).round() as u32;

        let mut visemes = Vec::new();
        let mut pos = 0usize;
        let mut frame = 0u32;

        while pos + WINDOW_SIZE <= samples.len() {
            let window = &samples[pos..pos + WINDOW_SIZE];

            // Hann window + collect into complex buffer
            let mut buf: Vec<Complex<f32>> = window
                .iter()
                .enumerate()
                .map(|(i, &s)| {
                    let hann = 0.5
                        * (1.0
                            - (2.0 * std::f32::consts::PI * i as f32
                                / (WINDOW_SIZE - 1) as f32)
                                .cos());
                    Complex::new(s * hann, 0.0)
                })
                .collect();

            let rms =
                (window.iter().map(|s| s * s).sum::<f32>() / WINDOW_SIZE as f32).sqrt();

            fft.process(&mut buf);

            let half = WINDOW_SIZE / 2;
            let magnitudes: Vec<f32> = buf[..half].iter().map(|c| c.norm()).collect();

            let centroid = Self::spectral_centroid(&magnitudes, self.sample_rate);
            let id = Self::centroid_to_viseme(centroid, rms);

            visemes.push(Viseme {
                id,
                timestamp_ms: frame * ms_per_hop,
            });

            pos += HOP_SIZE;
            frame += 1;
        }

        Ok(visemes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extractor() -> FftVisemeExtractor {
        FftVisemeExtractor::new(16_000)
    }

    fn f32_to_bytes(samples: &[f32]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[tokio::test]
    async fn empty_input_returns_empty() {
        let v = extractor().extract(&[]).await.unwrap();
        assert!(v.is_empty());
    }

    #[tokio::test]
    async fn too_short_returns_empty() {
        // Less than WINDOW_SIZE samples
        let pcm = f32_to_bytes(&vec![0.0f32; 100]);
        let v = extractor().extract(&pcm).await.unwrap();
        assert!(v.is_empty());
    }

    #[tokio::test]
    async fn silence_produces_viseme_zero() {
        // One full window of zeros
        let pcm = f32_to_bytes(&vec![0.0f32; WINDOW_SIZE]);
        let v = extractor().extract(&pcm).await.unwrap();
        assert!(!v.is_empty());
        assert_eq!(v[0].id, 0, "silence must map to viseme 0");
    }

    #[tokio::test]
    async fn timestamps_increase_monotonically() {
        // Two seconds of silence → many frames
        let pcm = f32_to_bytes(&vec![0.0f32; 16_000 * 2]);
        let v = extractor().extract(&pcm).await.unwrap();
        assert!(v.len() >= 2);
        for w in v.windows(2) {
            assert!(w[1].timestamp_ms > w[0].timestamp_ms);
        }
    }

    #[tokio::test]
    async fn sine_100hz_maps_to_open_vowel() {
        // 100 Hz sine → centroid ≤ 300 Hz → viseme 13 (AH)
        let sr = 16_000u32;
        let n = WINDOW_SIZE + HOP_SIZE; // enough for at least one frame
        let samples: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 100.0 * i as f32 / sr as f32).sin())
            .collect();
        let pcm = f32_to_bytes(&samples);
        let v = extractor().extract(&pcm).await.unwrap();
        assert!(!v.is_empty());
        assert_eq!(v[0].id, 13, "100 Hz sine should map to AH (id=13)");
    }

    #[tokio::test]
    async fn sine_3500hz_maps_to_sibilant() {
        // 3500 Hz sine → centroid in 3001-4000 Hz → viseme 7 (S/Z)
        let sr = 16_000u32;
        let n = WINDOW_SIZE + HOP_SIZE;
        let samples: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 3500.0 * i as f32 / sr as f32).sin())
            .collect();
        let pcm = f32_to_bytes(&samples);
        let v = extractor().extract(&pcm).await.unwrap();
        assert!(!v.is_empty());
        assert_eq!(v[0].id, 7, "3500 Hz sine should map to S/Z (id=7)");
    }

    #[test]
    fn spectral_centroid_of_flat_spectrum() {
        // All bins equal → centroid ≈ midpoint
        let mags = vec![1.0f32; 100];
        let c = FftVisemeExtractor::spectral_centroid(&mags, 16_000);
        // freq_res = 16000 / (2*100) = 80 Hz
        // weighted = Σ i*80 / 100 = 80*(0+1+..+99)/100 = 80*4950/100 = 3960
        // total = 100
        // centroid = 3960
        assert!((c - 3960.0).abs() < 1.0);
    }

    #[test]
    fn spectral_centroid_of_zeros_is_zero() {
        let mags = vec![0.0f32; 50];
        let c = FftVisemeExtractor::spectral_centroid(&mags, 16_000);
        assert_eq!(c, 0.0);
    }

    #[test]
    fn silence_viseme_below_rms_threshold() {
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(1000.0, 0.005), 0);
    }

    #[test]
    fn viseme_buckets() {
        let rms = 0.5;
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(200.0, rms), 13);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(500.0, rms), 12);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(800.0, rms), 11);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(1200.0, rms), 8);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(1800.0, rms), 4);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(2500.0, rms), 9);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(3500.0, rms), 7);
        assert_eq!(FftVisemeExtractor::centroid_to_viseme(5000.0, rms), 6);
    }
}
