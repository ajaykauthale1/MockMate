import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mockmate/src/audio/audio_provider.dart';
import 'package:mockmate/src/bridge/bridge.dart';
import 'package:mockmate/src/bridge/frb_generated.dart';
import 'package:mockmate/src/interview/interview_provider.dart';
import 'package:mockmate/src/interview/models/interview_question.dart';

// ── Tracking mock API ────────────────────────────────────────────────────────
// Single instance — RustLib.initMock can only be called once per process.

class _TrackingApi extends RustLibApi {
  // Configurable per-test outputs.
  String chatResult = 'ai response';
  Uint8List pcmResult = Uint8List(0);
  String visemesResult = '[]';

  // Call counters reset in setUp.
  int synthesiseCalls = 0;
  String? lastSynthesisedText;
  int playAudioCalls = 0;
  int extractVisemesCalls = 0;

  void reset() {
    chatResult = 'ai response';
    pcmResult = Uint8List(0);
    visemesResult = '[]';
    synthesiseCalls = 0;
    lastSynthesisedText = null;
    playAudioCalls = 0;
    extractVisemesCalls = 0;
  }

  @override
  Future<String> crateBridgeChat({required String userMessage}) async =>
      chatResult;

  @override
  Stream<String> crateBridgeChatStream({required String userMessage}) =>
      Stream.value(chatResult);

  @override
  Future<Uint8List> crateBridgeSynthesiseText({required String text}) async {
    synthesiseCalls++;
    lastSynthesisedText = text;
    return pcmResult;
  }

  @override
  Future<bool> crateBridgePlayAudio({required List<int> pcmBytes}) async {
    playAudioCalls++;
    return true;
  }

  @override
  Future<String> crateBridgeExtractVisemes(
      {required List<int> pcmBytes}) async {
    extractVisemesCalls++;
    return visemesResult;
  }

  @override
  Future<void> crateBridgeLoadKnowledgeBase({required String text}) async {}

  @override
  Future<void> crateBridgeSetInteractionMode({required bool isTest}) async {}

  // ── Unused stubs ─────────────────────────────────────────────────────────

  @override
  Future<bool> crateBridgeOllamaHealthCheck() async => false;
  @override
  Future<List<String>> crateBridgeOllamaPullModel() async => [];
  @override
  Future<bool> crateBridgeStartOllamaSidecar({required String binPath}) async =>
      false;
  @override
  Future<void> crateBridgeStopOllamaSidecar() async {}
  @override
  Future<String> crateBridgeGetSidecarStatus() async => 'stopped';
  @override
  Stream<AvatarState> crateBridgeAvatarStateStream() => const Stream.empty();
  @override
  Future<bool> crateBridgeInitAnthropicLlm(
          {required String apiKey, required String model}) async =>
      false;
  @override
  Future<bool> crateBridgeInitElevenlabsTts(
          {required String apiKey, required String voiceId}) async =>
      false;
  @override
  Future<bool> crateBridgeInitKokoroTts(
          {required String modelPath,
          required String stylePath,
          required String espeakBin}) async =>
      false;
  @override
  Future<bool> crateBridgeInitOpenaiLlm(
          {required String apiKey,
          required String model,
          required String baseUrl}) async =>
      false;
  @override
  Future<bool> crateBridgeInitPiperTts(
          {required String piperBin, required String modelPath}) async =>
      false;
  @override
  Future<bool> crateBridgeInitSileroVad({required String modelPath}) async =>
      false;
  @override
  Future<bool> crateBridgeInitWhisperStt(
          {required String whisperBin,
          required String modelPath}) async =>
      false;
  @override
  Future<String> crateBridgeProcessAudioTurn(
          {required List<int> pcmBytes}) async =>
      '{}';
  @override
  Future<String> crateBridgeTranscribeAudio(
          {required List<int> pcmBytes}) async =>
      '';
  @override
  Future<bool> crateBridgeValidateApiKey(
          {required String provider, required String apiKey}) async =>
      false;
  @override
  Future<void> crateBridgeStopAudio() async {}
  @override
  Future<bool> crateBridgeIsAudioPlaying() async => false;
  @override
  Stream<VoiceSetupEvent> crateBridgeEnsureVoiceAssets(
          {required String assetDir, required String espeakDir}) =>
      Stream.fromIterable([
        VoiceSetupEvent(
          step: 'done',
          bytesDone: BigInt.zero,
          bytesTotal: BigInt.zero,
          done: true,
          error: '',
        ),
      ]);
}

// ── Shared state ─────────────────────────────────────────────────────────────

final _api = _TrackingApi();

final _fakeQuestion = InterviewQuestion(
  id: 'test-q',
  title: 'Two Sum',
  difficulty: Difficulty.easy,
  tags: ['array'],
  description:
      'Given an array, return indices of two numbers that add to target.',
  examples: [QuestionExample(input: '[2,7,11,15], 9', output: '[0,1]')],
  constraints: ['2 <= nums.length <= 10^4'],
  starterCode: {'python': 'def twoSum(nums, target):\n    pass'},
  hiddenTests: [],
  solutionNotes: 'Use a hash map for O(n) solution.',
);

ProviderContainer _container() => ProviderContainer();

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  setUp(() => _api.reset());

  group('InterviewNotifier TTS — sendMessage', () {
    test('calls synthesiseText with AI response text', () async {
      _api.chatResult = 'Great question!';

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('Hello');

      expect(_api.synthesiseCalls, 1);
      expect(_api.lastSynthesisedText, 'Great question!');
    });

    test('calls extractVisemes after synthesise', () async {
      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('hint please');

      expect(_api.extractVisemesCalls, 1);
    });

    test('calls playAudio when PCM is non-empty', () async {
      _api.pcmResult = Uint8List.fromList([1, 2, 3, 4]);

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('help');

      // playAudio is fire-and-forget — flush microtask queue.
      await Future<void>.delayed(Duration.zero);
      expect(_api.playAudioCalls, 2);
    });

    test('does NOT call playAudio when PCM is empty', () async {
      _api.pcmResult = Uint8List(0);

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('hello');

      await Future<void>.delayed(Duration.zero);
      expect(_api.playAudioCalls, 0);
    });

    test('audioState returns to idle when no visemes', () async {
      _api.visemesResult = '[]';

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('hi');

      expect(c.read(audioStateProvider), AudioState.idle);
    });

    test('pendingVisemesProvider updated with viseme JSON', () async {
      _api.visemesResult =
          '[{"id":13,"timestamp_ms":0},{"id":0,"timestamp_ms":200}]';

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('explain');

      expect(c.read(pendingVisemesProvider), _api.visemesResult);
    });

    test('AI response text is appended to visible messages', () async {
      _api.chatResult = 'Think about O(1) lookup.';

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('any hints?');

      final msgs = c.read(interviewProvider).visibleMessages;
      expect(msgs.any((m) => m.text == 'Think about O(1) lookup.'), isTrue);
    });

    test('aiThinking is false after sendMessage completes', () async {
      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).sendMessage('test');

      expect(c.read(interviewProvider).aiThinking, isFalse);
    });
  });

  group('InterviewNotifier TTS — startSession', () {
    test('speaks the opening message', () async {
      _api.chatResult = 'Welcome! Here is your question.';

      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).startSession();

      expect(_api.synthesiseCalls, 1);
      expect(_api.lastSynthesisedText, 'Welcome! Here is your question.');
    });

    test('session state is active after startSession', () async {
      final c = _container();
      addTearDown(c.dispose);
      c.read(interviewProvider.notifier).selectQuestion(_fakeQuestion);

      await c.read(interviewProvider.notifier).startSession();

      expect(
        c.read(interviewProvider).sessionState,
        SessionState.active,
      );
    });
  });
}
