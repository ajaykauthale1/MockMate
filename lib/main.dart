import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/bridge/bridge.dart' as bridge;
import 'src/bridge/frb_generated.dart';
import 'src/home_screen.dart';
import 'src/onboarding/onboarding_page.dart';
import 'src/services/config_service.dart';
import 'src/services/kb_service.dart';
import 'src/theme/ske_theme.dart';

late final bool _onboardingDone;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(forceSameCodegenVersion: false);
  await loadKnowledgeBaseAssets();
  await _initTts();
  _onboardingDone = await ConfigService.hasConfig();
  runApp(ProviderScope(child: MockMateApp(onboardingDone: _onboardingDone)));
}

/// Load saved config and initialise Kokoro TTS if all three paths exist on disk.
///
/// In debug builds, if the config paths are missing or stale (app uninstalled),
/// falls back to the `resources/` directory beside the project root so that
/// `flutter run` works without reinstalling.
Future<void> _initTts() async {
  var cfg = await ConfigService.load();

  String model  = cfg.kokoroModelPath;
  String style  = cfg.kokoroStylePath;
  String espeak = cfg.espeakBinPath;

  // Debug fallback: if any path is missing, try resources/ next to the project.
  if (kDebugMode) {
    final res = _debugResourcesDir();
    if (res != null) {
      if (model.isEmpty  || !File(model).existsSync())  model  = '$res/kokoro/kokoro-v1.0.onnx';
      if (style.isEmpty  || !File(style).existsSync())  style  = '$res/kokoro/af_heart.bin';
      if (espeak.isEmpty || !File(espeak).existsSync()) espeak = '$res/espeak-ng/espeak-ng.exe';
    }
  }

  debugPrint('[TTS] model  = "$model"');
  debugPrint('[TTS] style  = "$style"');
  debugPrint('[TTS] espeak = "$espeak"');

  if (model.isEmpty || style.isEmpty || espeak.isEmpty) {
    debugPrint('[TTS] paths not configured — TTS disabled');
    return;
  }

  if (!File(model).existsSync() || !File(style).existsSync() || !File(espeak).existsSync()) {
    debugPrint('[TTS] one or more files missing — TTS disabled');
    return;
  }

  final ok = await bridge.initKokoroTts(
    modelPath: model,
    stylePath: style,
    espeakBin: espeak,
  );
  debugPrint('[TTS] initKokoroTts → $ok');
}

/// In debug mode, resolve the `resources/` directory from the working directory
/// (which is the project root when using `flutter run`).
String? _debugResourcesDir() {
  final res = Directory('${Directory.current.path}/resources');
  return res.existsSync() ? res.path : null;
}

class MockMateApp extends StatelessWidget {
  final bool onboardingDone;
  const MockMateApp({super.key, required this.onboardingDone});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MockMate',
      theme: skeuomorphicTheme(),
      home: onboardingDone
          ? const HomeScreen()
          : const OnboardingPage(nextPage: HomeScreen()),
    );
  }
}
