use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_util::StreamExt;
use mockmate_core::providers::LlmProvider;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

const DEFAULT_API_URL: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
const DEFAULT_MODEL: &str = "claude-haiku-4-5-20251001";
const DEFAULT_MAX_TOKENS: u32 = 1024;

/// Anthropic Claude LLM provider (streaming messages API).
pub struct AnthropicLlm {
    client: Client,
    api_key: String,
    model: String,
    max_tokens: u32,
    base_url: String,
}

impl AnthropicLlm {
    pub fn new(api_key: impl Into<String>, model: Option<String>) -> Self {
        Self {
            client: Client::new(),
            api_key: api_key.into(),
            model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
            max_tokens: DEFAULT_MAX_TOKENS,
            base_url: DEFAULT_API_URL.to_string(),
        }
    }

    pub fn with_max_tokens(mut self, max_tokens: u32) -> Self {
        self.max_tokens = max_tokens;
        self
    }

    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    /// Verify the API key with a minimal non-streaming request.
    pub async fn validate(&self) -> Result<bool> {
        #[derive(Serialize)]
        struct Ping<'a> {
            model: &'a str,
            max_tokens: u32,
            messages: Vec<Msg>,
        }
        #[derive(Serialize)]
        struct Msg { role: String, content: String }

        let resp = self
            .client
            .post(&self.base_url)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .json(&Ping {
                model: &self.model,
                max_tokens: 1,
                messages: vec![Msg { role: "user".into(), content: "ping".into() }],
            })
            .send()
            .await
            .context("Anthropic API unreachable")?;

        // 200 = valid key; 401 = invalid key; other = network/server issue
        Ok(resp.status().as_u16() != 401)
    }
}

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    max_tokens: u32,
    system: &'a str,
    messages: Vec<ChatMessage<'a>>,
    stream: bool,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

/// Anthropic SSE delta event data field.
#[derive(Deserialize)]
struct SseDelta {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
}

/// Wrapper for `content_block_delta` events.
#[derive(Deserialize)]
struct ContentBlockDelta {
    delta: SseDelta,
}

// ---------------------------------------------------------------------------
// LlmProvider impl
// ---------------------------------------------------------------------------

#[async_trait]
impl LlmProvider for AnthropicLlm {
    async fn chat(&self, system: &str, user: &str) -> Result<mpsc::Receiver<Result<String>>> {
        let req = ChatRequest {
            model: &self.model,
            max_tokens: self.max_tokens,
            system,
            messages: vec![ChatMessage { role: "user", content: user }],
            stream: true,
        };

        let resp = self
            .client
            .post(&self.base_url)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .json(&req)
            .send()
            .await
            .context("Failed to connect to Anthropic /v1/messages")?;

        anyhow::ensure!(
            resp.status().is_success(),
            "Anthropic returned HTTP {}",
            resp.status()
        );

        let (tx, rx) = mpsc::channel(128);
        let mut stream = resp.bytes_stream();

        tokio::spawn(async move {
            // SSE events arrive as pairs of lines:
            //   event: <event_type>
            //   data:  <json>
            // We only care about `content_block_delta` events with type `text_delta`.
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
                            if data.is_empty() {
                                continue;
                            }
                            if let Ok(ev) = serde_json::from_str::<ContentBlockDelta>(data) {
                                if ev.delta.kind == "text_delta" {
                                    if let Some(text) = ev.delta.text {
                                        if !text.is_empty()
                                            && tx.send(Ok(text)).await.is_err()
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
    fn default_model_is_haiku() {
        let p = AnthropicLlm::new("key", None);
        assert_eq!(p.model, DEFAULT_MODEL);
    }

    #[test]
    fn custom_model_stored() {
        let p = AnthropicLlm::new("key", Some("claude-opus-4-6".to_string()));
        assert_eq!(p.model, "claude-opus-4-6");
    }

    #[test]
    fn max_tokens_builder() {
        let p = AnthropicLlm::new("key", None).with_max_tokens(2048);
        assert_eq!(p.max_tokens, 2048);
    }

    #[test]
    fn text_delta_parsed() {
        let json = r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#;
        let ev: ContentBlockDelta = serde_json::from_str(json).unwrap();
        assert_eq!(ev.delta.kind, "text_delta");
        assert_eq!(ev.delta.text.as_deref(), Some("Hello"));
    }

    #[test]
    fn non_text_delta_ignored() {
        let json = r#"{"type":"content_block_start","index":0,"delta":{"type":"tool_use_delta","text":null}}"#;
        let ev: ContentBlockDelta = serde_json::from_str(json).unwrap();
        assert_ne!(ev.delta.kind, "text_delta");
        assert!(ev.delta.text.is_none());
    }

    #[test]
    fn message_stop_ignored() {
        let json = r#"{"type":"message_stop"}"#;
        // Should not parse as ContentBlockDelta
        let result = serde_json::from_str::<ContentBlockDelta>(json);
        // It may or may not parse; but the `kind` won't be `text_delta`
        if let Ok(ev) = result {
            assert_ne!(ev.delta.kind, "text_delta");
        }
    }

    // -----------------------------------------------------------------------
    // HTTP integration tests (wiremock)
    // -----------------------------------------------------------------------

    use wiremock::{Mock, MockServer, ResponseTemplate};
    use wiremock::matchers::method;

    fn sse_text_delta(text: &str) -> String {
        format!(
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{}\"}}}}\n",
            text
        )
    }

    fn anthropic_sse_body(tokens: &[&str]) -> String {
        let mut body = String::new();
        body.push_str("data: {\"type\":\"message_start\"}\n\n");
        for t in tokens {
            body.push_str(&sse_text_delta(t));
            body.push('\n');
        }
        body.push_str("data: {\"type\":\"message_stop\"}\n\n");
        body
    }

    #[tokio::test]
    async fn streams_tokens_from_anthropic_sse() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(anthropic_sse_body(&["Hello", " world"]), "text/event-stream"),
            )
            .mount(&server)
            .await;

        let llm = AnthropicLlm::new("test-key", None).with_base_url(server.uri());
        let mut rx = llm.chat("system", "hello").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["Hello", " world"]);
    }

    #[tokio::test]
    async fn non_text_delta_events_ignored() {
        let server = MockServer::start().await;
        // Mix in a tool_use_delta — must not appear in output
        let body = concat!(
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"tool_use_delta\",\"text\":null}}\n",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n",
            "data: {\"type\":\"message_stop\"}\n",
        );
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_raw(body, "text/event-stream"))
            .mount(&server)
            .await;

        let llm = AnthropicLlm::new("key", None).with_base_url(server.uri());
        let mut rx = llm.chat("sys", "hi").await.unwrap();
        let mut tokens = Vec::new();
        while let Some(t) = rx.recv().await {
            tokens.push(t.unwrap());
        }
        assert_eq!(tokens, vec!["hi"]);
    }

    #[tokio::test]
    async fn http_4xx_returns_err() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(401).set_body_string("Unauthorized"))
            .mount(&server)
            .await;

        let llm = AnthropicLlm::new("bad-key", None).with_base_url(server.uri());
        let err = llm.chat("sys", "hi").await.unwrap_err();
        assert!(err.to_string().contains("401"));
    }

    #[tokio::test]
    async fn dropped_receiver_does_not_panic() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_raw(anthropic_sse_body(&["a", "b", "c"]), "text/event-stream"),
            )
            .mount(&server)
            .await;

        let llm = AnthropicLlm::new("key", None).with_base_url(server.uri());
        let rx = llm.chat("sys", "hi").await.unwrap();
        drop(rx);
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }
}
