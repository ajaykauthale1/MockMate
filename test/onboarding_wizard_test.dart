import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mockmate/src/bridge/bridge.dart';
import 'package:mockmate/src/bridge/frb_generated.dart';
import 'package:mockmate/src/onboarding/model_catalog.dart';
import 'package:mockmate/src/onboarding/onboarding_page.dart';

// ── Minimal mock RustLib API ──────────────────────────────────────────────

class _MockApi extends RustLibApi {
  @override
  Future<bool> crateBridgeOllamaHealthCheck() async => true;

  @override
  Future<List<String>> crateBridgeOllamaPullModel() async => ['success'];

  @override
  Future<bool> crateBridgeStartOllamaSidecar({required String binPath}) async =>
      true;

  @override
  Future<void> crateBridgeStopOllamaSidecar() async {}

  @override
  Future<String> crateBridgeGetSidecarStatus() async => 'stopped';

  // Unused stubs
  @override
  Stream<AvatarState> crateBridgeAvatarStateStream() => const Stream.empty();

  @override
  Future<String> crateBridgeChat({required String userMessage}) async => '';

  @override
  Future<String> crateBridgeExtractVisemes({required List<int> pcmBytes}) async =>
      '[]';

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
          {required String whisperBin, required String modelPath}) async =>
      false;

  @override
  Future<void> crateBridgeLoadKnowledgeBase({required String text}) async {}

  @override
  Future<String> crateBridgeProcessAudioTurn(
          {required List<int> pcmBytes}) async =>
      '{}';

  @override
  Future<void> crateBridgeSetInteractionMode({required bool isTest}) async {}

  @override
  Future<Uint8List> crateBridgeSynthesiseText({required String text}) async =>
      Uint8List(0);

  @override
  Future<String> crateBridgeTranscribeAudio(
          {required List<int> pcmBytes}) async =>
      '';

  @override
  Future<bool> crateBridgeValidateApiKey(
          {required String provider, required String apiKey}) async =>
      false;

  @override
  Future<bool> crateBridgePlayAudio({required List<int> pcmBytes}) async =>
      false;

  @override
  Future<void> crateBridgeStopAudio() async {}

  @override
  Future<bool> crateBridgeIsAudioPlaying() async => false;

  @override
  Stream<VoiceSetupEvent> crateBridgeEnsureVoiceAssets({
    required String assetDir,
    required String espeakDir,
  }) => Stream.fromIterable([
    VoiceSetupEvent(
      step: 'done',
      bytesDone: BigInt.zero,
      bytesTotal: BigInt.zero,
      done: true,
      error: '',
    ),
  ]);
}

// ── Tests ─────────────────────────────────────────────────────────────────

Widget _buildWizard() {
  return const ProviderScope(
    child: MaterialApp(
      home: OnboardingPage(nextPage: Scaffold(body: Text('Home'))),
    ),
  );
}

void main() {
  setUpAll(() => RustLib.initMock(api: _MockApi()));

  testWidgets('wizard shows LLM mode step first', (tester) async {
    await tester.pumpWidget(_buildWizard());
    expect(find.text('How do you want to run the AI?'), findsOneWidget);
    expect(find.text('Run Locally (Ollama)'), findsOneWidget);
    expect(find.text('Cloud API (BYOK)'), findsOneWidget);
  });

  testWidgets('model catalog lists all entries', (tester) async {
    expect(kModelCatalog.length, 6);
    expect(kModelCatalog.first.id, 'gemma3:4b');
    expect(kModelCatalog.every((m) => m.vramGb > 0), isTrue);
  });

  testWidgets('selecting cloud mode advances to voice setup step', (tester) async {
    await tester.pumpWidget(_buildWizard());
    await tester.tap(find.text('Cloud API (BYOK)'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump(); // triggers _startVoiceSetup → setState(_step = voiceSetup)
    await tester.pump(); // rebuild with new step
    // Voice setup screen should be visible (async download hasn't completed yet)
    expect(find.text('Setting up voice'), findsOneWidget);
  });
}
