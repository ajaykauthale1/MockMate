import 'dart:io';
import '../models/runtime_info.dart';

class RuntimeDetector {
  static const _timeout = Duration(seconds: 5);

  Future<RuntimeInfo> detect(SupportedLanguage language) async {
    final result = await _probe(language);
    return result;
  }

  Future<Map<SupportedLanguage, RuntimeInfo>> detectAll() async {
    final results = await Future.wait(
      SupportedLanguage.values.map(detect),
    );
    return Map.fromIterables(SupportedLanguage.values, results);
  }

  Future<RuntimeInfo> _probe(SupportedLanguage language) async {
    final candidates = _versionCommands[language];
    if (candidates == null) {
      return RuntimeInfo(language: language, installed: false);
    }

    for (final cmd in candidates) {
      try {
        final result = await Process.run(
          cmd.$1,
          cmd.$2,
          runInShell: true,
        ).timeout(_timeout);

        if (result.exitCode == 0) {
          final raw = (result.stdout as String).trim();
          final version = _parseVersion(language, raw);
          final exe = await _resolveExecutable(cmd.$1);
          return RuntimeInfo(
            language: language,
            installed: true,
            version: version,
            executablePath: exe,
          );
        }
      } catch (_) {
        continue;
      }
    }

    return RuntimeInfo(language: language, installed: false);
  }

  String? _parseVersion(SupportedLanguage language, String raw) {
    // extract first version-like token from output
    final match = RegExp(r'\d+\.\d+[\.\d]*').firstMatch(raw);
    return match?.group(0);
  }

  Future<String?> _resolveExecutable(String cmd) async {
    try {
      final which = Platform.isWindows ? 'where' : 'which';
      final result = await Process.run(which, [cmd], runInShell: true)
          .timeout(_timeout);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('\n').first.trim();
      }
    } catch (_) {}
    return null;
  }

  // (executable, args) candidates per language, tried in order
  static const _versionCommands =
      <SupportedLanguage, List<(String, List<String>)>>{
    SupportedLanguage.python: [
      ('python3', ['--version']),
      ('python', ['--version']),
    ],
    SupportedLanguage.javascript: [
      ('node', ['--version']),
    ],
    SupportedLanguage.java: [
      ('java', ['-version']),
    ],
    SupportedLanguage.go: [
      ('go', ['version']),
    ],
    SupportedLanguage.cpp: [
      ('g++', ['--version']),
      ('clang++', ['--version']),
    ],
  };
}
