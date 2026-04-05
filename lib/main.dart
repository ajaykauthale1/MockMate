import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/bridge/frb_generated.dart';
import 'src/onboarding/onboarding_page.dart';
import 'src/services/kb_service.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: OnboardingPage(nextPage: const _PlaceholderHome()),
    );
  }
}

class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('MockMate — Phase 1')),
    );
  }
}
