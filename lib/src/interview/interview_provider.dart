import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_provider.dart';
import '../bridge/bridge.dart' as bridge;
import '../chat/chat_provider.dart';
import '../tts/tts_pipeline.dart';
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
  bool _cancelled = false;
  StreamController<String>? _synthQueue;
  StreamController<({String text, int msPerChar})>? _typingQueue;

  // Active Monitoring state
  DateTime _lastActionTime = DateTime.now();
  String _lastMonitoringCode = '';
  bool _monitoringInProgress = false;

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

  void setCode(String code) {
    state = state.copyWith(code: code);
    _lastActionTime = DateTime.now();
  }

  void setDuration(Duration d) => state = state.copyWith(totalDuration: d);

  Future<void> startSession() async {
    final q = state.question;
    if (q == null) return;

    await bridge.loadKnowledgeBase(text: _buildQuestionKb(q));
    await bridge.setInteractionMode(isTest: false);

    state = state.copyWith(
      sessionState: SessionState.active,
      messages: [],
      testResults: null,
      report: null,
      elapsed: Duration.zero,
      aiThinking: true,
    );

    _lastActionTime = DateTime.now();
    _lastMonitoringCode = state.code;
    _startTicker();

    final setupMsg = '''
${_conductor.buildInterviewerPrompt(q)}

Now, start the interview. Greet the candidate warmly and present the question in a conversational way. 

Follow this style exactly:
"Hi, I'll be your AI interviewer today. Please treat this like a standard interview: think out loud, ask clarifying questions, and talk me through your logic before writing code. Let's start with ${q.title}: ${q.description}. How would you approach solving this?"

Keep it simple and friendly for text-to-speech.
''';

    // Hidden user prompt + empty assistant placeholder; aiThinking stays true
    // until first audio chunk fires via onChunkReady in _processAiResponse.
    state = state.copyWith(
      messages: [
        InterviewMessage(role: MessageRole.user, text: setupMsg, hidden: true),
        InterviewMessage(role: MessageRole.assistant, text: ''),
      ],
    );

    final fullMessage = '''
CANDIDATE'S CURRENT CODE (${state.language.displayName}):
```
${state.code}
```

USER MESSAGE:
$setupMsg
''';

    await _processAiResponse(bridge.chatStream(userMessage: fullMessage));
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    state = state.copyWith(
      messages: [
        ...state.messages,
        InterviewMessage(role: MessageRole.user, text: text),
        InterviewMessage(role: MessageRole.assistant, text: ''),
      ],
      aiThinking: true,
    );

    _lastActionTime = DateTime.now();

    final fullMessage = '''
CANDIDATE'S CURRENT CODE (${state.language.displayName}):
```
${state.code}
```

USER MESSAGE:
$text
''';

    await _processAiResponse(bridge.chatStream(userMessage: fullMessage));
  }

  /// Periodically checks the candidate's progress and provides hints if they are stuck.
  Future<void> _performActiveMonitoring() async {
    if (_monitoringInProgress || _cancelled || state.aiThinking) return;
    if (state.sessionState != SessionState.active) return;

    final q = state.question;
    if (q == null) return;

    final code = state.code;
    final transcript = state.visibleMessages
        .map((m) => '${m.role.name.toUpperCase()}: ${m.text}')
        .toList();

    final monitorPrompt = _conductor.buildActiveMonitoringPrompt(
      q: q,
      code: code,
      conversationSummary: transcript,
    );

    _monitoringInProgress = true;
    try {
      final response = await bridge.chat(userMessage: monitorPrompt);
      if (response.trim().toUpperCase() == '[SILENT]' || _cancelled) {
        _lastMonitoringCode = code;
        _monitoringInProgress = false;
        return;
      }

      // AI decided to speak!
      state = state.copyWith(
        messages: [
          ...state.messages,
          InterviewMessage(role: MessageRole.assistant, text: ''),
        ],
        aiThinking: true,
      );

      _lastMonitoringCode = code;
      _lastActionTime = DateTime.now();
      
      // Feed the non-streamed response into the streaming processor for TTS and typing
      await _processAiResponse(Stream.value(response));
    } catch (e) {
      debugPrint('[Monitoring] Error: $e');
    } finally {
      _monitoringInProgress = false;
    }
  }

  /// Stream LLM tokens, pipe through TtsPipeline, and reveal text in sync
  /// with audio — text becomes visible only when the first audio chunk plays.
  Future<void> _processAiResponse(Stream<String> tokenStream) async {
    // Cancel any in-flight TTS/LLM/typing.
    _cancelled = true;
    await _synthQueue?.close();
    _typingQueue?.close();
    await bridge.stopAudio();
    _cancelled = false;

    ref.read(audioStateProvider.notifier).state = AudioState.speaking;

    // All raw tokens accumulated for the TTS-never-fired fallback.
    final tokenBuffer = StringBuffer();
    // Text already committed to screen (no cursor).
    final displayBuffer = StringBuffer();
    var lastQueued = ''; // last char enqueued to typing stream (separator tracking)
    bool firstChunkReady = false;

    void _updateDisplay({bool cursor = false}) {
      if (_cancelled) return;
      final msgs = state.messages.toList();
      if (msgs.isEmpty) return;
      final last = msgs.last;
      msgs[msgs.length - 1] = InterviewMessage(
        role: last.role,
        text: displayBuffer.toString() + (cursor ? '▋' : ''),
        hidden: last.hidden,
      );
      state = state.copyWith(messages: msgs, aiThinking: false);
    }

    // Serial typing consumer: drains jobs one character at a time, each job
    // at its own speed derived from the audio duration of that chunk.
    final typingQueue =
        StreamController<({String text, int msPerChar})>();
    _typingQueue = typingQueue;

    final typingDone = () async {
      await for (final job in typingQueue.stream) {
        for (int i = 0; i < job.text.length; i++) {
          if (_cancelled) return;
          displayBuffer.write(job.text[i]);
          _updateDisplay(cursor: true);
          await Future.delayed(Duration(milliseconds: job.msPerChar));
        }
      }
      if (!_cancelled) _updateDisplay(cursor: false);
    }();

    void revealChunk(String rawChunk, Duration audioDuration) {
      if (_cancelled) return;
      if (!firstChunkReady) firstChunkReady = true;
      if (rawChunk.isEmpty) return;

      // Separator space between chunks (skip after newline).
      final sep = (lastQueued.isNotEmpty && lastQueued != '\n' &&
              !rawChunk.startsWith('\n'))
          ? ' '
          : '';
      final toType = sep + rawChunk;
      lastQueued = rawChunk[rawChunk.length - 1];

      final msPerChar = audioDuration.inMilliseconds > 0
          ? (audioDuration.inMilliseconds / toType.length).round().clamp(10, 120)
          : 25;

      if (!typingQueue.isClosed) {
        typingQueue.add((text: toType, msPerChar: msPerChar));
      }
    }

    final synthQueue = StreamController<String>();
    _synthQueue = synthQueue;
    final synthDone = TtsPipeline.run(synthQueue.stream, onChunkReady: revealChunk);

    await for (final token in tokenStream) {
      if (_cancelled) break;
      if (token.startsWith('\nerror:')) break;
      tokenBuffer.write(token);
      if (!synthQueue.isClosed) synthQueue.add(token);
    }

    if (!synthQueue.isClosed) await synthQueue.close();
    await synthDone;

    // Close typing queue and wait for animation to finish.
    if (!typingQueue.isClosed) await typingQueue.close();
    await typingDone;

    // Fallback: TTS never fired (very short response / TTS disabled).
    if (!_cancelled && state.aiThinking) {
      final msgs = state.messages.toList();
      if (msgs.isNotEmpty) {
        final last = msgs.last;
        msgs[msgs.length - 1] = InterviewMessage(
          role: last.role,
          text: tokenBuffer.toString(),
          hidden: last.hidden,
        );
        state = state.copyWith(messages: msgs, aiThinking: false);
      }
    }

    if (!_cancelled) {
      ref.read(audioStateProvider.notifier).state = AudioState.idle;
    }
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

      if (state.sessionState == SessionState.active) {
        if (state.timerExpired) {
          submitCode();
        } else {
          final now = DateTime.now();
          final secondsSinceLastAction =
              now.difference(_lastActionTime).inSeconds;

          if (secondsSinceLastAction >= 30) {
            if (state.code != _lastMonitoringCode ||
                secondsSinceLastAction >= 60) {
              _performActiveMonitoring();
            }
          }
        }
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void stopTts() {
    _cancelled = true;
    _synthQueue?.close();
    bridge.stopAudio();
  }

  void _cleanup() {
    _ticker?.cancel();
    _ticker = null;
    stopTts();
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
