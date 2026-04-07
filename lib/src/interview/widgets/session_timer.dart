import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';

class SessionTimer extends StatelessWidget {
  final Duration remaining;
  final Duration total;

  const SessionTimer({
    super.key,
    required this.remaining,
    required this.total,
  });

  bool get _isWarning => remaining.inMinutes < 5;
  bool get _isExpired => remaining == Duration.zero;

  String get _label {
    if (_isExpired) return '0:00';
    final m = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = _isExpired
        ? const Color(0xFFBE3A3A)
        : _isWarning
            ? const Color(0xFFBE3A3A)
            : SkeColors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _isWarning
            ? const Color(0xFFBE3A3A).withValues(alpha: 0.12)
            : SkeColors.panelDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _isWarning
              ? const Color(0xFFBE3A3A).withValues(alpha: 0.5)
              : SkeColors.shadowLight,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            _label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
