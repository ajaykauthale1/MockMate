use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

/// Persistent cpal output stream that drains from a shared sample queue.
///
/// Samples are always stored as **mono f32 at the output device's native rate**.
/// The caller supplies mono f32 LE PCM at the TTS input rate; `enqueue_f32_pcm`
/// resamples to the device rate before pushing.
///
/// The callback interleaves the mono queue into however many output channels the
/// device requires (typically 2 for stereo — copies the same sample to every
/// channel).  Underrun (empty queue) is filled with silence (0.0).
pub struct AudioPlayer {
    /// Mono f32 samples at `output_rate`, ready for playback.
    queue: Arc<Mutex<VecDeque<f32>>>,
    /// Kept alive to keep the cpal stream running.
    _stream: cpal::Stream,
    /// Native rate of the output device (samples/sec).
    output_rate: u32,
    // output_channels stored in the closure; field kept for introspection / debug.
    #[allow(dead_code)]
    output_channels: usize,
    /// Rate of the PCM fed in by the caller (e.g. 24_000 for Kokoro).
    input_rate: u32,
}

// cpal::Stream is not Send by default on some platforms, but we only ever
// keep it alive (never send it across threads after construction).
unsafe impl Send for AudioPlayer {}
unsafe impl Sync for AudioPlayer {}

impl AudioPlayer {
    /// Open the default output device and start the playback stream.
    ///
    /// `input_sample_rate` is the rate at which callers will feed samples
    /// (e.g. 24 000 for Kokoro).  The stream uses the device's preferred
    /// format; resampling happens in the enqueue path.
    pub fn new(input_sample_rate: u32) -> Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| anyhow!("no default output device"))?;

        let default_config = device.default_output_config()?;
        let output_rate = default_config.sample_rate().0;
        let output_channels = default_config.channels() as usize;

        let config = cpal::StreamConfig {
            channels: output_channels as u16,
            sample_rate: cpal::SampleRate(output_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let queue: Arc<Mutex<VecDeque<f32>>> = Arc::new(Mutex::new(VecDeque::new()));
        let queue_cb = Arc::clone(&queue);
        let channels = output_channels;

        let stream = device.build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut q = queue_cb.lock().unwrap();
                // `data` is interleaved: frame 0 ch0, frame 0 ch1, frame 1 ch0 …
                let mut i = 0;
                while i < data.len() {
                    let sample = q.pop_front().unwrap_or(0.0);
                    for c in 0..channels {
                        data[i + c] = sample;
                    }
                    i += channels;
                }
            },
            |err| tracing::error!("audio playback error: {err}"),
            None,
        )?;

        stream.play()?;

        tracing::debug!(
            "AudioPlayer ready: device rate {}Hz, {} ch, input rate {}Hz",
            output_rate,
            output_channels,
            input_sample_rate
        );

        Ok(Self {
            queue,
            _stream: stream,
            output_rate,
            output_channels,
            input_rate: input_sample_rate,
        })
    }

    /// Parse f32 LE PCM bytes, resample if needed, and push into the play queue.
    pub fn enqueue_f32_pcm(&self, bytes: &[u8]) {
        let samples: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        self.enqueue_f32_samples(&samples);
    }

    /// Resample `samples` if needed and push into the play queue.
    pub fn enqueue_f32_samples(&self, samples: &[f32]) {
        let resampled = if self.input_rate == self.output_rate {
            // avoid clone: just extend directly
            let mut q = self.queue.lock().unwrap();
            q.extend(samples.iter().copied());
            return;
        } else {
            Self::resample_linear(samples, self.input_rate, self.output_rate)
        };
        let mut q = self.queue.lock().unwrap();
        q.extend(resampled.into_iter());
    }

    /// Drop all queued (not yet played) samples — use to interrupt mid-speech.
    pub fn clear(&self) {
        self.queue.lock().unwrap().clear();
    }

    /// `true` while there are samples waiting to be played.
    pub fn is_playing(&self) -> bool {
        !self.queue.lock().unwrap().is_empty()
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Windowed-sinc resample (Hann window, ±16 tap radius).
    ///
    /// Much higher quality than linear interpolation: avoids the aliasing on
    /// fricatives / sibilants that linear causes when going 24 kHz → 48 kHz.
    /// No quality loss at matching rates (guarded by the caller).
    fn resample_linear(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
        if samples.is_empty() {
            return vec![];
        }
        const RADIUS: i64 = 16;
        let ratio = from_rate as f64 / to_rate as f64;
        let out_len = (samples.len() as f64 / ratio).ceil() as usize;
        let len = samples.len() as i64;
        use std::f64::consts::PI;
        (0..out_len)
            .map(|i| {
                let center = i as f64 * ratio;
                let center_i = center.floor() as i64;
                let mut sum = 0.0f64;
                for k in (center_i - RADIUS)..=(center_i + RADIUS) {
                    if k < 0 || k >= len {
                        continue;
                    }
                    let t = center - k as f64;
                    let sinc = if t.abs() < 1e-10 {
                        1.0
                    } else {
                        let pt = PI * t;
                        pt.sin() / pt
                    };
                    let norm = t / (RADIUS as f64 + 1.0);
                    let window = if norm.abs() <= 1.0 {
                        0.5 * (1.0 + (PI * norm).cos())
                    } else {
                        0.0
                    };
                    sum += samples[k as usize] as f64 * sinc * window;
                }
                sum.clamp(-1.0, 1.0) as f32
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resample_identity() {
        let s = vec![0.0f32, 0.5, 1.0, -0.5];
        let out = AudioPlayer::resample_linear(&s, 24_000, 24_000);
        // same rate → not called in prod but verify math
        assert_eq!(out.len(), s.len());
        for (a, b) in s.iter().zip(out.iter()) {
            assert!((a - b).abs() < 1e-6, "identity failed: {a} vs {b}");
        }
    }

    #[test]
    fn resample_upsample_doubles_length_approx() {
        let s: Vec<f32> = (0..100).map(|i| i as f32 / 100.0).collect();
        let out = AudioPlayer::resample_linear(&s, 24_000, 48_000);
        // 48kHz / 24kHz = 2× → should be ~200 samples
        assert!(
            (out.len() as i64 - 200).abs() <= 2,
            "expected ~200 samples, got {}",
            out.len()
        );
    }

    #[test]
    fn resample_downsample_halves_length_approx() {
        let s: Vec<f32> = (0..200).map(|i| i as f32 / 200.0).collect();
        let out = AudioPlayer::resample_linear(&s, 48_000, 24_000);
        assert!(
            (out.len() as i64 - 100).abs() <= 2,
            "expected ~100 samples, got {}",
            out.len()
        );
    }

    #[test]
    fn resample_empty() {
        assert!(AudioPlayer::resample_linear(&[], 24_000, 48_000).is_empty());
    }

    #[test]
    fn enqueue_f32_pcm_parse() {
        // If we can't open a real device in CI, just verify the f32 parsing.
        let samples = vec![0.0f32, 0.5, -0.5, 1.0];
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        // Re-parse manually (mimics enqueue_f32_pcm's first step)
        let parsed: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        assert_eq!(parsed, samples);
    }

    #[test]
    fn clear_empties_queue() {
        // Directly test queue logic without opening a device.
        let q = Arc::new(Mutex::new(VecDeque::<f32>::new()));
        q.lock().unwrap().extend([1.0f32, 2.0, 3.0]);
        assert!(!q.lock().unwrap().is_empty());
        q.lock().unwrap().clear();
        assert!(q.lock().unwrap().is_empty());
    }
}
