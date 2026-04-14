import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';
import '../models/evaluation_report.dart';
import '../models/execution_result.dart';

class EvaluationReportView extends StatelessWidget {
  final EvaluationReport report;
  final VoidCallback onDone;

  const EvaluationReportView({
    super.key,
    required this.report,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        title: Text('Evaluation Report',
            style: TextStyle(
                color: c.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1)),
        leading: IconButton(
          icon: Icon(Icons.close, color: c.textSecondary),
          onPressed: onDone,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RecommendationBanner(report: report),
            const SizedBox(height: 20),
            _TestResultsTable(results: report.testResults),
            const SizedBox(height: 20),
            _NarrativeSection(text: report.aiNarrative),
            const SizedBox(height: 32),
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: onDone,
                child: const Text('Done',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _RecommendationBanner extends StatelessWidget {
  final EvaluationReport report;
  const _RecommendationBanner({required this.report});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final rec = report.recommendation;
    final positive = rec?.positive ?? false;
    final color =
        positive ? const Color(0xFF3CB371) : const Color(0xFFBE3A3A);
    final label = rec?.label ?? 'Evaluation Complete';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${report.testsPassed}/${report.testsTotal} test cases passed',
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _TestResultsTable extends StatelessWidget {
  final List<TestCaseResult> results;
  const _TestResultsTable({required this.results});

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const SizedBox.shrink();
    final c = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Test Results',
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: c.panelDark,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: results.map((r) => _TestRow(result: r)).toList(),
          ),
        ),
      ],
    );
  }
}

class _TestRow extends StatelessWidget {
  final TestCaseResult result;
  const _TestRow({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final color = result.passed
        ? const Color(0xFF3CB371)
        : result.timedOut
            ? c.accent
            : const Color(0xFFBE3A3A);
    final status = result.passed
        ? 'PASS'
        : result.timedOut
            ? 'TIMEOUT'
            : 'FAIL';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            result.passed ? Icons.check : Icons.close,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: Text(result.label,
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(status,
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              result.passed
                  ? 'expected: ${result.expected}'
                  : 'expected: ${result.expected}  got: ${result.actual}',
              style: TextStyle(color: c.textSecondary, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _NarrativeSection extends StatelessWidget {
  final String text;
  const _NarrativeSection({required this.text});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AI Feedback',
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.panelDark,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            text,
            style: TextStyle(
                color: c.textPrimary, fontSize: 13, height: 1.6),
          ),
        ),
      ],
    );
  }
}
