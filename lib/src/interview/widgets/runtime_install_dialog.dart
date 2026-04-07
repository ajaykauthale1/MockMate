import 'package:flutter/material.dart';
import '../../theme/ske_theme.dart';
import '../models/runtime_info.dart';
import '../services/runtime_installer.dart';

class RuntimeInstallDialog extends StatefulWidget {
  final SupportedLanguage language;

  const RuntimeInstallDialog({super.key, required this.language});

  static Future<bool> show(
      BuildContext context, SupportedLanguage language) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RuntimeInstallDialog(language: language),
        ) ??
        false;
  }

  @override
  State<RuntimeInstallDialog> createState() => _RuntimeInstallDialogState();
}

class _RuntimeInstallDialogState extends State<RuntimeInstallDialog> {
  final _installer = RuntimeInstaller();
  String _message = 'Starting…';
  double? _fraction;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await for (final progress in _installer.install(widget.language)) {
      if (!mounted) return;
      setState(() {
        _message = progress.message;
        _fraction = progress.fraction;
        _done = progress.done;
        _failed = progress.failed;
      });
      if (progress.done) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: SkeColors.panel,
      title: Text(
        'Installing ${widget.language.displayName}',
        style: const TextStyle(color: SkeColors.textPrimary),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_message,
                style: const TextStyle(
                    color: SkeColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 14),
            if (!_done)
              _fraction != null
                  ? LinearProgressIndicator(
                      value: _fraction,
                      color: SkeColors.accent,
                      backgroundColor: SkeColors.panelDark,
                    )
                  : const LinearProgressIndicator(
                      color: SkeColors.accent,
                      backgroundColor: SkeColors.panelDark,
                    ),
            if (_done)
              Icon(
                _failed ? Icons.error_outline : Icons.check_circle_outline,
                color: _failed ? const Color(0xFFBE3A3A) : const Color(0xFF3CB371),
                size: 28,
              ),
          ],
        ),
      ),
      actions: _done
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(!_failed),
                child: Text(
                  _failed ? 'Close' : 'Done',
                  style: const TextStyle(color: SkeColors.accent),
                ),
              ),
            ]
          : null,
    );
  }
}
