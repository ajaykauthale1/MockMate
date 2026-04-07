import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';
import '../models/runtime_info.dart';

class RuntimeStatusChip extends StatelessWidget {
  final RuntimeInfo? info;
  final SupportedLanguage language;
  final VoidCallback? onInstall;

  const RuntimeStatusChip({
    super.key,
    required this.language,
    this.info,
    this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final installed = info?.installed ?? false;
    final label = info?.statusLabel ?? '${language.displayName} — checking…';
    final color = installed ? const Color(0xFF3CB371) : SkeColors.accent;

    return GestureDetector(
      onTap: installed ? null : onInstall,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              installed ? Icons.check_circle_outline : Icons.download_outlined,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
