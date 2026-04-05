import 'package:flutter/material.dart';
import '../bridge/bridge.dart' as bridge;

/// Onboarding wizard: checks Ollama availability, pulls model if needed,
/// then loads the KB and navigates to the main app.
class OnboardingPage extends StatefulWidget {
  final Widget nextPage;
  const OnboardingPage({super.key, required this.nextPage});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  _Step _step = _Step.checking;
  List<String> _pullLog = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // Step 1: health check
    setState(() => _step = _Step.checking);
    final healthy = await bridge.ollamaHealthCheck();

    if (healthy) {
      _finish();
      return;
    }

    // Step 2: Ollama not ready — try pulling the model
    setState(() => _step = _Step.pulling);
    final statuses = await bridge.ollamaPullModel();
    setState(() => _pullLog = statuses);

    final failed = statuses.any((s) => s.startsWith('error'));
    if (failed) {
      setState(() {
        _step = _Step.failed;
        _error = statuses.firstWhere((s) => s.startsWith('error'));
      });
      return;
    }

    _finish();
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => widget.nextPage),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MockMate Setup',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 32),
              _buildBody(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _Step.checking:
        return const _StatusRow(
          icon: Icons.search,
          label: 'Checking Ollama…',
          loading: true,
        );

      case _Step.pulling:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _StatusRow(
              icon: Icons.download,
              label: 'Pulling model (this may take a while)…',
              loading: true,
            ),
            if (_pullLog.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                height: 160,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  children: _pullLog
                      .map((s) => Text(s,
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 12)))
                      .toList(),
                ),
              ),
            ],
          ],
        );

      case _Step.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusRow(
              icon: Icons.error_outline,
              label: _error ?? 'Unknown error',
              loading: false,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            const Text(
              'Make sure Ollama is installed and running:\n'
              '  https://ollama.com/download\n\n'
              'Then restart MockMate.',
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _run,
              child: const Text('Retry'),
            ),
          ],
        );
    }
  }
}

enum _Step { checking, pulling, failed }

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool loading;
  final Color? color;

  const _StatusRow({
    required this.icon,
    required this.label,
    required this.loading,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        loading
            ? const SizedBox(
                width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, color: color ?? Colors.green),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(color: color))),
      ],
    );
  }
}
