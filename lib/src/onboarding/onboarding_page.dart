import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../bridge/bridge.dart' as bridge;
import '../services/config_service.dart';
import '../services/kb_service.dart';
import '../theme/ske_theme.dart';
import 'model_catalog.dart';
import 'ollama_installer.dart';

/// 6-step onboarding wizard.
///
/// Step 1: LLM mode selection (Local / Cloud BYOK)
/// Step 2: Ollama detection / auto-start / install
/// Step 3: Model catalog selection + pull
/// Step 4: LLM model download progress
/// Step 5: Voice (Kokoro) asset download
/// Step 6: Finish → nextPage
class OnboardingPage extends StatefulWidget {
  final Widget nextPage;
  const OnboardingPage({super.key, required this.nextPage});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

enum _Step { llmMode, ollamaDetect, modelCatalog, installProgress, voiceSetup, done }

class _OnboardingPageState extends State<OnboardingPage> {
  _Step _step = _Step.llmMode;
  String _llmMode = 'local'; // 'local' | 'openai' | 'anthropic'
  String? _selectedModel;
  String _statusMsg = '';
  List<String> _pullLog = [];
  bool _busy = false;
  String? _ollamaBinPath;

  // Voice setup state
  String _voiceStep = '';
  double? _voiceProgress; // null = indeterminate
  String? _voiceError;
  bool _voiceDone = false;

  // ── Step 1 ──────────────────────────────────────────────────────────────

  Widget _buildLlmModeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How do you want to run the AI?',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 24),
        _ModeCard(
          icon: Icons.computer,
          title: 'Run Locally (Ollama)',
          subtitle: 'Free, private, offline-first. Requires 4–8 GB RAM.',
          selected: _llmMode == 'local',
          onTap: () => setState(() => _llmMode = 'local'),
        ),
        const SizedBox(height: 12),
        _ModeCard(
          icon: Icons.cloud,
          title: 'Cloud API (BYOK)',
          subtitle: 'OpenAI or Anthropic — bring your own API key.',
          selected: _llmMode != 'local',
          onTap: () => setState(() => _llmMode = 'openai'),
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: _onLlmModeContinue,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Future<void> _onLlmModeContinue() async {
    if (_llmMode == 'local') {
      setState(() {
        _step = _Step.ollamaDetect;
        _busy = true;
        _statusMsg = 'Checking for Ollama…';
      });
      await _detectOllama();
    } else {
      // BYOK path — skip LLM model pull, go straight to voice setup
      await _startVoiceSetup();
    }
  }

  // ── Step 2 ──────────────────────────────────────────────────────────────

  Future<void> _detectOllama() async {
    final running = await bridge.ollamaHealthCheck();
    if (running) {
      _ollamaBinPath = await OllamaInstaller.detectBinPath();
      setState(() { _step = _Step.modelCatalog; _busy = false; });
      return;
    }

    final bin = await OllamaInstaller.detectBinPath();
    if (bin != null) {
      setState(() => _statusMsg = 'Starting Ollama…');
      final ok = await bridge.startOllamaSidecar(binPath: bin);
      if (ok) {
        _ollamaBinPath = bin;
        setState(() { _step = _Step.modelCatalog; _busy = false; });
        return;
      }
    }

    setState(() { _busy = false; });
  }

  Widget _buildOllamaDetectStep() {
    if (_busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusRow(icon: Icons.search, label: _statusMsg, loading: true),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusRow(
          icon: Icons.error_outline,
          label: 'Ollama not found.',
          loading: false,
          color: context.appColors.mic,
        ),
        const SizedBox(height: 16),
        const Text('MockMate needs Ollama to run local models.\n'
            'Click below to download and install it automatically.'),
        const SizedBox(height: 24),
        _InstallOllamaButton(
          onDone: (binPath) {
            _ollamaBinPath = binPath;
            setState(() => _step = _Step.modelCatalog);
          },
          onError: (msg) => setState(() => _statusMsg = msg),
        ),
      ],
    );
  }

  // ── Step 3 ──────────────────────────────────────────────────────────────

  Widget _buildModelCatalogStep() {
    _selectedModel ??= kModelCatalog.first.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose a model', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('The model will be downloaded the first time you use it.'),
        const SizedBox(height: 16),
        ...kModelCatalog.map((m) => _ModelCard(
              entry: m,
              selected: _selectedModel == m.id,
              onTap: () => setState(() => _selectedModel = m.id),
            )),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _selectedModel == null ? null : _onModelContinue,
          child: const Text('Download & Continue'),
        ),
      ],
    );
  }

  Future<void> _onModelContinue() async {
    setState(() {
      _step = _Step.installProgress;
      _busy = true;
      _pullLog = [];
      _statusMsg = 'Pulling ${_selectedModel}…';
    });

    final statuses = await bridge.ollamaPullModel();
    _pullLog = statuses;

    final failed = statuses.any((s) => s.startsWith('error'));
    if (failed) {
      setState(() {
        _busy = false;
        _statusMsg = statuses.firstWhere((s) => s.startsWith('error'));
      });
      return;
    }

    // Save LLM config then proceed to voice setup.
    final cfg = AppConfig(
      llmMode: _llmMode,
      ollamaBinPath: _ollamaBinPath ?? '',
      ollamaModel: _selectedModel!,
    );
    await ConfigService.save(cfg);
    await loadKnowledgeBaseAssets();
    await _startVoiceSetup();
  }

  // ── Step 4 ──────────────────────────────────────────────────────────────

  Widget _buildInstallProgressStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusRow(
          icon: Icons.download,
          label: _statusMsg,
          loading: _busy,
          color: _statusMsg.startsWith('error') ? context.appColors.mic : null,
        ),
        if (_pullLog.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            height: 180,
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
        if (_statusMsg.startsWith('error')) ...[
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _onModelContinue,
            child: const Text('Retry'),
          ),
        ],
      ],
    );
  }

  // ── Step 5 — Voice setup ─────────────────────────────────────────────────

  Future<void> _startVoiceSetup() async {
    setState(() {
      _step = _Step.voiceSetup;
      _voiceStep = 'Setting up voice…';
      _voiceProgress = null;
      _voiceError = null;
      _voiceDone = false;
    });

    // kokoro + espeak-ng are both bundled alongside the app executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // Use the bundled kokoro dir — no download needed on installed builds.
    // Falls back to AppData if the bundled dir is missing (dev / portable).
    final bundledKokoro = Directory('$exeDir/kokoro');
    final String assetDir;
    if (bundledKokoro.existsSync()) {
      assetDir = bundledKokoro.path;
    } else {
      final appDir = await getApplicationSupportDirectory();
      assetDir = '${appDir.path}/kokoro';
    }
    final espeakDir = '$exeDir/espeak-ng';

    await for (final event in bridge.ensureVoiceAssets(
      assetDir: assetDir,
      espeakDir: espeakDir,
    )) {
      if (!mounted) return;
      if (event.done) {
        if (event.error.isNotEmpty) {
          setState(() { _voiceError = event.error; _voiceDone = true; });
        } else {
          // Persist Kokoro paths so next launch skips the download.
          final cfg = await ConfigService.load();
          await ConfigService.save(cfg.copyWith(
            kokoroModelPath: '$assetDir/kokoro-v0_19.onnx',
            kokoroStylePath: '$assetDir/af_heart.bin',
            espeakBinPath: '$espeakDir/${Platform.isWindows ? 'espeak-ng.exe' : 'espeak-ng'}',
          ));
          setState(() { _voiceDone = true; });
          _finish();
        }
        return;
      }

      final total = event.bytesTotal.toInt();
      final done = event.bytesDone.toInt();
      setState(() {
        _voiceStep = event.step;
        _voiceProgress = (total > 0) ? done / total : null;
      });
    }
  }

  Widget _buildVoiceSetupStep() {
    if (_voiceError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusRow(
            icon: Icons.volume_off,
            label: 'Voice setup failed',
            loading: false,
            color: context.appColors.mic,
          ),
          const SizedBox(height: 8),
          Text(_voiceError!,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 24),
          const Text(
              'MockMate will work without voice — you can retry from Settings.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _finish,
            child: const Text('Continue without voice'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _startVoiceSetup,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Setting up voice', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Initialising voice engine. This only takes a moment.'),
        const SizedBox(height: 24),
        _StatusRow(
          icon: Icons.record_voice_over,
          label: _voiceStep,
          loading: !_voiceDone,
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: _voiceProgress),
        if (_voiceProgress != null) ...[
          const SizedBox(height: 4),
          Text(
            '${(_voiceProgress! * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ],
    );
  }

  // ── Routing ──────────────────────────────────────────────────────────────

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
              const SizedBox(height: 8),
              _StepIndicator(
                steps: const ['Mode', 'Ollama', 'Model', 'Installing', 'Voice'],
                current: _step.index,
              ),
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
      case _Step.llmMode:
        return _buildLlmModeStep();
      case _Step.ollamaDetect:
        return _buildOllamaDetectStep();
      case _Step.modelCatalog:
        return _buildModelCatalogStep();
      case _Step.installProgress:
        return _buildInstallProgressStep();
      case _Step.voiceSetup:
        return _buildVoiceSetupStep();
      case _Step.done:
        return const _StatusRow(
            icon: Icons.check_circle, label: 'All set!', loading: false);
    }
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final List<String> steps;
  final int current;
  const _StepIndicator({required this.steps, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(steps.length, (i) {
        final done = i < current;
        final active = i == current;
        return Expanded(
          child: Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: done
                    ? Colors.green
                    : active
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.shade300,
                child: Text(
                  done ? '✓' : '${i + 1}',
                  style: TextStyle(
                      fontSize: 11,
                      color: done || active ? Colors.white : Colors.grey),
                ),
              ),
              if (i < steps.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: done ? Colors.green : Colors.grey.shade300,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            if (selected) const Icon(Icons.check_circle, color: Colors.green),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final ModelEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _ModelCard({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(entry.id,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      if (entry.freeForEnterprise)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Free for Enterprise',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.green.shade800)),
                        ),
                    ],
                  ),
                  Text(entry.description,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${entry.vramGb} GB',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text(entry.vendor,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallOllamaButton extends StatefulWidget {
  final void Function(String binPath) onDone;
  final void Function(String error) onError;

  const _InstallOllamaButton({required this.onDone, required this.onError});

  @override
  State<_InstallOllamaButton> createState() => _InstallOllamaButtonState();
}

class _InstallOllamaButtonState extends State<_InstallOllamaButton> {
  double? _progress;
  String _label = 'Install Ollama';

  Future<void> _install() async {
    setState(() => _progress = 0);
    await for (final event in OllamaInstaller.install()) {
      if (!mounted) return;
      if (event == 'done') {
        final bin = await OllamaInstaller.detectBinPath();
        widget.onDone(bin ?? 'ollama');
        return;
      } else if (event.startsWith('error:')) {
        widget.onError(event);
        setState(() => _progress = null);
        return;
      } else if (event.startsWith('Install')) {
        setState(() => _label = event);
      } else {
        final v = double.tryParse(event);
        if (v != null) setState(() => _progress = v);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_progress != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_label),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress == 0 ? null : _progress),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: _install,
      icon: const Icon(Icons.download),
      label: const Text('Install Ollama'),
    );
  }
}

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
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, color: color ?? Colors.green),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(color: color))),
      ],
    );
  }
}
