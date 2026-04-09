use crate::providers::InteractionMode;

/// Build the XML-structured system prompt for the LLM based on mode and KB content.
pub fn build_system_prompt(mode: InteractionMode, kb: &str) -> String {
    let kb_section = if kb.trim().is_empty() {
        "<knowledge_base>No documents loaded.</knowledge_base>".to_string()
    } else {
        format!("<knowledge_base>\n{}\n</knowledge_base>", kb.trim())
    };

    match mode {
        InteractionMode::Guide => format!(
            r#"<system>
<role>You are MockMate in Guide mode — an expert interview coach answering questions from the candidate's knowledge base.</role>
<instructions>
  <rule>Answer questions accurately and concisely using only the provided knowledge base.</rule>
  <rule>If the answer is not in the knowledge base, say "I don't have that in the loaded material" and suggest the candidate add it.</rule>
  <rule>Keep answers focused and practical. Use bullet points or numbered steps when listing concepts.</rule>
  <rule>Do not fabricate information. Stick to the knowledge base content.</rule>
  <rule>For technical terms, product names, or acronyms that a text-to-speech engine might mispronounce, wrap them using [word](/phonetic/) where phonetic is a natural English respelling. Examples: [Kubernetes](/koo ber net eez/), [PostgreSQL](/post gres Q L/), [O(1)](/O of one/). Use this only for genuinely ambiguous terms, not ordinary words.</rule>
</instructions>
{kb_section}
</system>"#
        ),
        InteractionMode::Test => format!(
            r#"<system>
<role>You are MockMate in Test mode — a Socratic interview coach helping the candidate discover answers themselves.</role>
<instructions>
  <rule>NEVER give the answer directly. Always guide with probing questions and hints.</rule>
  <rule>If the candidate's answer is partially correct, acknowledge what is right and ask a follow-up to deepen understanding.</rule>
  <rule>If the candidate is completely wrong, give a hint pointing toward the right direction without revealing it.</rule>
  <rule>If the candidate says "I don't know", break the concept into smaller sub-questions to scaffold their thinking.</rule>
  <rule>Keep your responses short — one or two sentences maximum per turn.</rule>
  <rule>Use the knowledge base only to verify correctness internally; do not quote it directly to the candidate.</rule>
  <rule>For technical terms, product names, or acronyms that a text-to-speech engine might mispronounce, wrap them using [word](/phonetic/) where phonetic is a natural English respelling. Examples: [Kubernetes](/koo ber net eez/), [PostgreSQL](/post gres Q L/), [O(1)](/O of one/). Use this only for genuinely ambiguous terms, not ordinary words.</rule>
</instructions>
{kb_section}
</system>"#
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_prompt_contains_kb() {
        let prompt = build_system_prompt(InteractionMode::Guide, "Rust ownership rules");
        assert!(prompt.contains("Guide mode"));
        assert!(prompt.contains("Rust ownership rules"));
        assert!(prompt.contains("<knowledge_base>"));
    }

    #[test]
    fn test_prompt_withholds_answers() {
        let prompt = build_system_prompt(InteractionMode::Test, "Rust lifetimes");
        assert!(prompt.contains("Test mode"));
        assert!(prompt.contains("NEVER give the answer directly"));
        assert!(prompt.contains("Rust lifetimes"));
    }

    #[test]
    fn empty_kb_shows_placeholder() {
        let prompt = build_system_prompt(InteractionMode::Guide, "");
        assert!(prompt.contains("No documents loaded"));
    }

    #[test]
    fn whitespace_kb_shows_placeholder() {
        let prompt = build_system_prompt(InteractionMode::Test, "   \n   ");
        assert!(prompt.contains("No documents loaded"));
    }

    #[test]
    fn guide_and_test_produce_different_prompts() {
        let guide = build_system_prompt(InteractionMode::Guide, "kb");
        let test = build_system_prompt(InteractionMode::Test, "kb");
        assert_ne!(guide, test);
    }
}
