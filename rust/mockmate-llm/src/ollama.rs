use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_util::StreamExt;
use mockmate_core::providers::LlmProvider;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tracing::debug;

const DEFAULT_BASE_URL: &str = "http://127.0.0.1:11434";
const DEFAULT_MODEL: &str = "qwen2.5:7b-instruct-q4_K_M";

pub struct OllamaLlm {
    client: Client,
    base_url: String,
    model: String,
}

impl OllamaLlm {
    pub fn new(base_url: Option<String>, model: Option<String>) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.unwrap_or_else(|| DEFAULT_BASE_URL.to_string()),
            model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        }
    }

    /// Check if Ollama is reachable and the model is available.
    pub async fn health_check(&self) -> Result<bool> {
        let resp = self
            .client
            .get(format!("{}/api/tags", self.base_url))
            .send()
            .await
            .context("Ollama not reachable")?;
        let body: serde_json::Value = resp.json().await?;
        let models = body["models"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["name"].as_str())
                    .any(|name| name.starts_with(&self.model))
            })
            .unwrap_or(false);
        Ok(models)
    }

    /// Pull the model from Ollama registry, streaming progress lines.
    /// Returns a receiver of status strings (e.g. "pulling manifest", "pull complete").
    pub async fn pull_model(&self) -> Result<mpsc::Receiver<Result<String>>> {
        #[derive(Serialize)]
        struct PullReq<'a> {
            name: &'a str,
            stream: bool,
        }
        let (tx, rx) = mpsc::channel(64);
        let resp = self
            .client
            .post(format!("{}/api/pull", self.base_url))
            .json(&PullReq { name: &self.model, stream: true })
            .send()
            .await
            .context("Failed to start model pull")?;
        let mut stream = resp.bytes_stream();
        tokio::spawn(async move {
            while let Some(chunk) = stream.next().await {
                match chunk {
                    Ok(bytes) => {
                        if let Ok(text) = std::str::from_utf8(&bytes) {
                            for line in text.lines().filter(|l| !l.is_empty()) {
                                if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
                                    let status = val["status"]
                                        .as_str()
                                        .unwrap_or(line)
                                        .to_string();
                                    if tx.send(Ok(status)).await.is_err() {
                                        return;
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e.into())).await;
                        return;
                    }
                }
            }
        });
        Ok(rx)
    }
}

// ---------------------------------------------------------------------------
// Ollama /api/chat types
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    stream: bool,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize)]
struct ChatChunk {
    message: Option<ChunkMessage>,
    done: bool,
}

#[derive(Deserialize)]
struct ChunkMessage {
    content: String,
}

// ---------------------------------------------------------------------------
// LlmProvider impl
// ---------------------------------------------------------------------------

#[async_trait]
impl LlmProvider for OllamaLlm {
    async fn chat(&self, system: &str, user: &str) -> Result<mpsc::Receiver<Result<String>>> {
        let req = ChatRequest {
            model: &self.model,
            messages: vec![
                ChatMessage { role: "system", content: system },
                ChatMessage { role: "user", content: user },
            ],
            stream: true,
        };

        let resp = self
            .client
            .post(format!("{}/api/chat", self.base_url))
            .json(&req)
            .send()
            .await
            .context("Failed to connect to Ollama /api/chat")?;

        let (tx, rx) = mpsc::channel(128);
        let mut stream = resp.bytes_stream();

        tokio::spawn(async move {
            while let Some(chunk) = stream.next().await {
                match chunk {
                    Ok(bytes) => {
                        if let Ok(text) = std::str::from_utf8(&bytes) {
                            for line in text.lines().filter(|l| !l.is_empty()) {
                                match serde_json::from_str::<ChatChunk>(line) {
                                    Ok(c) => {
                                        if let Some(msg) = c.message {
                                            if !msg.content.is_empty() {
                                                debug!(token = %msg.content, "llm chunk");
                                                if tx.send(Ok(msg.content)).await.is_err() {
                                                    return;
                                                }
                                            }
                                        }
                                        if c.done {
                                            return;
                                        }
                                    }
                                    Err(e) => {
                                        let _ = tx.send(Err(e.into())).await;
                                        return;
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e.into())).await;
                        return;
                    }
                }
            }
        });

        Ok(rx)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_construction() {
        let llm = OllamaLlm::new(None, None);
        assert_eq!(llm.base_url, DEFAULT_BASE_URL);
        assert_eq!(llm.model, DEFAULT_MODEL);
    }

    #[test]
    fn custom_construction() {
        let llm = OllamaLlm::new(
            Some("http://localhost:9999".into()),
            Some("llama3".into()),
        );
        assert_eq!(llm.base_url, "http://localhost:9999");
        assert_eq!(llm.model, "llama3");
    }

    // -----------------------------------------------------------------------
    // HTTP integration tests (wiremock)
    // -----------------------------------------------------------------------

    use wiremock::{Mock, MockServer, ResponseTemplate};
    use wiremock::matchers::{method, path};

    /// Build a newline-delimited Ollama chat response with given tokens.
    /// The last entry has `"done":true` and empty content.
    fn ndjson_response(tokens: &[&str]) -> String {
        let mut lines: Vec<String> = tokens
            .iter()
            .map(|t| {
                format!(
                    r#"{{"message":{{"role":"assistant","content":"{}"}},"done":false}}"#,
                    t
                )
            })
            .collect();
        lines.push(r#"{"done":true}"#.to_string());
        lines.join("\n")
    }

    #[tokio::test]
    async fn streams_tokens_from_ndjson() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(ndjson_response(&["Hello", " world"]), "application/x-ndjson"),
            )
            .mount(&server)
            .await;

        let llm = OllamaLlm::new(Some(server.uri()), None);
        let mut rx = llm.chat("system", "hello").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["Hello", " world"]);
    }

    #[tokio::test]
    async fn done_true_terminates_stream() {
        let server = MockServer::start().await;
        let body = r#"{"message":{"role":"assistant","content":"only"},"done":true}"#;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(body, "application/json"))
            .mount(&server)
            .await;

        let llm = OllamaLlm::new(Some(server.uri()), None);
        let mut rx = llm.chat("sys", "hi").await.unwrap();
        let first = rx.recv().await.unwrap().unwrap();
        assert_eq!(first, "only");
        // Stream must terminate — no more tokens
        assert!(rx.recv().await.is_none());
    }

    #[tokio::test]
    async fn empty_content_chunks_skipped() {
        let server = MockServer::start().await;
        // Chunk with empty content should not be emitted
        let body = ndjson_response(&["", "real", ""]);
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(body, "application/json"))
            .mount(&server)
            .await;

        let llm = OllamaLlm::new(Some(server.uri()), None);
        let mut rx = llm.chat("sys", "hi").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["real"]);
    }

    #[tokio::test]
    async fn dropped_receiver_does_not_panic() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(ndjson_response(&["a", "b", "c"]), "application/json"),
            )
            .mount(&server)
            .await;

        let llm = OllamaLlm::new(Some(server.uri()), None);
        let rx = llm.chat("sys", "hi").await.unwrap();
        drop(rx);
        // Give the spawned task time to hit the closed channel without panicking
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }
}
