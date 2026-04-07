import 'interview_question.dart';
import 'runtime_info.dart';

class CodeSnapshot {
  final String code;
  final SupportedLanguage language;
  final DateTime takenAt;

  const CodeSnapshot({
    required this.code,
    required this.language,
    required this.takenAt,
  });
}

class InterviewSession {
  final InterviewQuestion question;
  final DateTime startedAt;
  final List<String> messages; // plain text transcript
  final List<CodeSnapshot> codeSnapshots;

  const InterviewSession({
    required this.question,
    required this.startedAt,
    this.messages = const [],
    this.codeSnapshots = const [],
  });

  InterviewSession copyWith({
    List<String>? messages,
    List<CodeSnapshot>? codeSnapshots,
  }) =>
      InterviewSession(
        question: question,
        startedAt: startedAt,
        messages: messages ?? this.messages,
        codeSnapshots: codeSnapshots ?? this.codeSnapshots,
      );
}
