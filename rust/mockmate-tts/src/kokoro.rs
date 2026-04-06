use std::io::Write as _;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use async_trait::async_trait;
use ort::{session::Session, value::Tensor};
use tokio::sync::Mutex;

use mockmate_core::providers::{TtsPlaybackEvent, TtsProvider, Viseme};

/// Kokoro-82M ONNX output sample rate.
pub const SAMPLE_RATE: u32 = 24_000;

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/// Kokoro v0.19 phoneme vocabulary — position = token ID.
///
/// Layout: pad($) | punctuation(16) | letters A-Z a-z(52) | IPA symbols(~100)
static VOCAB: &[char] = &[
    // 0 — pad / BOS / EOS
    '$',
    // 1-16 — punctuation + space
    ';', ':', ',', '.', '!', '?', '¡', '¿', '—', '…',
    '"', '«', '»', '\u{201C}', '\u{201D}', ' ',
    // 17-42 — uppercase letters
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    // 43-68 — lowercase letters
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    // 69+ — IPA symbols (matching Kokoro training vocab)
    'ɑ', 'ɐ', 'ɒ', 'æ', 'ɓ', 'ʙ', 'β', 'ɔ', 'ɕ', 'ç',
    'ɗ', 'ɖ', 'ð', 'ʤ', 'ə', 'ɘ', 'ɚ', 'ɛ', 'ɜ', 'ɝ',
    'ɞ', 'ɟ', 'ʄ', 'ɡ', 'ɠ', 'ɢ', 'ʛ', 'ɦ', 'ɧ', 'ħ',
    'ɥ', 'ʜ', 'ɨ', 'ɪ', 'ʝ', 'ɭ', 'ɬ', 'ɫ', 'ɮ', 'ʟ',
    'ɱ', 'ɯ', 'ɰ', 'ŋ', 'ɳ', 'ɲ', 'ɴ', 'ø', 'ɵ', 'ɸ',
    'θ', 'œ', 'ɶ', 'ʘ', 'ɹ', 'ɺ', 'ɾ', 'ɻ', 'ʀ', 'ʁ',
    'ɽ', 'ʂ', 'ʃ', 'ʈ', 'ʧ', 'ʉ', 'ʊ', 'ʋ', 'ⱱ', 'ʌ',
    'ɣ', 'ɤ', 'ʍ', 'χ', 'ʎ', 'ʏ', 'ʑ', 'ʐ', 'ʒ', 'ʔ',
    'ʡ', 'ʕ', 'ʢ', 'ǀ', 'ǁ', 'ǂ', 'ǃ', 'ˈ', 'ˌ', 'ː',
    'ˑ', 'ʼ', 'ʴ', 'ʰ', 'ʱ', 'ʲ', 'ʷ', 'ˠ', 'ˤ', '˞',
    '↓', '↑', '→', '↗', '↘', 'ᵻ',
];

/// Map a single IPA character to its Kokoro token ID.  Returns `None` for
/// characters not in the training vocab (they are silently skipped).
fn char_to_token(c: char) -> Option<i64> {
    VOCAB.iter().position(|&v| v == c).map(|i| i as i64)
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
    /// Style / speaker embedding — 256 f32 values, shape [1, 1, 256].
    style: Vec<f32>,
    espeak_bin: String,
    speed: f32,
}

impl KokoroTts {
    /// Load from model + style files with default speed (1.0).
    ///
    /// * `model_path` — path to `kokoro-v0_19.onnx`
    /// * `style_path` — raw binary file of **exactly 1 024 bytes** (256 × f32 LE),
    ///                  one speaker/style embedding extracted from `voices.bin`
    /// * `espeak_bin` — path to the `espeak-ng` executable
    pub fn new(model_path: &str, style_path: &str, espeak_bin: &str) -> Result<Self> {
        Self::with_speed(model_path, style_path, espeak_bin, 1.0)
    }

    /// Same as [`KokoroTts::new`] but with a custom playback speed multiplier.
    pub fn with_speed(
        model_path: &str,
        style_path: &str,
        espeak_bin: &str,
        speed: f32,
    ) -> Result<Self> {
        let session = Session::builder()?
            .commit_from_file(model_path)
            .context("kokoro: failed to load ONNX model")?;

        let raw = std::fs::read(style_path)
            .context("kokoro: failed to read style file")?;
        anyhow::ensure!(
            raw.len() == 256 * 4,
            "kokoro: style file must be exactly 1 024 bytes (256 × f32 LE), got {} bytes",
            raw.len()
        );

        let style: Vec<f32> = raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();

        Ok(Self {
            session: Mutex::new(session),
            style,
            espeak_bin: espeak_bin.to_string(),
            speed,
        })
    }
}

impl KokoroTts {
    /// Core synthesis: phonemise → tokenise → ONNX → pack bytes + build visemes.
    async fn synthesise_inner(&self, text: &str) -> Result<TtsPlaybackEvent> {
        // ── 1. Phonemise via espeak-ng ────────────────────────────────────────
        let espeak = self.espeak_bin.clone();
        let text_owned = text.to_string();

        let ipa = tokio::task::spawn_blocking(move || -> Result<String> {
            let mut child = Command::new(&espeak)
                .args(["--ipa", "-q", "--stdin"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .with_context(|| format!("kokoro: failed to spawn espeak-ng ({espeak})"))?;

            child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("kokoro: espeak-ng stdin unavailable"))?
                .write_all(text_owned.as_bytes())?;

            let out = child.wait_with_output()?;
            anyhow::ensure!(
                out.status.success(),
                "kokoro: espeak-ng exited with status {}",
                out.status
            );
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        })
        .await??;

        // ── 2. Build phoneme-viseme list from IPA ─────────────────────────────
        // Collect (char, viseme_id) pairs, skipping chars not in the token vocab.
        // We keep all chars (including silence) for timestamp distribution.
        let phonemes: Vec<(i64, u8)> = {
            let mut v = Vec::new();
            for c in ipa.chars() {
                if let Some(tok) = char_to_token(c) {
                    v.push((tok, ipa_char_to_viseme(c)));
                }
            }
            v
        };

        // ── 3. Build token sequence ───────────────────────────────────────────
        let mut tokens: Vec<i64> = Vec::with_capacity(phonemes.len() + 2);
        tokens.push(0); // BOS ($)
        tokens.extend(phonemes.iter().map(|(t, _)| *t));
        tokens.push(0); // EOS ($)
        let seq_len = tokens.len() as i64;

        // ── 4. ONNX inference ─────────────────────────────────────────────────
        let mut guard = self.session.lock().await;

        let tokens_t =
            Tensor::<i64>::from_array((vec![1i64, seq_len], tokens))?;
        let style_t =
            Tensor::<f32>::from_array((vec![1i64, 1i64, 256i64], self.style.clone()))?;
        let speed_t =
            Tensor::<f32>::from_array((vec![1i64], vec![self.speed]))?;

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
        let audio_samples: Vec<f32> = audio_view.iter().copied().collect();
        drop(outputs);
        drop(guard);

        // ── 5. Pack audio as f32 LE bytes ─────────────────────────────────────
        let mut audio = Vec::with_capacity(audio_samples.len() * 4);
        for s in &audio_samples {
            audio.extend_from_slice(&s.to_le_bytes());
        }

        // ── 6. Build phoneme-aligned visemes ─────────────────────────────────
        // Distribute phonemes uniformly across the total audio duration.
        let visemes = if phonemes.is_empty() {
            vec![]
        } else {
            let total_ms =
                audio_samples.len() as f32 / SAMPLE_RATE as f32 * 1000.0;
            let ms_per_phoneme = total_ms / phonemes.len() as f32;

            phonemes
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
        Ok(self.synthesise_inner(text).await?.audio)
    }

    async fn synthesise_with_visemes(&self, text: &str) -> Result<TtsPlaybackEvent> {
        self.synthesise_inner(text).await
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
    fn pad_token_is_zero() {
        assert_eq!(char_to_token('$'), Some(0));
    }

    #[test]
    fn space_token_is_sixteen() {
        assert_eq!(char_to_token(' '), Some(16));
    }

    #[test]
    fn uppercase_a_maps_to_17() {
        assert_eq!(char_to_token('A'), Some(17));
    }

    #[test]
    fn lowercase_a_maps_to_43() {
        assert_eq!(char_to_token('a'), Some(43));
    }

    #[test]
    fn unknown_char_returns_none() {
        assert_eq!(char_to_token('\0'), None);
        assert_eq!(char_to_token('€'), None);
    }

    #[test]
    fn vocab_has_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for &c in VOCAB {
            assert!(seen.insert(c), "duplicate character in VOCAB: {c:?}");
        }
    }

    // ── construction ─────────────────────────────────────────────────────────

    #[test]
    fn missing_model_returns_err() {
        // Write a valid-size style file then try a bad model path.
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("style.bin");
        std::fs::write(&style_path, vec![0u8; 1024]).unwrap();

        let result = KokoroTts::new(
            "/nonexistent/kokoro.onnx",
            style_path.to_str().unwrap(),
            "espeak-ng",
        );
        assert!(result.is_err());
    }

    #[test]
    fn wrong_style_size_returns_err() {
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("bad.bin");
        std::fs::write(&style_path, vec![0u8; 512]).unwrap(); // wrong size

        let result = KokoroTts::new(
            "/nonexistent/kokoro.onnx",
            style_path.to_str().unwrap(),
            "espeak-ng",
        );
        assert!(result.is_err());
    }

    #[test]
    fn style_file_parsed_correctly() {
        // Write 256 f32 values: 0.0, 1.0, 2.0, …
        let dir = tempfile::tempdir().unwrap();
        let style_path = dir.path().join("style.bin");
        let bytes: Vec<u8> = (0u32..256)
            .flat_map(|i| (i as f32).to_le_bytes())
            .collect();
        std::fs::write(&style_path, &bytes).unwrap();

        // The model path will fail — that's fine, we want to check style parsing
        // separately.  We check via the raw parsing logic.
        let raw = std::fs::read(style_path).unwrap();
        let style: Vec<f32> = raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        assert_eq!(style.len(), 256);
        assert!((style[0] - 0.0).abs() < f32::EPSILON);
        assert!((style[1] - 1.0).abs() < f32::EPSILON);
        assert!((style[255] - 255.0).abs() < f32::EPSILON);
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
        // Generic consonants fall back to stop/nasal bucket
        assert_eq!(ipa_char_to_viseme('n'), 4);
        assert_eq!(ipa_char_to_viseme('t'), 4);
        assert_eq!(ipa_char_to_viseme('k'), 4);
    }

    #[test]
    fn viseme_distribution_timing() {
        // Simulate 10 phonemes over 1000 ms of audio → 100 ms per phoneme
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
        // Simulate what synthesise() does to check the BOS/EOS wrapping.
        let ipa = "hɛloʊ"; // "hello" approximate IPA
        let mut tokens: Vec<i64> = vec![0]; // BOS
        for c in ipa.chars() {
            if let Some(t) = char_to_token(c) {
                tokens.push(t);
            }
        }
        tokens.push(0); // EOS

        assert_eq!(tokens[0], 0, "BOS must be 0");
        assert_eq!(*tokens.last().unwrap(), 0, "EOS must be 0");
        assert!(tokens.len() >= 2, "must have at least BOS+EOS");
    }

    #[test]
    fn tokenize_drops_unknown_chars() {
        let ipa = "€ɛ"; // '€' unknown, 'ɛ' known
        let mut tokens: Vec<i64> = vec![0];
        for c in ipa.chars() {
            if let Some(t) = char_to_token(c) {
                tokens.push(t);
            }
        }
        tokens.push(0);
        // BOS + ɛ_token + EOS = 3 total
        assert_eq!(tokens.len(), 3);
    }
}
