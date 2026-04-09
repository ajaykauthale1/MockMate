import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Download and silently install Ollama for the current platform.
class OllamaInstaller {
  static const _windowsUrl =
      'https://ollama.com/download/OllamaSetup.exe';
  static const _macUrl =
      'https://ollama.com/download/Ollama-darwin.zip';
  static const _linuxUrl =
      'https://ollama.com/install.sh';

  /// Stream download + install progress as [0.0 .. 1.0], then `done` or `error:<msg>`.
  static Stream<String> install() async* {
    if (Platform.isWindows) {
      yield* _installWindows();
    } else if (Platform.isMacOS) {
      yield* _installMac();
    } else {
      yield* _installLinux();
    }
  }

  static Stream<String> _installWindows() async* {
    final dir = await getTemporaryDirectory();
    final dest = File('${dir.path}/OllamaSetup.exe');

    yield* _download(_windowsUrl, dest);

    yield 'Installing…';
    final result = await Process.run(
      dest.path,
      ['/SILENT', '/NORESTART'],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      yield 'error:installer exited ${result.exitCode}';
      return;
    }
    yield 'done';
  }

  static Stream<String> _installMac() async* {
    final dir = await getTemporaryDirectory();
    final dest = File('${dir.path}/Ollama-darwin.zip');
    yield* _download(_macUrl, dest);

    yield 'Extracting…';
    final unzip = await Process.run('unzip', ['-o', dest.path, '-d', '/Applications']);
    if (unzip.exitCode != 0) {
      yield 'error:unzip failed';
      return;
    }
    yield 'done';
  }

  static Stream<String> _installLinux() async* {
    final dir = await getTemporaryDirectory();
    final dest = File('${dir.path}/ollama_install.sh');
    yield* _download(_linuxUrl, dest);

    yield 'Installing…';
    await Process.run('chmod', ['+x', dest.path]);
    final result = await Process.run('sh', [dest.path]);
    if (result.exitCode != 0) {
      yield 'error:install script exited ${result.exitCode}';
      return;
    }
    yield 'done';
  }

  /// Download [url] to [dest], yielding progress strings `"0.42"` etc.
  static Stream<String> _download(String url, File dest) async* {
    final req = http.Request('GET', Uri.parse(url));
    final response = await req.send();
    final total = response.contentLength ?? 0;
    int received = 0;
    final sink = dest.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        yield (received / total).toStringAsFixed(2);
      }
    }
    await sink.close();
  }

  /// Try to locate the Ollama binary on PATH or known install locations.
  static Future<String?> detectBinPath() async {
    // Check PATH first — most reliable across all platforms.
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['ollama'],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        final line = (result.stdout as String).trim().split('\n').first.trim();
        if (line.isNotEmpty && await File(line).exists()) return line;
      }
    } catch (_) {}

    // Fallback: known install locations.
    final List<String> candidates;
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final userProfile = Platform.environment['USERPROFILE'] ?? '';
      final programFiles = Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files';
      candidates = [
        if (localAppData.isNotEmpty) '$localAppData\\Programs\\Ollama\\ollama.exe',
        if (userProfile.isNotEmpty) '$userProfile\\AppData\\Local\\Programs\\Ollama\\ollama.exe',
        '$programFiles\\Ollama\\ollama.exe',
        r'C:\Program Files\Ollama\ollama.exe',
      ];
    } else if (Platform.isMacOS) {
      candidates = [
        '/usr/local/bin/ollama',
        '/opt/homebrew/bin/ollama',
        '${Platform.environment['HOME'] ?? ''}/bin/ollama',
      ];
    } else {
      candidates = [
        '/usr/bin/ollama',
        '/usr/local/bin/ollama',
        '${Platform.environment['HOME'] ?? ''}/.local/bin/ollama',
      ];
    }

    for (final path in candidates) {
      if (path.isNotEmpty && await File(path).exists()) return path;
    }
    return null;
  }
}
