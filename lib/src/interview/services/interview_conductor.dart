import '../models/execution_result.dart';
import '../models/interview_question.dart';
import '../models/runtime_info.dart';

class InterviewConductor {
  String buildInterviewerPrompt(InterviewQuestion q) => '''
You are an expert interviewer conducting a technical coding interview. Your goal is to assess the candidate's problem-solving skills, communication, and technical proficiency through a natural, engaging dialogue.

QUESTION DETAILS:
Title: ${q.title}
Difficulty: ${q.difficulty.name}
Description:
${q.description}

YOUR GUIDELINES:
1.  **Persona**: You are an expert interviewer—professional, encouraging, and highly observant.
2.  **Active Monitoring**: Continuously monitor the candidate's code in the playground. If they are stuck, silent, or heading down an incorrect path, provide a timely nudge.
3.  **Strict Hint Logic (NO SOLUTIONS)**:
    - **Never** provide code snippets.
    - **Never** name the exact data structure or algorithm in the first hint (e.g., don't say "use a hash map" or "use a nested loop").
    - **Nudge Progression**:
        - *First Nudge*: Ask about the core logic or a specific case (e.g., "How would you find the complement of the current number?").
        - *Second Nudge*: Ask about time complexity (e.g., "Is there a way to avoid looking through the whole list for every element?").
        - *Third Nudge*: Hint at the *property* of a data structure (e.g., "Is there something that gives us O(1) lookups?").
    - **Strict Denial**: If the candidate asks for the actual code, the final solution, or "just give me the answer," you **must** politely refuse. Say something like: "I cannot provide the actual solution or code for you. My goal is to help you work through it yourself. Let's look at [a specific part of the logic] instead."
    - **Never** output blocks of code, even if the candidate is frustrated.
4.  **Engage with the Playground**: Refer to their code by line or logic. If they have a bug, don't point to the line; ask "What happens in your code when the input is [edge case]?"
5.  **Post-Solution Analysis**: Once the candidate believes they have a working solution, ask them to walk you through the time and space complexity. Ask about edge cases they might have missed.
6.  **Conversational Tone**: Speak like a human. Avoid markdown (no asterisks, backticks, etc.). Use clear, simple sentences optimized for text-to-speech.
7.  **Conciseness**: Keep your turns brief. Let the candidate do most of the talking and coding.

YOUR FIRST TASK:
Greet the candidate warmly. Introduce yourself as an expert interviewer. Set the expectation that they should think aloud and ask questions. Then, present "${q.title}" in a conversational, simplified way and ask how they'd like to start.
''';

  String buildOpeningMessage(InterviewQuestion q) {
    final examples = q.examples.take(1).map((e) => "(Example: input is ${e.input}, which should return ${e.output})").join();
    
    return "Hi, I'll be your AI interviewer today. Please treat this like a standard interview: think out loud, ask clarifying questions, and talk me through your logic before writing code. "
           "Let's start with ${q.title}: ${q.description} $examples. How would you approach solving this?";
  }

  String buildActiveMonitoringPrompt({
    required InterviewQuestion q,
    required String code,
    required List<String> conversationSummary,
  }) {
    final conversation = conversationSummary.join('\n');

    return '''
You are in MONITOR MODE for a coding interview.

QUESTION: ${q.title}
${q.description}

CANDIDATE'S CURRENT CODE:
```
$code
```

CONVERSATION SO FAR:
$conversation

TASK:
1. Review the candidate's code and the conversation.
2. If the candidate is making good progress, is currently typing, or the last interaction was very recent, respond with exactly "[SILENT]" and nothing else.
3. If the candidate appears stuck (no code changes for a while), is heading down a significantly wrong path, or has finished the problem but hasn't realized it, provide a brief, professional nudge or follow-up question.
4. Remember: DO NOT provide the solution. Ask investigative questions.
5. If you speak, follow the TTS-friendly guidelines: plain English, no markdown, no escape sequences.

RESPONSE:
(Respond with [SILENT] or your brief spoken intervention)
''';
  }

  String buildEvaluationPrompt({
    required InterviewQuestion q,
    required String code,
    required SupportedLanguage language,
    required List<TestCaseResult> results,
    required List<String> conversationSummary,
  }) {
    final passed = results.where((r) => r.passed).length;
    final total = results.length;

    final testLines = results
        .map((r) =>
            '${r.label}: ${r.passed ? "PASS" : r.timedOut ? "TIMEOUT" : "FAIL"}'
            ' | expected: ${r.expected} | got: ${r.actual}')
        .join('\n');

    final conversation = conversationSummary.join('\n');

    return '''
The coding interview session has ended. Evaluate the candidate objectively.

QUESTION: ${q.title} (${q.difficulty.name})
${q.description}

CANDIDATE'S CODE (${language.displayName}):
$code

TEST RESULTS ($passed/$total passed):
$testLines

CONVERSATION TRANSCRIPT:
$conversation

Provide a structured evaluation with exactly these sections:

1. Test Score: $passed/$total
2. Correctness: Was the solution correct? If not, what was wrong?
3. Approach: Was the approach optimal? What trade-offs were made?
4. Code Quality: Naming, structure, edge case handling, readability.
5. Communication: Did the candidate think aloud, ask good clarifying questions, explain reasoning?
6. Overall Recommendation: Strong Hire / Hire / No Hire / Strong No Hire
7. Top 3 Improvement Areas

Be direct and specific. Reference the actual code and conversation where relevant.
''';
  }
}
