/// Integration tests for the Ollama sidecar lifecycle.
/// Run with: cargo test -p mockmate-sidecar -- --test-threads=1
#[cfg(test)]
mod sidecar_integration {
    use crate::{get_status, is_ollama_running, stop_ollama};

    #[test]
    fn get_status_returns_stopped_initially() {
        // Fresh process — no child spawned yet.
        let s = get_status();
        assert_eq!(s, "stopped", "expected 'stopped' before any spawn");
    }

    #[test]
    fn stop_ollama_is_idempotent() {
        // Calling stop when nothing is running must not panic.
        stop_ollama();
        stop_ollama();
    }

    #[tokio::test]
    async fn is_ollama_running_returns_false_on_unreachable_port() {
        // Assumes port 11435 is unused in CI.
        let result = is_ollama_running("http://127.0.0.1:11435").await;
        assert!(!result, "nothing should be listening on 11435");
    }

    /// Smoke test: start_ollama with a bad path must not panic, just return false.
    #[tokio::test]
    async fn start_ollama_bad_path_returns_false() {
        let result = crate::start_ollama("/nonexistent/ollama").await;
        // spawn will fail → Ok(false) or Err → unwrap_or(false)
        assert!(!result.unwrap_or(false));
    }
}
