use std::process::{Child, Command};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const OLLAMA_BASE_URL: &str = "http://localhost:11434";

static CHILD: OnceLock<Mutex<Option<Child>>> = OnceLock::new();

fn child_lock() -> &'static Mutex<Option<Child>> {
    CHILD.get_or_init(|| Mutex::new(None))
}

/// `true` if Ollama's `/api/tags` endpoint responds with 200.
pub async fn is_ollama_running(base_url: &str) -> bool {
    reqwest::get(format!("{base_url}/api/tags"))
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// Spawn Ollama (if not already running) and poll until healthy (max 8 s).
/// Returns `true` on success, `false` on timeout or spawn failure.
pub async fn start_ollama(bin_path: &str) -> anyhow::Result<bool> {
    if is_ollama_running(OLLAMA_BASE_URL).await {
        return Ok(true);
    }

    let mut cmd = Command::new(bin_path);
    cmd.arg("serve");

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    let child = cmd.spawn()?;
    *child_lock().lock().unwrap() = Some(child);

    // Poll up to 8 s (16 × 500 ms)
    for _ in 0..16 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if is_ollama_running(OLLAMA_BASE_URL).await {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Kill the spawned Ollama child process (if we own it).
pub fn stop_ollama() {
    if let Ok(mut guard) = child_lock().lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Returns `"running"`, `"stopped"`, or `"error:<msg>"`.
pub fn get_status() -> String {
    // We can't do async here so we check the child handle as a proxy.
    // Real health-check callers should use `is_ollama_running`.
    match child_lock().lock() {
        Ok(guard) => {
            if guard.is_some() {
                "running".to_string()
            } else {
                "stopped".to_string()
            }
        }
        Err(e) => format!("error:{e}"),
    }
}

#[cfg(test)]
mod tests;

