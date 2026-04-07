import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';
import '../models/runtime_info.dart';

class LanguageSelector extends StatelessWidget {
  final SupportedLanguage value;
  final ValueChanged<SupportedLanguage> onChanged;

  const LanguageSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: SkeColors.panelDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SkeColors.shadowLight),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<SupportedLanguage>(
          value: value,
          dropdownColor: SkeColors.panelDark,
          style: const TextStyle(color: SkeColors.textPrimary, fontSize: 13),
          isDense: true,
          items: SupportedLanguage.values
              .map((l) => DropdownMenuItem(
                    value: l,
                    child: Text(l.displayName),
                  ))
              .toList(),
          onChanged: (l) => l != null ? onChanged(l) : null,
        ),
      ),
    );
  }
}
