import '../models/execution_result.dart';
import '../models/interview_question.dart';
import '../models/runtime_info.dart';

class InterviewConductor {
  String buildInterviewerPrompt(InterviewQuestion q) => '''
You are a senior software engineer conducting a coding interview at a top tech company.

QUESTION YOU HAVE GIVEN THE CANDIDATE:
${q.title} (${q.difficulty.name})
${q.description}

EXPECTED SOLUTIONS (for your reference only — never share with the candidate):
${q.solutionNotes}

YOUR ROLE:
- Guide, never solve. Never write or dictate code.
- Hint levels:
    L1: nudge toward the right approach (e.g. "think about O(1) lookup")
    L2: name the data structure or algorithm
    L3: pseudocode outline only — never actual code
- Ask probing questions: time complexity, space complexity, edge cases, alternative approaches.
- If the candidate asks a clarifying question about the problem, answer it directly and concisely.
- Track communication quality: is the candidate thinking aloud, asking good questions, explaining their reasoning?
- Do not reveal test cases or expected outputs.
- Keep responses concise — this is a live interview, not a lecture.
''';

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

  String buildOpeningMessage(InterviewQuestion q) =>
      "Let's get started. Here's your question:\n\n"
      "**${q.title}** (${q.difficulty.name})\n\n"
      "${q.description}\n\n"
      "Take your time to read through it. Feel free to ask me any clarifying questions before you start coding.";
}
