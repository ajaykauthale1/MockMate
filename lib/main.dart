import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/bridge/bridge.dart' as bridge;
import 'src/bridge/frb_generated.dart';
import 'src/home_screen.dart';
import 'src/onboarding/onboarding_page.dart';
import 'src/services/config_service.dart';
import 'src/services/kb_service.dart';
import 'src/theme/ske_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(forceSameCodegenVersion: false);
  await loadKnowledgeBaseAssets();
  await _initTts();
  runApp(const ProviderScope(child: MockMateApp()));
}

/// Load saved config and initialise Kokoro TTS if all three paths exist on disk.
/// Runs silently — missing models are not fatal; the app works text-only.
Future<void> _initTts() async {
  final cfg = await ConfigService.load();
  if (cfg.kokoroModelPath.isEmpty ||
      cfg.kokoroStylePath.isEmpty ||
      cfg.espeakBinPath.isEmpty) {
    return;
  }

  if (!File(cfg.kokoroModelPath).existsSync() ||
      !File(cfg.kokoroStylePath).existsSync() ||
      !File(cfg.espeakBinPath).existsSync()) {
    return;
  }

  final ok = await bridge.initKokoroTts(
    modelPath: cfg.kokoroModelPath,
    stylePath: cfg.kokoroStylePath,
    espeakBin: cfg.espeakBinPath,
  );
  if (!ok) debugPrint('[MockMate] Kokoro TTS init failed');
}

class MockMateApp extends StatelessWidget {
  const MockMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MockMate',
      theme: skeuomorphicTheme(),
      home: const OnboardingPage(nextPage: HomeScreen()),
    );
  }
}
