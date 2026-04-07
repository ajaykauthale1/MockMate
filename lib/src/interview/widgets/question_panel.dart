import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';
import '../models/interview_question.dart';
import 'difficulty_badge.dart';

class QuestionPanel extends StatelessWidget {
  final InterviewQuestion question;

  const QuestionPanel({super.key, required this.question});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: skeSunken(radius: 0, color: SkeColors.panelDark),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    question.title,
                    style: const TextStyle(
                      color: SkeColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DifficultyBadge(difficulty: question.difficulty),
              ],
            ),
            if (question.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: question.tags
                    .map((t) => _TagChip(tag: t))
                    .toList(),
              ),
            ],
            const SizedBox(height: 14),
            _Section(
              label: 'Description',
              child: Text(
                question.description,
                style: const TextStyle(
                    color: SkeColors.textPrimary,
                    fontSize: 13,
                    height: 1.6),
              ),
            ),
            if (question.examples.isNotEmpty) ...[
              const SizedBox(height: 14),
              _Section(
                label: 'Examples',
                child: Column(
                  children: question.examples
                      .asMap()
                      .entries
                      .map((e) => _ExampleBlock(
                          index: e.key + 1, example: e.value))
                      .toList(),
                ),
              ),
            ],
            if (question.constraints.isNotEmpty) ...[
              const SizedBox(height: 14),
              _Section(
                label: 'Constraints',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: question.constraints
                      .map((c) => Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('• ',
                                    style: TextStyle(
                                        color: SkeColors.accent,
                                        fontSize: 13)),
                                Expanded(
                                  child: Text(c,
                                      style: const TextStyle(
                                          color: SkeColors.textSecondary,
                                          fontSize: 12,
                                          fontFamily: 'monospace')),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  final Widget child;
  const _Section({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: SkeColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _ExampleBlock extends StatelessWidget {
  final int index;
  final QuestionExample example;
  const _ExampleBlock({required this.index, required this.example});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: SkeColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: SkeColors.shadowLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Example $index',
              style: const TextStyle(
                  color: SkeColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _mono('Input:  ${example.input}'),
          _mono('Output: ${example.output}'),
          if (example.explanation != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                example.explanation!,
                style: const TextStyle(
                    color: SkeColors.textSecondary,
                    fontSize: 11,
                    height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mono(String text) => Text(
        text,
        style: const TextStyle(
          color: SkeColors.textPrimary,
          fontSize: 12,
          fontFamily: 'monospace',
          height: 1.5,
        ),
      );
}

class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: SkeColors.userBubble.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(tag,
          style: const TextStyle(
              color: SkeColors.textSecondary, fontSize: 10)),
    );
  }
}
