import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/ske_theme.dart';
import 'interview_provider.dart';
import 'widgets/code_panel.dart';
import 'widgets/evaluation_report_view.dart';
import 'widgets/interviewer_panel.dart';
import 'widgets/question_panel.dart';
import 'widgets/session_timer.dart';

class InterviewPage extends ConsumerStatefulWidget {
  const InterviewPage({super.key});

  @override
  ConsumerState<InterviewPage> createState() => _InterviewPageState();
}

class _InterviewPageState extends ConsumerState<InterviewPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(interviewProvider.notifier)
        ..loadQuestions()
        ..detectRuntimes();
    });
  }

  @override
  void dispose() {
    ref.read(interviewProvider.notifier).stopTts();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final state = ref.watch(interviewProvider);
    final notifier = ref.read(interviewProvider.notifier);

    // Show evaluation report as full-screen overlay when complete
    if (state.sessionState == SessionState.complete && state.report != null) {
      return EvaluationReportView(
        report: state.report!,
        onDone: () async {
          await notifier.resetSession();
          if (!mounted) return;
          // ignore: use_build_context_synchronously
          Navigator.of(context).pop();
        },
      );
    }

    final q = state.question;

    return Scaffold(
      backgroundColor: c.background,
      appBar: _InterviewAppBar(state: state, notifier: notifier),
      body: q == null
          ? _QuestionPicker(state: state, notifier: notifier)
          : _ThreePanelLayout(state: state),
    );
  }
}

// ---------------------------------------------------------------------------
// AppBar
// ---------------------------------------------------------------------------

class _InterviewAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final InterviewState state;
  final InterviewNotifier notifier;

  const _InterviewAppBar({required this.state, required this.notifier});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.appColors;
    final active = state.sessionState == SessionState.active;
    final submitting = state.sessionState == SessionState.submitting ||
        state.sessionState == SessionState.evaluating;

    return AppBar(
      title: Text(
        state.question?.title ?? 'Coding Interview',
        style: TextStyle(
            color: c.accent,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1),
      ),
      actions: [
        if (active)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SessionTimer(
              remaining: state.remaining,
              total: state.totalDuration,
            ),
          ),
        if (active || submitting)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: submitting
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.accent),
                  )
                : TextButton(
                    onPressed: notifier.submitCode,
                    style: TextButton.styleFrom(
                      backgroundColor: c.accent.withValues(alpha: 0.15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text('Submit',
                        style: TextStyle(
                            color: c.accent,
                            fontWeight: FontWeight.w600)),
                  ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Question picker (before session starts)
// ---------------------------------------------------------------------------

class _QuestionPicker extends StatelessWidget {
  final InterviewState state;
  final InterviewNotifier notifier;

  const _QuestionPicker({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    if (state.questions.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: c.accent),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Select a Question',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              ...state.questions.map((q) => _QuestionCard(
                    question: q,
                    onTap: () => notifier.selectQuestion(q),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final dynamic question;
  final VoidCallback onTap;

  const _QuestionCard({required this.question, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: c.raised(radius: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(question.title,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.userBubble,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.arrow_forward, color: c.accent, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3-panel layout
// ---------------------------------------------------------------------------

class _ThreePanelLayout extends StatelessWidget {
  final InterviewState state;

  const _ThreePanelLayout({required this.state});

  @override
  Widget build(BuildContext context) {
    return state.sessionState == SessionState.notStarted
        ? _StartOverlay(state: state)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300, child: QuestionPanel(question: state.question!)),
              const Expanded(flex: 3, child: CodePanel()),
              const Expanded(flex: 2, child: InterviewerPanel()),
            ],
          );
  }
}

// ---------------------------------------------------------------------------
// Start overlay
// ---------------------------------------------------------------------------

class _StartOverlay extends ConsumerWidget {
  final InterviewState state;
  const _StartOverlay({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.appColors;
    final notifier = ref.read(interviewProvider.notifier);

    final durations = [
      const Duration(minutes: 20),
      const Duration(minutes: 30),
      const Duration(minutes: 45),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state.question!.title,
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose your time limit and start when ready.',
                style: TextStyle(color: c.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: durations
                    .map((d) => Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 6),
                          child: _DurationChip(
                            label: '${d.inMinutes} min',
                            selected: state.totalDuration == d,
                            onTap: () => notifier.setDuration(d),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: notifier.startSession,
                child: const Text('Start Interview',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DurationChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: selected
            ? c.raised(radius: 8, color: c.accent.withValues(alpha: 0.2))
            : c.sunken(radius: 8),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.accent : c.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
