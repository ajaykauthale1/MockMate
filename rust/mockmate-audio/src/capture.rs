use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::RingBuffer;

/// Target sample rate for all downstream audio processing (Whisper / Silero).
pub const CAPTURE_SAMPLE_RATE: u32 = 16_000;

/// Keeps the cpal stream alive and exposes the shared ring buffer.
pub struct AudioCapture {
    /// Kept alive so the stream keeps running.
    _stream: cpal::Stream,
    /// Shared handle — callers drain this to get captured samples.
    pub ring: Arc<Mutex<RingBuffer>>,
}

impl AudioCapture {
    /// Start capturing from the default input device at 16 kHz mono f32.
    ///
    /// `capacity_secs` controls how many seconds of audio the ring buffer holds
    /// before oldest samples are evicted.
    pub fn start(capacity_secs: f32) -> anyhow::Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| anyhow::anyhow!("no default input device"))?;

        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(CAPTURE_SAMPLE_RATE),
            buffer_size: cpal::BufferSize::Default,
        };

        let capacity = (CAPTURE_SAMPLE_RATE as f32 * capacity_secs) as usize;
        let ring = Arc::new(Mutex::new(RingBuffer::new(capacity)));
        let ring_cb = Arc::clone(&ring);

        let stream = device.build_input_stream(
            &config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if let Ok(mut rb) = ring_cb.lock() {
                    rb.push_slice(data);
                }
            },
            |err| tracing::error!("audio capture error: {err}"),
            None,
        )?;

        stream.play()?;

        Ok(Self { _stream: stream, ring })
    }
}
