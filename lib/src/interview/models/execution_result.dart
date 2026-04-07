class ExecutionResult {
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;
  final Duration elapsed;

  const ExecutionResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.timedOut,
    required this.elapsed,
  });

  bool get succeeded => !timedOut && exitCode == 0;

  String get trimmedStdout => stdout.trim();
}

class TestCaseResult {
  final String label;
  final bool passed;
  final String expected;
  final String actual;
  final bool timedOut;

  const TestCaseResult({
    required this.label,
    required this.passed,
    required this.expected,
    required this.actual,
    required this.timedOut,
  });
}
