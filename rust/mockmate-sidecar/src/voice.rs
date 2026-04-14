//! Kokoro TTS asset management — download model + voice style on first run.
//!
//! Assets downloaded:
//!   - `kokoro-v1.0.onnx`  (~325 MB full / ~80 MB quantized) — the ONNX model
//!   - `af_heart.bin`       (522 240 B) — pre-extracted voice style embeddings
//!                           shape [510, 1, 256] f32 LE (one row per sequence length)
//!
//! espeak-ng is NOT downloaded here; it is expected to be bundled with the
//! installer at `{install_dir}\espeak-ng\espeak-ng.exe`.  As a fallback the
//! function also checks `PATH` so developer machines with a system install
//! still work.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// Download URLs
// ---------------------------------------------------------------------------

/// Kokoro-82M ONNX model (v1.0) — thewh1teagle mirror on GitHub Releases.
const KOKORO_ONNX_URL: &str =
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx";

/// Pre-packaged voices ZIP — per-voice numpy arrays (shape [510, 1, 256] f32).
const VOICES_BIN_URL: &str =
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin";

/// Voice to extract.
const VOICE_NAME: &str = "am_adam";
/// Fallback voice if VOICE_NAME is not found.
const VOICE_FALLBACK: &str = "af_bella";

/// Expected number of style rows (one per possible sequence length).
const STYLE_ROWS: usize = 510;
/// Style dimensions per row.
const STYLE_DIM: usize = 256;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Resolved on-disk paths for all three Kokoro inputs.
#[derive(Debug, Clone)]
pub struct KokoroPaths {
    pub model: PathBuf,
    pub style: PathBuf,
    pub espeak_bin: PathBuf,
}

/// Progress event emitted while assets are being fetched.
#[derive(Debug, Clone)]
pub struct VoiceSetupProgress {
    /// Human-readable label (e.g. "Downloading Kokoro model…").
    pub step: String,
    /// Bytes received so far; 0 when not yet started.
    pub bytes_done: u64,
    /// Total bytes expected; 0 when Content-Length is unknown.
    pub bytes_total: u64,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Ensure all Kokoro TTS assets are present in `dir`.
///
/// Downloads any missing files, streaming progress via `tx`.  Returns the
/// resolved paths on success.  Sending on `tx` may fail if the receiver is
/// dropped — those errors are silently ignored (progress is best-effort).
pub async fn ensure_kokoro_assets(
    dir: &Path,
    espeak_dir: &Path,
    tx: mpsc::Sender<VoiceSetupProgress>,
) -> Result<KokoroPaths> {
    tokio::fs::create_dir_all(dir)
        .await
        .context("create kokoro asset dir")?;

    let model_path = dir.join("kokoro-v1.0.onnx");
    let style_path = dir.join(format!("{VOICE_NAME}.bin"));

    // ── Model ────────────────────────────────────────────────────────────────
    if !model_path.exists() {
        emit(&tx, "Downloading Kokoro model…", 0, 0).await;
        download_with_progress(KOKORO_ONNX_URL, &model_path, "Kokoro model", &tx).await?;
    } else {
        emit(&tx, "Kokoro model: already present", 0, 0).await;
    }

    // ── Voice style ──────────────────────────────────────────────────────────
    if !style_path.exists() {
        emit(&tx, "Downloading voice styles…", 0, 0).await;
        download_and_extract_voice(VOICES_BIN_URL, VOICE_NAME, VOICE_FALLBACK, &style_path, &tx)
            .await?;
    } else {
        emit(&tx, "Voice style: already present", 0, 0).await;
    }

    // ── espeak-ng ────────────────────────────────────────────────────────────
    let espeak_bin = resolve_espeak(espeak_dir)?;
    emit(&tx, &format!("espeak-ng: {}", espeak_bin.display()), 0, 0).await;

    Ok(KokoroPaths { model: model_path, style: style_path, espeak_bin })
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

async fn emit(tx: &mpsc::Sender<VoiceSetupProgress>, step: &str, done: u64, total: u64) {
    let _ = tx
        .send(VoiceSetupProgress {
            step: step.to_string(),
            bytes_done: done,
            bytes_total: total,
        })
        .await;
}

/// Stream-download `url` to `dest`, emitting progress events.
async fn download_with_progress(
    url: &str,
    dest: &Path,
    label: &str,
    tx: &mpsc::Sender<VoiceSetupProgress>,
) -> Result<()> {
    let client = reqwest::Client::builder().user_agent("MockMate/1.0").build()?;

    let resp = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("HTTP error for {url}"))?;

    let total = resp.content_length().unwrap_or(0);
    let mut bytes_done: u64 = 0;

    // Write to a temp file so a partial download never leaves a corrupt asset.
    let tmp = dest.with_extension("tmp");
    let mut file = std::fs::File::create(&tmp)
        .with_context(|| format!("create tmp file {}", tmp.display()))?;

    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("stream read error")?;
        file.write_all(&chunk).context("write chunk")?;
        bytes_done += chunk.len() as u64;
        emit(tx, &format!("Downloading {label}…"), bytes_done, total).await;
    }

    drop(file);
    std::fs::rename(&tmp, dest)
        .with_context(|| format!("rename {} → {}", tmp.display(), dest.display()))?;

    Ok(())
}

/// Download voices-v1.0.bin (ZIP of .npy files), extract `voice_name`'s numpy
/// array (shape [510, 1, 256] f32 LE), and save the raw float data to `dest`.
async fn download_and_extract_voice(
    bin_url: &str,
    voice_name: &str,
    fallback: &str,
    dest: &Path,
    tx: &mpsc::Sender<VoiceSetupProgress>,
) -> Result<()> {
    let client = reqwest::Client::builder().user_agent("MockMate/1.0").build()?;

    let resp = client
        .get(bin_url)
        .send()
        .await
        .with_context(|| format!("GET {bin_url}"))?
        .error_for_status()
        .with_context(|| format!("HTTP error for {bin_url}"))?;

    let total = resp.content_length().unwrap_or(0);
    let mut bytes_done: u64 = 0;
    let mut buf: Vec<u8> =
        if total > 0 { Vec::with_capacity(total as usize) } else { Vec::new() };

    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("stream read error")?;
        bytes_done += chunk.len() as u64;
        buf.extend_from_slice(&chunk);
        emit(tx, "Downloading voice styles…", bytes_done, total).await;
    }

    emit(tx, "Extracting voice style…", 0, 0).await;

    let voice_name = voice_name.to_string();
    let fallback = fallback.to_string();
    let floats = tokio::task::spawn_blocking(move || {
        extract_voice_npy(&buf, &voice_name, &fallback)
    })
    .await??;

    // Write as flat f32 LE binary: 510 × 256 × 4 = 522 240 bytes.
    let mut style_bytes = Vec::with_capacity(floats.len() * 4);
    for f in &floats {
        style_bytes.extend_from_slice(&f.to_le_bytes());
    }

    std::fs::write(dest, &style_bytes)
        .with_context(|| format!("write {}", dest.display()))?;

    Ok(())
}

/// Open `zip_data` as a ZIP archive, find `{voice_name}.npy` (or `{fallback}.npy`),
/// parse the numpy header, and return all f32 values from the data section.
fn extract_voice_npy(zip_data: &[u8], voice_name: &str, fallback: &str) -> Result<Vec<f32>> {
    let cursor = std::io::Cursor::new(zip_data);
    let mut archive =
        zip::ZipArchive::new(cursor).context("voices bin: not a valid ZIP archive")?;

    let primary = format!("{voice_name}.npy");
    let secondary = format!("{fallback}.npy");

    let npy_data = {
        let entry_name = if archive.by_name(&primary).is_ok() {
            primary
        } else if archive.by_name(&secondary).is_ok() {
            secondary
        } else {
            anyhow::bail!("voices ZIP: neither '{voice_name}' nor '{fallback}' found");
        };

        let mut entry =
            archive.by_name(&entry_name).with_context(|| format!("open {entry_name}"))?;
        let mut buf = Vec::new();
        entry.read_to_end(&mut buf).context("read npy entry")?;
        buf
    };

    parse_npy_f32(&npy_data, voice_name)
}

/// Parse a numpy v1/v2 `.npy` file containing a contiguous f32 LE array.
/// Expected shape: `[STYLE_ROWS, 1, STYLE_DIM]` = [510, 1, 256].
fn parse_npy_f32(data: &[u8], label: &str) -> Result<Vec<f32>> {
    // Magic: \x93NUMPY
    anyhow::ensure!(data.len() > 10, "{label}.npy: file too short");
    anyhow::ensure!(
        &data[0..6] == b"\x93NUMPY",
        "{label}.npy: invalid numpy magic bytes"
    );

    let major = data[6];
    let (header_len, data_offset) = if major == 1 {
        let len = u16::from_le_bytes([data[8], data[9]]) as usize;
        (len, 10 + len)
    } else {
        // numpy format v2+: 4-byte header length
        anyhow::ensure!(data.len() > 12, "{label}.npy: v2 header truncated");
        let len = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;
        (len, 12 + len)
    };

    anyhow::ensure!(
        data.len() >= data_offset,
        "{label}.npy: header claims {} bytes but file is only {}",
        data_offset,
        data.len()
    );
    let _ = header_len; // validated implicitly via data_offset

    let raw = &data[data_offset..];
    let expected_bytes = STYLE_ROWS * STYLE_DIM * 4;

    anyhow::ensure!(
        raw.len() == expected_bytes,
        "{label}.npy: expected {} bytes for [{STYLE_ROWS}, 1, {STYLE_DIM}] f32, got {}",
        expected_bytes,
        raw.len()
    );

    Ok(raw
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

/// Find espeak-ng binary.
///
/// Priority:
/// 1. `{espeak_dir}\espeak-ng.exe` (bundled with installer on Windows)
/// 2. `espeak-ng` / `espeak-ng.exe` on PATH
fn resolve_espeak(espeak_dir: &Path) -> Result<PathBuf> {
    // 1. Bundled alongside the app
    #[cfg(windows)]
    let bundled = espeak_dir.join("espeak-ng.exe");
    #[cfg(not(windows))]
    let bundled = espeak_dir.join("espeak-ng");

    if bundled.exists() {
        return Ok(bundled);
    }

    // 2. System PATH
    #[cfg(windows)]
    let names = &["espeak-ng.exe", "espeak-ng"];
    #[cfg(not(windows))]
    let names = &["espeak-ng"];

    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            for name in names.iter() {
                let candidate = dir.join(name);
                if candidate.exists() {
                    return Ok(candidate);
                }
            }
        }
    }

    anyhow::bail!(
        "espeak-ng not found. Expected at '{}' (bundled) or on PATH.",
        bundled.display()
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn resolve_espeak_nonexistent_dir_falls_back_to_path() {
        let result = resolve_espeak(&PathBuf::from("/nonexistent/dir"));
        let _ = result;
    }

    #[test]
    fn style_file_size_constant() {
        // 510 rows × 256 dims × 4 bytes = 522 240
        assert_eq!(STYLE_ROWS * STYLE_DIM * std::mem::size_of::<f32>(), 522_240);
    }

    #[test]
    fn parse_npy_rejects_wrong_magic() {
        let bad = vec![0u8; 512];
        assert!(parse_npy_f32(&bad, "test").is_err());
    }

    #[test]
    fn parse_npy_rejects_wrong_size() {
        // Build a minimal valid v1 npy header with wrong data size.
        let header_str = b"{'descr': '<f4', 'fortran_order': False, 'shape': (1, 1, 1), }    \n";
        let header_len = header_str.len() as u16;
        let mut npy: Vec<u8> = Vec::new();
        npy.extend_from_slice(b"\x93NUMPY");
        npy.push(1); // major
        npy.push(0); // minor
        npy.extend_from_slice(&header_len.to_le_bytes());
        npy.extend_from_slice(header_str);
        // Only 4 bytes of data (1 f32) — wrong for 510×256
        npy.extend_from_slice(&0.0f32.to_le_bytes());
        assert!(parse_npy_f32(&npy, "test").is_err());
    }
}
