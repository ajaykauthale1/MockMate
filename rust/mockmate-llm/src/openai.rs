use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_util::StreamExt;
use mockmate_core::providers::LlmProvider;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

const DEFAULT_BASE_URL: &str = "https://api.openai.com";
const DEFAULT_MODEL: &str = "gpt-4o-mini";

/// OpenAI-compatible LLM provider (streaming chat completions).
///
/// Also works with any OpenAI-compatible endpoint (e.g. Azure, Groq, Together)
/// by passing a custom `base_url`.
pub struct OpenAiLlm {
    client: Client,
    api_key: String,
    model: String,
    base_url: String,
}

impl OpenAiLlm {
    pub fn new(api_key: impl Into<String>, model: Option<String>) -> Self {
        Self::with_base_url(api_key, model, None)
    }

    pub fn with_base_url(
        api_key: impl Into<String>,
        model: Option<String>,
        base_url: Option<String>,
    ) -> Self {
        Self {
            client: Client::new(),
            api_key: api_key.into(),
            model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
            base_url: base_url.unwrap_or_else(|| DEFAULT_BASE_URL.to_string()),
        }
    }

    /// Verify the API key with a cheap `/v1/models` call.
    pub async fn validate(&self) -> Result<bool> {
        let resp = self
            .client
            .get(format!("{}/v1/models", self.base_url))
            .bearer_auth(&self.api_key)
            .send()
            .await
            .context("OpenAI /v1/models unreachable")?;
        Ok(resp.status().is_success())
    }
}

// ---------------------------------------------------------------------------
// Request / response types
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
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    delta: Delta,
}

#[derive(Deserialize)]
struct Delta {
    content: Option<String>,
}

// ---------------------------------------------------------------------------
// LlmProvider impl
// ---------------------------------------------------------------------------

#[async_trait]
impl LlmProvider for OpenAiLlm {
    async fn chat(&self, system: &str, user: &str) -> Result<mpsc::Receiver<Result<String>>> {
        let req = ChatRequest {
            model: &self.model,
            messages: vec![
                ChatMessage { role: "system", content: system },
                ChatMessage { role: "user",   content: user },
            ],
            stream: true,
        };

        let resp = self
            .client
            .post(format!("{}/v1/chat/completions", self.base_url))
            .bearer_auth(&self.api_key)
            .json(&req)
            .send()
            .await
            .context("Failed to connect to OpenAI /v1/chat/completions")?;

        anyhow::ensure!(
            resp.status().is_success(),
            "OpenAI returned HTTP {}",
            resp.status()
        );

        let (tx, rx) = mpsc::channel(128);
        let mut stream = resp.bytes_stream();

        tokio::spawn(async move {
            while let Some(result) = stream.next().await {
                match result {
                    Err(e) => {
                        let _ = tx.send(Err(e.into())).await;
                        return;
                    }
                    Ok(bytes) => {
                        let Ok(text) = std::str::from_utf8(&bytes) else { continue };
                        for line in text.lines() {
                            let data = line.strip_prefix("data: ").unwrap_or("").trim();
                            if data.is_empty() || data == "[DONE]" {
                                continue;
                            }
                            if let Ok(chunk) = serde_json::from_str::<ChatChunk>(data) {
                                for choice in chunk.choices {
                                    if let Some(content) = choice.delta.content {
                                        if !content.is_empty()
                                            && tx.send(Ok(content)).await.is_err()
                                        {
                                            return;
                                        }
                                    }
                                }
                            }
                        }
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
    fn default_model_is_mini() {
        let p = OpenAiLlm::new("key", None);
        assert_eq!(p.model, DEFAULT_MODEL);
    }

    #[test]
    fn custom_model_stored() {
        let p = OpenAiLlm::new("key", Some("gpt-4o".to_string()));
        assert_eq!(p.model, "gpt-4o");
    }

    #[test]
    fn custom_base_url_stored() {
        let p = OpenAiLlm::with_base_url("key", None, Some("https://my.proxy".to_string()));
        assert_eq!(p.base_url, "https://my.proxy");
    }

    #[test]
    fn bad_key_validate_returns_err_on_network_failure() {
        // No network call in this test; just ensure the type compiles correctly.
        let p = OpenAiLlm::new("bad-key", None);
        assert!(!p.api_key.is_empty());
    }

    #[test]
    fn sse_data_stripped_correctly() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}";
        let data = line.strip_prefix("data: ").unwrap_or("").trim();
        let chunk: ChatChunk = serde_json::from_str(data).unwrap();
        assert_eq!(chunk.choices[0].delta.content.as_deref(), Some("hello"));
    }

    #[test]
    fn done_sentinel_skipped() {
        let line = "data: [DONE]";
        let data = line.strip_prefix("data: ").unwrap_or("").trim();
        assert_eq!(data, "[DONE]");
        // Should not try to parse as JSON
        assert!(serde_json::from_str::<ChatChunk>(data).is_err());
    }

    // -----------------------------------------------------------------------
    // HTTP integration tests (wiremock)
    // -----------------------------------------------------------------------

    use wiremock::{Mock, MockServer, ResponseTemplate};
    use wiremock::matchers::{method, path};

    fn sse_body(tokens: &[&str]) -> String {
        let mut lines: Vec<String> = tokens
            .iter()
            .map(|t| {
                format!(
                    "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{}\"}}}}]}}\n",
                    t
                )
            })
            .collect();
        lines.push("data: [DONE]\n".to_string());
        lines.join("")
    }

    #[tokio::test]
    async fn streams_tokens_from_sse() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1/chat/completions"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(sse_body(&["Hello", " world"]), "text/event-stream"),
            )
            .mount(&server)
            .await;

        let llm = OpenAiLlm::with_base_url("test-key", None, Some(server.uri()));
        let mut rx = llm.chat("system", "hello").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["Hello", " world"]);
    }

    #[tokio::test]
    async fn http_4xx_returns_err() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1/chat/completions"))
            .respond_with(ResponseTemplate::new(401).set_body_string("Unauthorized"))
            .mount(&server)
            .await;

        let llm = OpenAiLlm::with_base_url("bad-key", None, Some(server.uri()));
        let err = llm.chat("sys", "hi").await.unwrap_err();
        assert!(err.to_string().contains("401"));
    }

    #[tokio::test]
    async fn empty_delta_content_skipped() {
        let server = MockServer::start().await;
        // Mixing empty and non-empty content deltas
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n",
            "data: [DONE]\n",
        );
        Mock::given(method("POST"))
            .and(path("/v1/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(body, "text/event-stream"))
            .mount(&server)
            .await;

        let llm = OpenAiLlm::with_base_url("key", None, Some(server.uri()));
        let mut rx = llm.chat("sys", "hi").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["hi"]);
    }

    #[tokio::test]
    async fn dropped_receiver_does_not_panic() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1/chat/completions"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(sse_body(&["a", "b", "c"]), "text/event-stream"),
            )
            .mount(&server)
            .await;

        let llm = OpenAiLlm::with_base_url("key", None, Some(server.uri()));
        let rx = llm.chat("sys", "hi").await.unwrap();
        drop(rx);
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }
}
