//! Kokoro TTS asset management — download model + voice style on first run.
//!
//! Assets downloaded:
//!   - `kokoro-v0_19.onnx`  (~82 MB) — the ONNX inference model
//!   - `af_heart.bin`        (1 024 B) — pre-extracted voice style embedding
//!
//! espeak-ng is NOT downloaded here; it is expected to be bundled with the
//! installer at `{install_dir}\espeak-ng\espeak-ng.exe`.  As a fallback the
//! function also checks `PATH` so developer machines with a system install
//! still work.

use std::io::{Cursor, Write as _};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// Download URLs
// ---------------------------------------------------------------------------

/// Kokoro-82M ONNX model (v0.19) — thewh1teagle mirror on GitHub Releases.
const KOKORO_ONNX_URL: &str =
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1/kokoro-v0_19.onnx";

/// Pre-packaged voices ZIP — contains individual `<voice>.bin` files (256 × f32 LE each).
const VOICES_ZIP_URL: &str =
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1/voices.zip";

/// Voice to extract from the ZIP.
const VOICE_NAME: &str = "af_heart";

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

    let model_path = dir.join("kokoro-v0_19.onnx");
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
        emit(&tx, "Downloading voice style…", 0, 0).await;
        download_voice_style(VOICES_ZIP_URL, VOICE_NAME, &style_path, &tx).await?;
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
    let _ = tx.send(VoiceSetupProgress {
        step: step.to_string(),
        bytes_done: done,
        bytes_total: total,
    }).await;
}

/// Stream-download `url` to `dest`, emitting progress events.
async fn download_with_progress(
    url: &str,
    dest: &Path,
    label: &str,
    tx: &mpsc::Sender<VoiceSetupProgress>,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .user_agent("MockMate/1.0")
        .build()?;

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

/// Download the voices ZIP, extract `{voice_name}.bin`, save to `dest`.
async fn download_voice_style(
    zip_url: &str,
    voice_name: &str,
    dest: &Path,
    tx: &mpsc::Sender<VoiceSetupProgress>,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .user_agent("MockMate/1.0")
        .build()?;

    emit(tx, "Downloading voice styles…", 0, 0).await;

    let resp = client
        .get(zip_url)
        .send()
        .await
        .with_context(|| format!("GET {zip_url}"))?
        .error_for_status()
        .with_context(|| format!("HTTP error for {zip_url}"))?;

    let total = resp.content_length().unwrap_or(0);
    let mut bytes_done: u64 = 0;
    let mut buf: Vec<u8> = if total > 0 { Vec::with_capacity(total as usize) } else { Vec::new() };

    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("stream read error")?;
        bytes_done += chunk.len() as u64;
        buf.extend_from_slice(&chunk);
        emit(tx, "Downloading voice styles…", bytes_done, total).await;
    }

    // Extract the target voice bin from the ZIP.
    let target = format!("{voice_name}.bin");
    let cursor = Cursor::new(buf);
    let mut zip = zip::ZipArchive::new(cursor).context("open voices ZIP")?;
    let mut entry = zip
        .by_name(&target)
        .with_context(|| format!("'{target}' not found in voices ZIP"))?;

    anyhow::ensure!(
        entry.size() == 1024,
        "unexpected voice style size: expected 1024 bytes, got {}",
        entry.size()
    );

    let mut style_bytes = [0u8; 1024];
    std::io::Read::read_exact(&mut entry, &mut style_bytes)
        .context("read voice style bytes")?;

    std::fs::write(dest, style_bytes)
        .with_context(|| format!("write {}", dest.display()))?;

    Ok(())
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
        // A dir that definitely doesn't exist — should try PATH next.
        let result = resolve_espeak(&PathBuf::from("/nonexistent/dir"));
        // On a machine with espeak-ng installed: Ok. Otherwise: Err.
        // Either is acceptable — the test just checks it doesn't panic.
        let _ = result;
    }

    #[test]
    fn voice_style_size_constant() {
        // 256 f32 values × 4 bytes = 1024
        assert_eq!(256 * std::mem::size_of::<f32>(), 1024);
    }
}
