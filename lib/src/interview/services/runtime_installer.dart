import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/runtime_info.dart';
import 'runtime_detector.dart';

class InstallProgress {
  final String message;
  final double? fraction; // null = indeterminate
  final bool done;
  final bool failed;
  final String? error;

  const InstallProgress._({
    required this.message,
    this.fraction,
    this.done = false,
    this.failed = false,
    this.error,
  });

  factory InstallProgress.step(String message, {double? fraction}) =>
      InstallProgress._(message: message, fraction: fraction);

  factory InstallProgress.complete(String message) =>
      InstallProgress._(message: message, done: true, fraction: 1.0);

  factory InstallProgress.failure(String message, String error) =>
      InstallProgress._(
          message: message, done: true, failed: true, error: error);
}

class RuntimeInstaller {
  final RuntimeDetector _detector;

  RuntimeInstaller({RuntimeDetector? detector})
      : _detector = detector ?? RuntimeDetector();

  Stream<InstallProgress> install(SupportedLanguage language) async* {
    final spec = _installSpec(language);
    if (spec == null) {
      yield InstallProgress.failure(
        'No installer for ${language.displayName}',
        'unsupported',
      );
      return;
    }

    yield InstallProgress.step('Downloading ${language.displayName}...');

    try {
      final installerPath = await _download(spec, onProgress: (f) {});

      yield InstallProgress.step(
          'Installing ${language.displayName}...', fraction: 0.6);

      await _runInstaller(language, installerPath, spec);

      yield InstallProgress.step('Verifying...', fraction: 0.9);

      final info = await _detector.detect(language);
      if (info.installed) {
        yield InstallProgress.complete(
            '${language.displayName} ${info.version ?? ''} installed');
      } else {
        yield InstallProgress.failure(
          'Install completed but runtime not detected',
          'post-install verification failed',
        );
      }
    } catch (e) {
      yield InstallProgress.failure(
          'Failed to install ${language.displayName}', e.toString());
    }
  }

  Future<String> _download(
    _InstallSpec spec, {
    required void Function(double) onProgress,
  }) async {
    final client = HttpClient();
    final url = spec.urlForPlatform();
    if (url == null) {
      throw UnsupportedError(
          'No installer URL for ${Platform.operatingSystem}');
    }

    final uri = Uri.parse(url);
    final request = await client.getUrl(uri);
    final response = await request.close();

    final total = response.contentLength;
    var received = 0;

    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
    final sink = file.openWrite();

    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total);
    }
    await sink.close();
    client.close();
    return file.path;
  }

  Future<void> _runInstaller(
    SupportedLanguage language,
    String installerPath,
    _InstallSpec spec,
  ) async {
    if (language == SupportedLanguage.cpp && !Platform.isWindows) {
      // MinGW is Windows-only; on other platforms g++ should already be present
      return;
    }

    if (spec.isArchive) {
      await _extractArchive(installerPath, spec);
      return;
    }

    final args = spec.silentArgs;
    final result = await Process.run(
      installerPath,
      args,
      runInShell: false,
    ).timeout(const Duration(minutes: 10));

    if (result.exitCode != 0 && result.exitCode != 3010) {
      // 3010 = reboot required (Windows), treat as success
      throw ProcessException(
        installerPath,
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }
  }

  Future<void> _extractArchive(String archivePath, _InstallSpec spec) async {
    final dir = await getApplicationSupportDirectory();
    final dest = '${dir.path}${Platform.pathSeparator}${spec.extractDirName}';
    await Directory(dest).create(recursive: true);

    // 7-zip available on Windows via path; fall back to tar on others
    final result = Platform.isWindows
        ? await Process.run('7z', ['x', archivePath, '-o$dest', '-y'])
        : await Process.run('tar', ['-xf', archivePath, '-C', dest]);

    if (result.exitCode != 0) {
      throw Exception('Archive extraction failed: ${result.stderr}');
    }
  }
}

class _InstallSpec {
  final String? windowsUrl;
  final String fileName;
  final List<String> silentArgs;
  final bool isArchive;
  final String extractDirName;

  const _InstallSpec({
    this.windowsUrl,
    required this.fileName,
    this.silentArgs = const [],
    this.isArchive = false,
    this.extractDirName = '',
  });

  String? urlForPlatform() {
    if (Platform.isWindows) return windowsUrl;
    return null;
  }
}

_InstallSpec? _installSpec(SupportedLanguage language) {
  switch (language) {
    case SupportedLanguage.python:
      return const _InstallSpec(
        windowsUrl:
            'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe',
        fileName: 'python-3.11.9-amd64.exe',
        silentArgs: ['/quiet', 'InstallAllUsers=1', 'PrependPath=1'],
      );
    case SupportedLanguage.javascript:
      return const _InstallSpec(
        windowsUrl: 'https://nodejs.org/dist/v20.14.0/node-v20.14.0-x64.msi',
        fileName: 'node-v20.14.0-x64.msi',
        silentArgs: ['/quiet', '/norestart'],
      );
    case SupportedLanguage.java:
      return const _InstallSpec(
        windowsUrl:
            'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.3%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.3_9.msi',
        fileName: 'OpenJDK21U-jdk_x64_windows.msi',
        silentArgs: ['/quiet', '/norestart'],
      );
    case SupportedLanguage.go:
      return const _InstallSpec(
        windowsUrl: 'https://go.dev/dl/go1.22.4.windows-amd64.msi',
        fileName: 'go1.22.4.windows-amd64.msi',
        silentArgs: ['/quiet', '/norestart'],
      );
    case SupportedLanguage.cpp:
      return const _InstallSpec(
        windowsUrl:
            'https://github.com/niXman/mingw-builds-binaries/releases/download/13.2.0-rt_v11-rev1/x86_64-13.2.0-release-posix-seh-ucrt-rt_v11-rev1.7z',
        fileName: 'mingw64.7z',
        isArchive: true,
        extractDirName: 'mingw64',
      );
  }
}
