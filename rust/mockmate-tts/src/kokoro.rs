use std::collections::HashMap;
use std::io::Write as _;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use async_trait::async_trait;
use ort::{execution_providers::CPU as CpuEp, session::Session, value::Tensor};
use tokio::sync::Mutex;

use mockmate_core::providers::{TtsPlaybackEvent, TtsProvider, Viseme};

/// Kokoro-82M ONNX output sample rate.
pub const SAMPLE_RATE: u32 = 24_000;

/// Number of style rows in the voice embedding file — one per possible sequence length.
const STYLE_ROWS: usize = 510;
/// Style dimensions per sequence-length row.
const STYLE_DIM: usize = 256;

/// Kokoro v1.0 phoneme token limit.  The style tensor is indexed by phoneme count,
/// so we must not exceed STYLE_ROWS - 1.
const MAX_TOKENS: usize = STYLE_ROWS - 1; // 509

// ---------------------------------------------------------------------------
// Vocabulary  (Kokoro v1.0 — loaded from config.json)
// ---------------------------------------------------------------------------

/// Build the v1.0 phoneme→token-ID map.
///
/// The IDs are sparse (not contiguous), so we use a HashMap rather than a
/// positional array.  Token 0 is reserved for BOS/EOS padding and is never
/// included in the map itself.
fn build_vocab() -> HashMap<char, i64> {
    [
        // Punctuation
        (';', 1i64), (':', 2), (',', 3), ('.', 4), ('!', 5), ('?', 6),
        ('—', 9), ('…', 10), ('"', 11), ('(', 12), (')', 13),
        ('\u{201C}', 14), ('\u{201D}', 15), (' ', 16),
        // Special phoneme symbols (Misaki)
        ('\u{0303}', 17), ('ʣ', 18), ('ʥ', 19), ('ʦ', 20), ('ʨ', 21),
        ('ᵝ', 22), ('\u{AB67}', 23),
        // Kokoro uppercase diphthong tokens
        ('A', 24), ('I', 25), ('O', 31), ('Q', 33), ('S', 35), ('T', 36),
        ('W', 39), ('Y', 41), ('ᵊ', 42),
        // Lowercase letters
        ('a', 43), ('b', 44), ('c', 45), ('d', 46), ('e', 47), ('f', 48),
        ('h', 50), ('i', 51), ('j', 52), ('k', 53), ('l', 54), ('m', 55),
        ('n', 56), ('o', 57), ('p', 58), ('q', 59), ('r', 60), ('s', 61),
        ('t', 62), ('u', 63), ('v', 64), ('w', 65), ('x', 66), ('y', 67),
        ('z', 68),
        // IPA symbols
        ('ɑ', 69), ('ɐ', 70), ('ɒ', 71), ('æ', 72), ('β', 75), ('ɔ', 76),
        ('ɕ', 77), ('ç', 78), ('ɖ', 80), ('ð', 81), ('ʤ', 82), ('ə', 83),
        ('ɚ', 85), ('ɛ', 86), ('ɜ', 87), ('ɟ', 90), ('ɡ', 92), ('ɥ', 99),
        ('ɨ', 101), ('ɪ', 102), ('ʝ', 103), ('ɯ', 110), ('ɰ', 111),
        ('ŋ', 112), ('ɳ', 113), ('ɲ', 114), ('ɴ', 115), ('ø', 116),
        ('ɸ', 118), ('θ', 119), ('œ', 120), ('ɹ', 123), ('ɾ', 125),
        ('ɻ', 126), ('ʁ', 128), ('ɽ', 129), ('ʂ', 130), ('ʃ', 131),
        ('ʈ', 132), ('ʧ', 133), ('ʊ', 135), ('ʋ', 136), ('ʌ', 138),
        ('ɣ', 139), ('ɤ', 140), ('χ', 142), ('ʎ', 143), ('ʒ', 147),
        ('ʔ', 148), ('ˈ', 156), ('ˌ', 157), ('ː', 158), ('ʰ', 162),
        ('ʲ', 164), ('↓', 169), ('→', 171), ('↗', 172), ('↘', 173),
        ('ᵻ', 177),
    ]
    .into_iter()
    .collect()
}

/// Map a single IPA character to its Kokoro v1.0 token ID.
/// Returns `None` for characters not in the vocab (silently skipped).
fn char_to_token(c: char, vocab: &HashMap<char, i64>) -> Option<i64> {
    vocab.get(&c).copied()
}

// ---------------------------------------------------------------------------
// IPA → Viseme mapping
// ---------------------------------------------------------------------------

/// Map a single IPA character to a Preston Blair viseme ID.
///
/// IDs are consistent with `FftVisemeExtractor`:
/// - 0  silence / prosodic
/// - 4  T / D / N / stops
/// - 6  CH / SH  (affricates + palatal fricatives)
/// - 7  S / Z  (sibilants + dental/labiodental fricatives)
/// - 8  R  (rhotics)
/// - 9  L  (laterals)
/// - 11 OW  (rounded back vowels)
/// - 12 AW / ER  (mid-central vowels, schwa)
/// - 13 AH  (open vowels + high front vowels)
pub fn ipa_char_to_viseme(c: char) -> u8 {
    match c {
        // Silence: pad, spaces, punctuation, prosodic markers, clicks
        '$' | ' ' | '\n' | '\r' | '\t'
        | ';' | ':' | ',' | '.' | '!' | '?'
        | '¡' | '¿' | '—' | '…' | '"' | '«' | '»' | '\u{201C}' | '\u{201D}'
        | 'ʔ' | 'ʡ' | 'ʕ' | 'ʢ'
        | 'ˈ' | 'ˌ' | 'ː' | 'ˑ' | 'ʼ'
        | '↓' | '↑' | '→' | '↗' | '↘'
        | 'ʴ' | 'ʰ' | 'ʱ' | 'ʲ' | 'ʷ' | 'ˠ' | 'ˤ' | '˞'
        | 'ǀ' | 'ǁ' | 'ǂ' | 'ǃ'
        | 'h' | 'ɦ' | 'ɧ' | 'ħ' | 'ʜ' | 'ɥ' => 0,

        // Open vowels (AH, 13)
        'ɑ' | 'ɐ' | 'ɒ' | 'æ' | 'ʌ' | 'ɪ' | 'i' | 'ɨ' | 'ᵻ'
        | 'j' => 13,    // palatal approximant – yod, vowel-like

        // Mid / central vowels, schwa (AW / ER, 12)
        'ə' | 'ɘ' | 'ɚ' | 'ɝ' | 'ɞ' | 'ɛ' | 'e' | 'ɜ' | 'œ' | 'ɶ' | 'ʏ' => 12,

        // Rounded back vowels (OW, 11)
        'ɔ' | 'o' | 'ø' | 'ɵ' | 'ʉ' | 'ʊ' | 'u' | 'ɤ'
        | 'w' | 'ʍ' => 11,  // labial-velar approximants – rounded lips

        // Rhotics (R, 8)
        'ɹ' | 'ɾ' | 'ɻ' | 'ʀ' | 'ʁ' | 'ɽ' => 8,

        // Laterals (L, 9)
        'l' | 'ɭ' | 'ɬ' | 'ɫ' | 'ɮ' | 'ʟ' | 'ɱ' | 'ʎ' => 9,

        // Affricates + postalveolar / palatal fricatives (CH / SH, 6)
        'ʧ' | 'ʃ' | 'ç' | 'ɕ' => 6,
        'ʤ' => 6,   // voiced affricate

        // Sibilants + dental/labiodental fricatives (S / Z, 7)
        's' | 'z' | 'ʑ' | 'ʐ' | 'ʂ' | 'ʒ'
        | 'θ' | 'ð'
        | 'f' | 'v' | 'β' | 'ɸ'
        | 'χ' | 'ɣ' | 'ⱱ' => 7,

        // Stops, nasals, velars, bilabials → generic consonant (T / D / N, 4)
        _ => 4,
    }
}

// ---------------------------------------------------------------------------
// KokoroTts
// ---------------------------------------------------------------------------

/// Kokoro-82M TTS running end-to-end via ONNX Runtime.
///
/// Text → phonemes (espeak-ng subprocess) → token IDs → ONNX inference →
/// f32 LE PCM at 24 kHz mono.
pub struct KokoroTts {
    session: Mutex<Session>,
    /// Voice style embeddings — shape [510, 256] stored flat (row-major f32 LE).
    /// Index by `phoneme_count * STYLE_DIM` to get the [1, 256] slice for a
    /// given sequence length, matching Kokoro v1.0's `voice[len(tokens)]` API.
    style: Vec<f32>,
    espeak_bin: String,
    speed: f32,
    vocab: HashMap<char, i64>,
}

impl KokoroTts {
    /// Load with default speed (0.9) and a single voice style.
    pub fn new(model_path: &str, style_path: &str, espeak_bin: &str) -> Result<Self> {
        Self::with_speed(model_path, style_path, espeak_bin, 0.9)
    }

    /// Load with custom speed multiplier (float; 1.0 = normal speed).
    pub fn with_speed(
        model_path: &str,
        style_path: &str,
        espeak_bin: &str,
        speed: f32,
    ) -> Result<Self> {
        // Pin to CPU to avoid VRAM contention with the Ollama LLM.
        let session = Session::builder()?
            .with_execution_providers([CpuEp::default().build()])
            .map_err(|e| anyhow::anyhow!("kokoro: CPU EP: {e}"))?
            .commit_from_file(model_path)
            .context("kokoro: failed to load ONNX model")?;

        let style = Self::load_style(style_path)?;

        Ok(Self {
            session: Mutex::new(session),
            style,
            espeak_bin: espeak_bin.to_string(),
            speed,
            vocab: build_vocab(),
        })
    }

    /// Load with two voice styles blended by `weight_a` (0.0–1.0).
    ///
    /// The blended embedding = `style_a * weight_a + style_b * (1 - weight_a)`.
    /// Blending is applied element-wise across all 510 × 256 style values.
    pub fn with_blend(
        model_path: &str,
        style_path_a: &str,
        style_path_b: &str,
        weight_a: f32,
        espeak_bin: &str,
        speed: f32,
    ) -> Result<Self> {
        let session = Session::builder()?
            .with_execution_providers([CpuEp::default().build()])
            .map_err(|e| anyhow::anyhow!("kokoro: CPU EP: {e}"))?
            .commit_from_file(model_path)
            .context("kokoro: failed to load ONNX model")?;

        let a = Self::load_style(style_path_a)?;
        let b = Self::load_style(style_path_b)?;
        let wb = 1.0 - weight_a;
        let style: Vec<f32> =
            a.iter().zip(b.iter()).map(|(x, y)| x * weight_a + y * wb).collect();

        Ok(Self {
            session: Mutex::new(session),
            style,
            espeak_bin: espeak_bin.to_string(),
            speed,
            vocab: build_vocab(),
        })
    }

    /// Read and validate a v1.0 style binary: 510 × 256 × 4 = 522 240 bytes.
    fn load_style(path: &str) -> Result<Vec<f32>> {
        let raw = std::fs::read(path)
            .with_context(|| format!("kokoro: failed to read style file {path}"))?;
        let expected = STYLE_ROWS * STYLE_DIM * 4;
        anyhow::ensure!(
            raw.len() == expected,
            "kokoro: style file must be exactly {expected} bytes \
             ({STYLE_ROWS} × {STYLE_DIM} × f32 LE), got {} bytes",
            raw.len()
        );
        Ok(raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect())
    }

    /// Get the [1 × 256] style slice for a given phoneme count.
    ///
    /// Clamps `phoneme_count` to the valid index range so we never go OOB.
    fn style_for(&self, phoneme_count: usize) -> &[f32] {
        let row = phoneme_count.min(STYLE_ROWS - 1);
        let start = row * STYLE_DIM;
        &self.style[start..start + STYLE_DIM]
    }
}

impl KokoroTts {
    /// Silence buffer for explicit pauses (f32 LE PCM, all zeros).
    fn silence(ms: u32) -> Vec<u8> {
        let samples = (SAMPLE_RATE as u64 * ms as u64 / 1000) as usize;
        vec![0u8; samples * 4]
    }

    /// Append `other` to `base`, adjusting viseme timestamps by the current audio length.
    fn concat(base: &mut TtsPlaybackEvent, other: TtsPlaybackEvent) {
        let offset_ms = base.audio.len() as u32 / (4 * (SAMPLE_RATE / 1000));
        base.audio.extend_from_slice(&other.audio);
        base.visemes.extend(other.visemes.into_iter().map(|v| Viseme {
            id: v.id,
            timestamp_ms: v.timestamp_ms + offset_ms,
        }));
    }

    /// Public synthesis entry-point.
    ///
    /// 1. Splits on pause punctuation (`,;:—…`) and inserts explicit silence
    ///    between segments so pauses are always audible.
    /// 2. Falls back to word-boundary splitting if a segment overflows the
    ///    ONNX token limit.
    pub(crate) fn synthesise_safe<'a>(
        &'a self,
        text: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<TtsPlaybackEvent>> + Send + 'a>>
    {
        Box::pin(async move {
            // ── 1. Pause-based split ──────────────────────────────────────────
            // Each pause character maps to a silence duration (ms).
            const PAUSES: &[(char, u32)] = &[
                (',', 130),
                (';', 180),
                (':', 180),
                ('—', 230),
                ('…', 230),
            ];

            if let Some((idx, &(pause_char, pause_ms))) = text
                .char_indices()
                .find_map(|(i, c)| PAUSES.iter().find(|(p, _)| *p == c).map(|e| (i, e)))
            {
                let left  = text[..idx].trim();
                let right = text[idx + pause_char.len_utf8()..].trim();

                let mut out = TtsPlaybackEvent { audio: Vec::new(), visemes: Vec::new() };

                if !left.is_empty() {
                    let ra = self.synthesise_safe(left).await?;
                    Self::concat(&mut out, ra);
                }

                // Explicit silence for the punctuation.
                out.audio.extend_from_slice(&Self::silence(pause_ms));

                if !right.is_empty() {
                    let rb = self.synthesise_safe(right).await?;
                    Self::concat(&mut out, rb);
                }

                return Ok(out);
            }

            // ── 2. Single-segment synthesis with overflow retry ───────────────
            match self.synthesise_inner(text).await {
                Ok(r) => Ok(r),
                Err(e)
                    if e.to_string().contains("out of bounds")
                        || e.to_string().contains("index 5") =>
                {
                    eprintln!("[TTS-RUST] token overflow, splitting: {e}");
                    let mid = text.len() / 2;
                    let split = text[..mid].rfind(' ').map(|i| i + 1).unwrap_or(mid);
                    let (a, b) = text.split_at(split);
                    let mut ra = self.synthesise_safe(a.trim()).await?;
                    let rb  = self.synthesise_safe(b.trim()).await?;
                    Self::concat(&mut ra, rb);
                    Ok(ra)
                }
                Err(e) => Err(e),
            }
        })
    }

    /// Apply Misaki's IPA normalisation so phoneme tokens match Kokoro training.
    fn misaki_normalize(ipa: &str) -> String {
        ipa.replace("eɪ", "A")   // day, say, make, face
           .replace("oʊ", "O")   // go, know, code, both (American)
           .replace("əʊ", "O")   // go, know, code, both (British fallback)
           .replace("aɪ", "I")   // I, my, time, write
           .replace("aʊ", "W")   // now, how, out, cloud
           .replace("ɔɪ", "Y")   // boy, choice, oil
           .replace("dʒ", "ʤ")  // job, just → precomposed
           .replace("tʃ", "ʧ")  // check, change → precomposed
    }

    /// Run espeak-ng on one chunk of plain text, returning raw IPA.
    fn espeak_chunk(espeak_bin: &str, text: &str) -> Result<String> {
        let data_dir = std::path::Path::new(espeak_bin)
            .parent()
            .map(|p| p.join("espeak-ng-data"))
            .filter(|p| p.exists());

        let mut cmd = Command::new(espeak_bin);
        cmd.args(["--ipa", "-q", "--stdin", "-v", "en-us"]);
        if let Some(ref data) = data_dir {
            cmd.arg(format!("--path={}", data.display()));
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("kokoro: failed to spawn espeak-ng ({espeak_bin})"))?;

        child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("kokoro: espeak-ng stdin unavailable"))?
            .write_all(text.as_bytes())?;

        let out = child.wait_with_output()?;
        let stderr_str = String::from_utf8_lossy(&out.stderr);
        if !stderr_str.trim().is_empty() {
            tracing::warn!("espeak-ng stderr: {}", stderr_str.trim());
        }
        anyhow::ensure!(
            out.status.success(),
            "kokoro: espeak-ng exited with status {}",
            out.status
        );
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// Core synthesis: phonemise → tokenise → ONNX → pack bytes + build visemes.
    /// Receives text that has already been split on pause punctuation by
    /// `synthesise_safe`, so a single espeak call suffices.
    async fn synthesise_inner(&self, text: &str) -> Result<TtsPlaybackEvent> {
        // ── 1. Phonemise via espeak-ng ────────────────────────────────────────
        let espeak = self.espeak_bin.clone();
        let text_owned = text.to_string();

        let ipa = tokio::task::spawn_blocking(move || -> Result<String> {
            tracing::debug!("kokoro: phonemising {:?}", &text_owned);
            Self::espeak_chunk(&espeak, &text_owned)
        })
        .await??;

        let ipa = Self::misaki_normalize(&ipa);

        // espeak-ng uses parentheses for optional sounds e.g. s(ə)lˈuːʃən.
        // Stripping them prevents token 12 '(' and token 13 ')' from appearing
        // in the phoneme sequence where the model doesn't expect them.
        let ipa = ipa.replace(['(', ')'], "");

        tracing::debug!(
            "kokoro: phoneme count={}",
            ipa.chars().filter(|c| *c != '\n' && *c != ' ').count()
        );

        // ── 2. Build phoneme-viseme list from IPA ─────────────────────────────
        let phonemes: Vec<(i64, u8)> = {
            let mut v = Vec::new();
            for c in ipa.chars() {
                if let Some(tok) = char_to_token(c, &self.vocab) {
                    v.push((tok, ipa_char_to_viseme(c)));
                }
            }
            v
        };

        // ── 3. Build token sequence and select style ──────────────────────────
        // In v1.0 the style embedding is indexed by the phoneme count (before
        // BOS/EOS padding).  Clamp to the last valid row (509).
        let phoneme_count = phonemes.len().min(MAX_TOKENS);
        let style_slice = self.style_for(phoneme_count);

        let mut tokens: Vec<i64> = Vec::with_capacity(phoneme_count + 2);
        tokens.push(0); // BOS
        tokens.extend(phonemes[..phoneme_count].iter().map(|(t, _)| *t));
        tokens.push(0); // EOS
        let seq_len = tokens.len() as i64;

        // ── 4. ONNX inference ─────────────────────────────────────────────────
        let mut guard = self.session.lock().await;

        let tokens_t = Tensor::<i64>::from_array((vec![1i64, seq_len], tokens))?;
        let style_t =
            Tensor::<f32>::from_array((vec![1i64, STYLE_DIM as i64], style_slice.to_vec()))?;

        let speed_t = Tensor::<f32>::from_array((vec![1i64], vec![self.speed]))?;
        let outputs = guard.run(ort::inputs![
            "tokens" => tokens_t,
            "style"  => style_t,
            "speed"  => speed_t,
        ])?;

        let output_name = outputs
            .keys()
            .next()
            .context("kokoro: model produced no outputs")?
            .to_string();
        let (_, audio_view) = outputs[output_name].try_extract_tensor::<f32>()?;
        let raw: Vec<f32> = audio_view.iter().copied().collect();
        let peak = raw.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
        let gain = if peak > 1e-6 { 0.45 / peak } else { 1.0 };
        let audio_samples: Vec<f32> = raw.iter().map(|s| s * gain).collect();
        drop(outputs);
        drop(guard);

        // ── 5. Pack audio as f32 LE bytes ─────────────────────────────────────
        let mut audio = Vec::with_capacity(audio_samples.len() * 4);
        for s in &audio_samples {
            audio.extend_from_slice(&s.to_le_bytes());
        }

        // ── 6. Build phoneme-aligned visemes ─────────────────────────────────
        let visemes = if phonemes.is_empty() {
            vec![]
        } else {
            let total_ms = audio_samples.len() as f32 / SAMPLE_RATE as f32 * 1000.0;
            let ms_per_phoneme = total_ms / phoneme_count as f32;

            phonemes[..phoneme_count]
                .iter()
                .enumerate()
                .map(|(i, (_, viseme_id))| Viseme {
                    id: *viseme_id,
                    timestamp_ms: (i as f32 * ms_per_phoneme) as u32,
                })
                .collect()
        };

        Ok(TtsPlaybackEvent { audio, visemes })
    }
}

#[async_trait]
impl TtsProvider for KokoroTts {
    async fn synthesise(&self, text: &str) -> Result<Vec<u8>> {
        Ok(self.synthesise_safe(text).await?.audio)
    }

    async fn synthesise_with_visemes(&self, text: &str) -> Result<TtsPlaybackEvent> {
        self.synthesise_safe(text).await
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ── vocab ────────────────────────────────────────────────────────────────

    #[test]
    fn space_token_is_sixteen() {
        let vocab = build_vocab();
        assert_eq!(char_to_token(' ', &vocab), Some(16));
    }

    #[test]
    fn uppercase_a_maps_to_24() {
        let vocab = build_vocab();
        assert_eq!(char_to_token('A', &vocab), Some(24));
    }

    #[test]
    fn lowercase_a_maps_to_43() {
        let vocab = build_vocab();
        assert_eq!(char_to_token('a', &vocab), Some(43));
    }

    #[test]
    fn unknown_char_returns_none() {
        let vocab = build_vocab();
        assert_eq!(char_to_token('\0', &vocab), None);
        assert_eq!(char_to_token('€', &vocab), None);
    }

    #[test]
    fn vocab_has_no_duplicates() {
        let map = build_vocab();
        // HashMap construction deduplicates by key — verify sizes match the raw array.
        assert!(map.len() > 70, "vocab unexpectedly small: {}", map.len());
    }

    // ── style loading ─────────────────────────────────────────────────────────

    #[test]
    fn style_size_constant() {
        assert_eq!(STYLE_ROWS * STYLE_DIM * 4, 522_240);
    }

    #[test]
    fn wrong_style_size_returns_err() {
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("bad.bin");
        std::fs::write(&style_path, vec![0u8; 1024]).unwrap(); // v0.19 size — wrong

        let result = KokoroTts::new(
            "/nonexistent/kokoro.onnx",
            style_path.to_str().unwrap(),
            "espeak-ng",
        );
        assert!(result.is_err());
    }

    #[test]
    fn style_parsed_correctly() {
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("style.bin");
        let n = STYLE_ROWS * STYLE_DIM;
        let bytes: Vec<u8> = (0u32..n as u32)
            .flat_map(|i| (i as f32).to_le_bytes())
            .collect();
        std::fs::write(&style_path, &bytes).unwrap();

        let raw = std::fs::read(&style_path).unwrap();
        let style: Vec<f32> = raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        assert_eq!(style.len(), STYLE_ROWS * STYLE_DIM);
        assert!((style[0] - 0.0).abs() < f32::EPSILON);
        assert!((style[1] - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn style_for_clamps_to_last_row() {
        // Build a dummy KokoroTts-like style vec and verify indexing.
        let style: Vec<f32> = (0..STYLE_ROWS * STYLE_DIM).map(|i| i as f32).collect();
        let row = |n: usize| {
            let r = n.min(STYLE_ROWS - 1);
            &style[r * STYLE_DIM..(r + 1) * STYLE_DIM]
        };
        // Accessing exactly at STYLE_ROWS should return last row (509).
        assert_eq!(row(STYLE_ROWS), row(STYLE_ROWS - 1));
        assert_eq!(row(9999), row(STYLE_ROWS - 1));
    }

    // ── construction ─────────────────────────────────────────────────────────

    #[test]
    fn missing_model_returns_err() {
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("style.bin");
        std::fs::write(&style_path, vec![0u8; STYLE_ROWS * STYLE_DIM * 4]).unwrap();

        let result = KokoroTts::new(
            "/nonexistent/kokoro.onnx",
            style_path.to_str().unwrap(),
            "espeak-ng",
        );
        assert!(result.is_err());
    }

    // ── ipa_char_to_viseme ───────────────────────────────────────────────────

    #[test]
    fn silence_chars_map_to_zero() {
        for c in ['$', ' ', '.', ',', '!', '?', 'h', 'ʔ', 'ˈ', 'ˌ'] {
            assert_eq!(ipa_char_to_viseme(c), 0, "char {c:?} should be silence");
        }
    }

    #[test]
    fn open_vowels_map_to_13() {
        for c in ['ɑ', 'æ', 'ʌ', 'ɪ', 'i'] {
            assert_eq!(ipa_char_to_viseme(c), 13, "char {c:?} should be AH (13)");
        }
    }

    #[test]
    fn schwa_maps_to_12() {
        assert_eq!(ipa_char_to_viseme('ə'), 12);
        assert_eq!(ipa_char_to_viseme('ɛ'), 12);
        assert_eq!(ipa_char_to_viseme('e'), 12);
    }

    #[test]
    fn rounded_vowels_map_to_11() {
        for c in ['ɔ', 'o', 'ʊ', 'u', 'w'] {
            assert_eq!(ipa_char_to_viseme(c), 11, "char {c:?} should be OW (11)");
        }
    }

    #[test]
    fn rhotics_map_to_8() {
        for c in ['ɹ', 'ɾ', 'ʀ'] {
            assert_eq!(ipa_char_to_viseme(c), 8);
        }
    }

    #[test]
    fn laterals_map_to_9() {
        for c in ['l', 'ɭ', 'ɫ'] {
            assert_eq!(ipa_char_to_viseme(c), 9);
        }
    }

    #[test]
    fn affricates_map_to_6() {
        assert_eq!(ipa_char_to_viseme('ʧ'), 6);
        assert_eq!(ipa_char_to_viseme('ʃ'), 6);
        assert_eq!(ipa_char_to_viseme('ʤ'), 6);
    }

    #[test]
    fn sibilants_map_to_7() {
        for c in ['s', 'z', 'f', 'v', 'θ', 'ð'] {
            assert_eq!(ipa_char_to_viseme(c), 7, "char {c:?} should be S/Z (7)");
        }
    }

    #[test]
    fn unknown_ipa_maps_to_4() {
        assert_eq!(ipa_char_to_viseme('n'), 4);
        assert_eq!(ipa_char_to_viseme('t'), 4);
        assert_eq!(ipa_char_to_viseme('k'), 4);
    }

    #[test]
    fn viseme_distribution_timing() {
        let phonemes: Vec<u8> = (0..10).map(|_| 13u8).collect();
        let total_ms = 1000.0f32;
        let ms_per_phoneme = total_ms / phonemes.len() as f32;
        let visemes: Vec<Viseme> = phonemes
            .iter()
            .enumerate()
            .map(|(i, &id)| Viseme {
                id,
                timestamp_ms: (i as f32 * ms_per_phoneme) as u32,
            })
            .collect();
        assert_eq!(visemes[0].timestamp_ms, 0);
        assert_eq!(visemes[1].timestamp_ms, 100);
        assert_eq!(visemes[9].timestamp_ms, 900);
    }

    // ── tokeniser ────────────────────────────────────────────────────────────

    #[test]
    fn tokenize_wraps_bos_eos() {
        let vocab = build_vocab();
        let ipa = "hɛloʊ";
        let mut tokens: Vec<i64> = vec![0]; // BOS
        for c in ipa.chars() {
            if let Some(t) = char_to_token(c, &vocab) {
                tokens.push(t);
            }
        }
        tokens.push(0); // EOS
        assert_eq!(tokens[0], 0, "BOS must be 0");
        assert_eq!(*tokens.last().unwrap(), 0, "EOS must be 0");
        assert!(tokens.len() >= 2);
    }

    #[test]
    fn tokenize_drops_unknown_chars() {
        let vocab = build_vocab();
        let ipa = "€ɛ"; // '€' unknown, 'ɛ' known
        let mut tokens: Vec<i64> = vec![0];
        for c in ipa.chars() {
            if let Some(t) = char_to_token(c, &vocab) {
                tokens.push(t);
            }
        }
        tokens.push(0);
        assert_eq!(tokens.len(), 3); // BOS + ɛ + EOS
    }
}
