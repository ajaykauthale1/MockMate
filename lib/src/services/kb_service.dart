import 'package:flutter/services.dart';
import '../bridge/bridge.dart' as bridge;

/// Loads all *.txt files from assets/kb/, concatenates them,
/// and pushes the result into the Rust AppState via FRB bridge.
Future<void> loadKnowledgeBaseAssets() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final keys = manifest
      .listAssets()
      .where((k) => k.startsWith('assets/kb/') && k.endsWith('.txt'));

  final buffer = StringBuffer();
  for (final key in keys) {
    final text = await rootBundle.loadString(key);
    buffer.writeln(text);
    buffer.writeln();
  }

  await bridge.loadKnowledgeBase(text: buffer.toString());
}
