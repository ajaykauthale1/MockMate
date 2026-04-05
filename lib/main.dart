import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/bridge/frb_generated.dart';
import 'src/chat/chat_page.dart';
import 'src/onboarding/onboarding_page.dart';
import 'src/services/kb_service.dart';
import 'src/theme/ske_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await loadKnowledgeBaseAssets();
  runApp(const ProviderScope(child: MockMateApp()));
}

class MockMateApp extends StatelessWidget {
  const MockMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MockMate',
      theme: skeuomorphicTheme(),
      home: const OnboardingPage(nextPage: ChatPage()),
    );
  }
}
