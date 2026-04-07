import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/bridge.dart' as bridge;
import '../chat/chat_provider.dart';
import '../services/kb_service.dart';
import 'models/evaluation_report.dart';
import 'models/execution_result.dart';
import 'models/interview_question.dart';
import 'models/runtime_info.dart';
import 'services/code_executor.dart';
import 'services/interview_conductor.dart';
import 'services/runtime_detector.dart';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

enum SessionState { notStarted, active, submitting, evaluating, complete }

// ---------------------------------------------------------------------------
// Interview message (hidden system messages not shown in UI)
// ---------------------------------------------------------------------------

class InterviewMessage {
  final MessageRole role;
  final String text;
  final bool hidden;

  const InterviewMessage({
    required this.role,
    required this.text,
    this.hidden = false,
  });
}

// ---------------------------------------------------------------------------
// Interview state
// ---------------------------------------------------------------------------

class InterviewState {
  final List<InterviewQuestion> questions;
  final InterviewQuestion? question;
  final SupportedLanguage language;
  final String code;
  final SessionState sessionState;
  final List<InterviewMessage> messages;
  final List<TestCaseResult>? testResults;
  final EvaluationReport? report;
  final Map<SupportedLanguage, RuntimeInfo> runtimes;
  final Duration totalDuration;
  final Duration elapsed;
  final bool aiThinking;

  const InterviewState({
    this.questions = const [],
    this.question,
    this.language = SupportedLanguage.python,
    this.code = '',
    this.sessionState = SessionState.notStarted,
    this.messages = const [],
    this.testResults,
    this.report,
    this.runtimes = const {},
    this.totalDuration = const Duration(minutes: 30),
    this.elapsed = Duration.zero,
    this.aiThinking = false,
  });

  List<InterviewMessage> get visibleMessages =>
      messages.where((m) => !m.hidden).toList();

  bool get timerExpired => elapsed >= totalDuration;

  Duration get remaining {
    final r = totalDuration - elapsed;
    return r.isNegative ? Duration.zero : r;
  }

  InterviewState copyWith({
    List<InterviewQuestion>? questions,
    InterviewQuestion? question,
    SupportedLanguage? language,
    String? code,
    SessionState? sessionState,
    List<InterviewMessage>? messages,
    List<TestCaseResult>? testResults,
    EvaluationReport? report,
    Map<SupportedLanguage, RuntimeInfo>? runtimes,
    Duration? totalDuration,
    Duration? elapsed,
    bool? aiThinking,
  }) =>
      InterviewState(
        questions: questions ?? this.questions,
        question: question ?? this.question,
        language: language ?? this.language,
        code: code ?? this.code,
        sessionState: sessionState ?? this.sessionState,
        messages: messages ?? this.messages,
        testResults: testResults ?? this.testResults,
        report: report ?? this.report,
        runtimes: runtimes ?? this.runtimes,
        totalDuration: totalDuration ?? this.totalDuration,
        elapsed: elapsed ?? this.elapsed,
        aiThinking: aiThinking ?? this.aiThinking,
      );
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class InterviewNotifier extends Notifier<InterviewState> {
  final _conductor = InterviewConductor();
  final _executor = CodeExecutor();
  final _detector = RuntimeDetector();
  Timer? _ticker;

  @override
  InterviewState build() {
    ref.onDispose(_cleanup);
    return const InterviewState();
  }

  Future<void> loadQuestions() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest
        .listAssets()
        .where((k) => k.startsWith('assets/questions/') && k.endsWith('.json'));

    final questions = <InterviewQuestion>[];
    for (final key in keys) {
      final raw = await rootBundle.loadString(key);
      questions.add(InterviewQuestion.fromJsonString(raw));
    }
    state = state.copyWith(questions: questions);
  }

  Future<void> detectRuntimes() async {
    final all = await _detector.detectAll();
    state = state.copyWith(runtimes: all);
  }

  void selectQuestion(InterviewQuestion q) {
    final starter = q.starterCodeFor(state.language.jsonKey) ?? '';
    state = state.copyWith(question: q, code: starter);
  }

  void setLanguage(SupportedLanguage lang) {
    final starter = state.question?.starterCodeFor(lang.jsonKey) ?? '';
    state = state.copyWith(language: lang, code: starter);
  }

  void setCode(String code) => state = state.copyWith(code: code);

  void setDuration(Duration d) => state = state.copyWith(totalDuration: d);

  Future<void> startSession() async {
    final q = state.question;
    if (q == null) return;

    // Load question as KB (no solution notes)
    final kbContent = _buildQuestionKb(q);
    await bridge.loadKnowledgeBase(text: kbContent);
    await bridge.setInteractionMode(isTest: false);

    state = state.copyWith(
      sessionState: SessionState.active,
      messages: [],
      testResults: null,
      report: null,
      elapsed: Duration.zero,
      aiThinking: true,
    );

    _startTicker();

    // Send hidden setup message → get opening from AI
    final setupMsg =
        '${_conductor.buildInterviewerPrompt(q)}\n\nNow greet the candidate and present the question. Be concise.';
    final opening = await bridge.chat(userMessage: setupMsg);

    state = state.copyWith(
      messages: [
        InterviewMessage(
            role: MessageRole.user, text: setupMsg, hidden: true),
        InterviewMessage(role: MessageRole.assistant, text: opening),
      ],
      aiThinking: false,
    );
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    state = state.copyWith(
      messages: [
        ...state.messages,
        InterviewMessage(role: MessageRole.user, text: text),
      ],
      aiThinking: true,
    );

    final response = await bridge.chat(userMessage: text);
    state = state.copyWith(
      messages: [
        ...state.messages,
        InterviewMessage(role: MessageRole.assistant, text: response),
      ],
      aiThinking: false,
    );
  }

  Future<void> submitCode() async {
    final q = state.question;
    if (q == null) return;

    _stopTicker();
    state = state.copyWith(sessionState: SessionState.submitting, aiThinking: true);

    final results = await _executor.runAllTests(
      code: state.code,
      language: state.language,
      tests: q.hiddenTests,
    );

    state = state.copyWith(
      testResults: results,
      sessionState: SessionState.evaluating,
    );

    final transcript = state.visibleMessages
        .map((m) => '${m.role.name.toUpperCase()}: ${m.text}')
        .toList();

    final evalPrompt = _conductor.buildEvaluationPrompt(
      q: q,
      code: state.code,
      language: state.language,
      results: results,
      conversationSummary: transcript,
    );

    final narrative = await bridge.chat(userMessage: evalPrompt);

    final report = EvaluationReport(
      testResults: results,
      aiNarrative: narrative,
      recommendation: _parseRecommendation(narrative),
      generatedAt: DateTime.now(),
    );

    state = state.copyWith(
      report: report,
      sessionState: SessionState.complete,
      aiThinking: false,
    );
  }

  Future<void> resetSession() async {
    _cleanup();
    // Restore user KB
    await loadKnowledgeBaseAssets();
    state = state.copyWith(
      sessionState: SessionState.notStarted,
      messages: [],
      testResults: null,
      report: null,
      elapsed: Duration.zero,
    );
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = state.elapsed + const Duration(seconds: 1);
      state = state.copyWith(elapsed: next);
      if (state.timerExpired && state.sessionState == SessionState.active) {
        submitCode();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _cleanup() {
    _ticker?.cancel();
    _ticker = null;
  }

  String _buildQuestionKb(InterviewQuestion q) {
    final examples = q.examples
        .map((e) => 'Input: ${e.input}\nOutput: ${e.output}'
            '${e.explanation != null ? '\nExplanation: ${e.explanation}' : ''}')
        .join('\n\n');

    return '''
CODING INTERVIEW QUESTION
=========================
Title: ${q.title}
Difficulty: ${q.difficulty.name}
Tags: ${q.tags.join(', ')}

Description:
${q.description}

Examples:
$examples

Constraints:
${q.constraints.join('\n')}
''';
  }

  Recommendation? _parseRecommendation(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('strong hire')) return Recommendation.strongHire;
    if (lower.contains('strong no hire')) return Recommendation.strongNoHire;
    if (lower.contains('no hire')) return Recommendation.noHire;
    if (lower.contains('hire')) return Recommendation.hire;
    return null;
  }
}

final interviewProvider =
    NotifierProvider<InterviewNotifier, InterviewState>(InterviewNotifier.new);
