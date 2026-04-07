import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/execution_result.dart';
import '../models/interview_question.dart';
import '../models/runtime_info.dart';

class CodeExecutor {
  static const _defaultTimeout = Duration(seconds: 10);

  Future<ExecutionResult> run({
    required String code,
    required SupportedLanguage language,
    required String stdin,
    Duration timeout = _defaultTimeout,
  }) async {
    final dir = await _tempDir();
    try {
      return await _execute(
        code: code,
        language: language,
        stdin: stdin,
        workDir: dir,
        timeout: timeout,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<List<TestCaseResult>> runAllTests({
    required String code,
    required SupportedLanguage language,
    required List<TestCase> tests,
    Duration timeout = _defaultTimeout,
  }) async {
    final results = <TestCaseResult>[];
    for (final tc in tests) {
      final result = await run(
        code: code,
        language: language,
        stdin: tc.stdin,
        timeout: timeout,
      );
      results.add(TestCaseResult(
        label: tc.label,
        passed: !result.timedOut &&
            result.exitCode == 0 &&
            result.trimmedStdout == tc.expectedStdout.trim(),
        expected: tc.expectedStdout,
        actual: result.trimmedStdout,
        timedOut: result.timedOut,
      ));
    }
    return results;
  }

  Future<ExecutionResult> _execute({
    required String code,
    required SupportedLanguage language,
    required String stdin,
    required Directory workDir,
    required Duration timeout,
  }) async {
    final path = workDir.path;
    final sep = Platform.pathSeparator;

    switch (language) {
      case SupportedLanguage.python:
        final file = '$path${sep}solution.py';
        await File(file).writeAsString(code);
        return _runProcess('python3', [file], stdin, timeout,
            fallback: () => _runProcess('python', [file], stdin, timeout));

      case SupportedLanguage.javascript:
        final file = '$path${sep}solution.js';
        await File(file).writeAsString(code);
        return _runProcess('node', [file], stdin, timeout);

      case SupportedLanguage.java:
        final file = '$path${sep}Solution.java';
        await File(file).writeAsString(code);
        final compile =
            await _runProcess('javac', [file], '', const Duration(seconds: 30));
        if (!compile.succeeded) return compile;
        return _runProcess('java', ['-cp', path, 'Solution'], stdin, timeout);

      case SupportedLanguage.go:
        final file = '$path${sep}solution.go';
        await File(file).writeAsString(code);
        return _runProcess('go', ['run', file], stdin, timeout);

      case SupportedLanguage.cpp:
        final src = '$path${sep}solution.cpp';
        final bin = '$path${sep}solution${Platform.isWindows ? '.exe' : ''}';
        await File(src).writeAsString(code);
        final compile = await _runProcess(
            'g++', [src, '-o', bin, '-std=c++17'], '', const Duration(seconds: 30),
            fallback: () => _runProcess('clang++', [src, '-o', bin, '-std=c++17'],
                '', const Duration(seconds: 30)));
        if (!compile.succeeded) return compile;
        return _runProcess(bin, [], stdin, timeout);
    }
  }

  Future<ExecutionResult> _runProcess(
    String executable,
    List<String> args,
    String stdin,
    Duration timeout, {
    Future<ExecutionResult> Function()? fallback,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final process = await Process.start(
        executable,
        args,
        runInShell: false,
      );

      if (stdin.isNotEmpty) {
        process.stdin.write(stdin);
      }
      await process.stdin.close();

      final stdoutFuture = process.stdout.transform(
        const SystemEncoding().decoder,
      ).join();
      final stderrFuture = process.stderr.transform(
        const SystemEncoding().decoder,
      ).join();

      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );

      stopwatch.stop();
      final timedOut = exitCode == -1;

      return ExecutionResult(
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
        exitCode: exitCode,
        timedOut: timedOut,
        elapsed: stopwatch.elapsed,
      );
    } on ProcessException catch (e) {
      stopwatch.stop();
      if (fallback != null) return fallback();
      return ExecutionResult(
        stdout: '',
        stderr: e.toString(),
        exitCode: -2,
        timedOut: false,
        elapsed: stopwatch.elapsed,
      );
    }
  }

  Future<Directory> _tempDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}mockmate_${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);
    return dir;
  }
}
