import 'package:flutter/material.dart';
import '../models/interview_question.dart';

class DifficultyBadge extends StatelessWidget {
  final Difficulty difficulty;
  const DifficultyBadge({super.key, required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (difficulty) {
      Difficulty.easy => ('Easy', const Color(0xFF3CB371)),
      Difficulty.medium => ('Medium', const Color(0xFFD4A017)),
      Difficulty.hard => ('Hard', const Color(0xFFBE3A3A)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
