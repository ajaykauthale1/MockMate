use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_util::StreamExt;
use mockmate_core::providers::LlmProvider;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
const DEFAULT_MODEL: &str = "claude-haiku-4-5-20251001";
const DEFAULT_MAX_TOKENS: u32 = 1024;

/// Anthropic Claude LLM provider (streaming messages API).
pub struct AnthropicLlm {
    client: Client,
    api_key: String,
    model: String,
    max_tokens: u32,
}

impl AnthropicLlm {
    pub fn new(api_key: impl Into<String>, model: Option<String>) -> Self {
        Self {
            client: Client::new(),
            api_key: api_key.into(),
            model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
            max_tokens: DEFAULT_MAX_TOKENS,
        }
    }

    pub fn with_max_tokens(mut self, max_tokens: u32) -> Self {
        self.max_tokens = max_tokens;
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
            .post(API_URL)
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
            .post(API_URL)
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
}
