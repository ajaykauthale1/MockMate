import 'execution_result.dart';

enum Recommendation { strongHire, hire, noHire, strongNoHire }

extension RecommendationExt on Recommendation {
  String get label => switch (this) {
        Recommendation.strongHire => 'Strong Hire',
        Recommendation.hire => 'Hire',
        Recommendation.noHire => 'No Hire',
        Recommendation.strongNoHire => 'Strong No Hire',
      };

  bool get positive =>
      this == Recommendation.strongHire || this == Recommendation.hire;
}

class EvaluationReport {
  final List<TestCaseResult> testResults;
  final String aiNarrative; // raw LLM evaluation text
  final Recommendation? recommendation; // parsed from narrative if possible
  final DateTime generatedAt;

  const EvaluationReport({
    required this.testResults,
    required this.aiNarrative,
    this.recommendation,
    required this.generatedAt,
  });

  int get testsPassed => testResults.where((r) => r.passed).length;
  int get testsTotal => testResults.length;
}
