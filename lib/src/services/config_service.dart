import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class AppConfig {
  final String llmMode; // "local" | "openai" | "anthropic"
  final String ollamaBinPath;
  final String ollamaModel;
  final String whisperBinPath;
  final String whisperModelPath;
  // Kokoro TTS paths (active TTS provider).
  final String kokoroModelPath;
  final String kokoroStylePath;
  final String espeakBinPath;
  // Legacy Piper fields — read-only for backward compat with old configs.
  final String piperBinPath;
  final String piperModelPath;

  const AppConfig({
    this.llmMode = 'local',
    this.ollamaBinPath = '',
    this.ollamaModel = 'gemma3:4b',
    this.whisperBinPath = '',
    this.whisperModelPath = '',
    this.kokoroModelPath = '',
    this.kokoroStylePath = '',
    this.espeakBinPath = '',
    this.piperBinPath = '',
    this.piperModelPath = '',
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        llmMode: j['llm_mode'] as String? ?? 'local',
        ollamaBinPath: j['ollama_bin_path'] as String? ?? '',
        ollamaModel: j['ollama_model'] as String? ?? 'gemma3:4b',
        whisperBinPath: j['whisper_bin_path'] as String? ?? '',
        whisperModelPath: j['whisper_model_path'] as String? ?? '',
        kokoroModelPath: j['kokoro_model_path'] as String? ?? '',
        kokoroStylePath: j['kokoro_style_path'] as String? ?? '',
        espeakBinPath: j['espeak_bin_path'] as String? ?? '',
        piperBinPath: j['piper_bin_path'] as String? ?? '',
        piperModelPath: j['piper_model_path'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'llm_mode': llmMode,
        'ollama_bin_path': ollamaBinPath,
        'ollama_model': ollamaModel,
        'whisper_bin_path': whisperBinPath,
        'whisper_model_path': whisperModelPath,
        'kokoro_model_path': kokoroModelPath,
        'kokoro_style_path': kokoroStylePath,
        'espeak_bin_path': espeakBinPath,
        'piper_bin_path': piperBinPath,
        'piper_model_path': piperModelPath,
      };

  AppConfig copyWith({
    String? llmMode,
    String? ollamaBinPath,
    String? ollamaModel,
    String? whisperBinPath,
    String? whisperModelPath,
    String? kokoroModelPath,
    String? kokoroStylePath,
    String? espeakBinPath,
    String? piperBinPath,
    String? piperModelPath,
  }) =>
      AppConfig(
        llmMode: llmMode ?? this.llmMode,
        ollamaBinPath: ollamaBinPath ?? this.ollamaBinPath,
        ollamaModel: ollamaModel ?? this.ollamaModel,
        whisperBinPath: whisperBinPath ?? this.whisperBinPath,
        whisperModelPath: whisperModelPath ?? this.whisperModelPath,
        kokoroModelPath: kokoroModelPath ?? this.kokoroModelPath,
        kokoroStylePath: kokoroStylePath ?? this.kokoroStylePath,
        espeakBinPath: espeakBinPath ?? this.espeakBinPath,
        piperBinPath: piperBinPath ?? this.piperBinPath,
        piperModelPath: piperModelPath ?? this.piperModelPath,
      );
}

class ConfigService {
  static const _fileName = 'mockmate_config.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<bool> hasConfig() async {
    try {
      final f = await _file();
      return f.existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<AppConfig> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const AppConfig();
      final raw = await f.readAsString();
      return AppConfig.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppConfig();
    }
  }

  static Future<void> save(AppConfig config) async {
    final f = await _file();
    await f.writeAsString(json.encode(config.toJson()));
  }
}
