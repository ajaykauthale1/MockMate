import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/ske_theme.dart';
import '../interview_provider.dart';
import 'language_selector.dart';
import 'runtime_install_dialog.dart';
import 'runtime_status_chip.dart';

class CodePanel extends ConsumerStatefulWidget {
  const CodePanel({super.key});

  @override
  ConsumerState<CodePanel> createState() => _CodePanelState();
}

class _CodePanelState extends ConsumerState<CodePanel> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(interviewProvider).code;
    _ctrl = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(interviewProvider);
    final notifier = ref.read(interviewProvider.notifier);
    final locked = state.sessionState == SessionState.submitting ||
        state.sessionState == SessionState.evaluating ||
        state.sessionState == SessionState.complete;

    // Sync controller when language changes (starter code swap)
    ref.listen<InterviewState>(interviewProvider, (prev, next) {
      if (prev?.language != next.language || prev?.question != next.question) {
        if (_ctrl.text != next.code) {
          _ctrl.text = next.code;
          _ctrl.selection = TextSelection.collapsed(offset: next.code.length);
        }
      }
    });

    final runtime = state.runtimes[state.language];

    return Container(
      color: SkeColors.background,
      child: Column(
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: SkeColors.panelDark,
              border: Border(
                  bottom: BorderSide(color: SkeColors.shadowDark)),
            ),
            child: Row(
              children: [
                LanguageSelector(
                  value: state.language,
                  onChanged: locked ? (_) {} : notifier.setLanguage,
                ),
                const SizedBox(width: 10),
                RuntimeStatusChip(
                  language: state.language,
                  info: runtime,
                  onInstall: () async {
                    final ok = await RuntimeInstallDialog.show(
                        context, state.language);
                    if (ok) notifier.detectRuntimes();
                  },
                ),
              ],
            ),
          ),
          // Editor
          Expanded(
            child: Container(
              color: const Color(0xFF0D0D1A),
              child: TextField(
                controller: _ctrl,
                onChanged: locked ? null : notifier.setCode,
                readOnly: locked,
                expands: true,
                maxLines: null,
                minLines: null,
                style: const TextStyle(
                  color: SkeColors.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.55,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  hintText: '// Start coding…',
                  hintStyle: TextStyle(color: SkeColors.shadowLight),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
