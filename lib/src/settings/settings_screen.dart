import 'package:flutter/material.dart';

import '../bridge/bridge.dart' as bridge;
import '../theme/ske_theme.dart';

/// Supported BYOK LLM providers.
enum _Provider { ollama, openai, anthropic }

/// Settings screen for switching the LLM provider and entering BYOK keys.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  _Provider _provider = _Provider.ollama;
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();

  bool _validating = false;
  bool _saving = false;
  String? _statusMsg;
  bool _statusOk = true;

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _validate() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      _setStatus('Enter an API key first.', ok: false);
      return;
    }
    setState(() { _validating = true; _statusMsg = null; });
    final providerName = _provider == _Provider.openai ? 'openai' : 'anthropic';
    final ok = await bridge.validateApiKey(provider: providerName, apiKey: key);
    setState(() { _validating = false; });
    _setStatus(ok ? 'Key accepted.' : 'Key rejected or service unreachable.', ok: ok);
  }

  Future<void> _apply() async {
    setState(() { _saving = true; _statusMsg = null; });
    final model = _modelCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();

    switch (_provider) {
      case _Provider.ollama:
        // Ollama is local; no key needed — just confirm health.
        final ok = await bridge.ollamaHealthCheck();
        _setStatus(ok ? 'Ollama active.' : 'Ollama not reachable.', ok: ok);
      case _Provider.openai:
        await bridge.initOpenaiLlm(apiKey: key, model: model, baseUrl: baseUrl);
        _setStatus('OpenAI provider activated.', ok: true);
      case _Provider.anthropic:
        await bridge.initAnthropicLlm(apiKey: key, model: model);
        _setStatus('Anthropic provider activated.', ok: true);
    }
    setState(() { _saving = false; });
  }

  void _setStatus(String msg, {required bool ok}) =>
      setState(() { _statusMsg = msg; _statusOk = ok; });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SkeColors.background,
      appBar: AppBar(
        backgroundColor: SkeColors.panelDark,
        title: const Text('Settings', style: TextStyle(color: SkeColors.textPrimary)),
        iconTheme: const IconThemeData(color: SkeColors.textPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Provider selector ──────────────────────────────────────────────
            _SectionLabel('LLM Provider'),
            const SizedBox(height: 8),
            _ProviderSelector(
              value: _provider,
              onChanged: (p) => setState(() {
                _provider = p;
                _statusMsg = null;
              }),
            ),
            const SizedBox(height: 24),

            // ── BYOK fields ───��────────────────────────────────────────────────
            if (_provider != _Provider.ollama) ...[
              _SectionLabel('API Key'),
              const SizedBox(height: 8),
              _SkeTextField(
                controller: _keyCtrl,
                hint: 'sk-...',
                obscure: true,
              ),
              const SizedBox(height: 16),
              _SectionLabel('Model (optional)'),
              const SizedBox(height: 8),
              _SkeTextField(
                controller: _modelCtrl,
                hint: _provider == _Provider.openai
                    ? 'gpt-4o-mini'
                    : 'claude-haiku-4-5-20251001',
              ),
              if (_provider == _Provider.openai) ...[
                const SizedBox(height: 16),
                _SectionLabel('Base URL (optional)'),
                const SizedBox(height: 8),
                _SkeTextField(
                  controller: _baseUrlCtrl,
                  hint: 'https://api.openai.com',
                ),
              ],
              const SizedBox(height: 16),
              _ValidateButton(
                loading: _validating,
                onPressed: _validate,
              ),
              const SizedBox(height: 24),
            ],

            // ── Apply button ───────────────────────────────────────────────────
            _ApplyButton(
              loading: _saving,
              onPressed: _apply,
            ),

            // ── Status message ─────────────────────────────────────────────────
            if (_statusMsg != null) ...[
              const SizedBox(height: 16),
              _StatusBanner(message: _statusMsg!, ok: _statusOk),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small helper widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: SkeColors.textSecondary,
          fontSize: 12,
          letterSpacing: 1.2,
        ),
      );
}

class _ProviderSelector extends StatelessWidget {
  final _Provider value;
  final ValueChanged<_Provider> onChanged;
  const _ProviderSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: skeRaised(radius: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_Provider>(
          value: value,
          dropdownColor: SkeColors.panel,
          style: const TextStyle(color: SkeColors.textPrimary, fontSize: 15),
          isExpanded: true,
          onChanged: (p) { if (p != null) onChanged(p); },
          items: const [
            DropdownMenuItem(value: _Provider.ollama,    child: Text('Ollama (local)')),
            DropdownMenuItem(value: _Provider.openai,    child: Text('OpenAI (BYOK)')),
            DropdownMenuItem(value: _Provider.anthropic, child: Text('Anthropic (BYOK)')),
          ],
        ),
      ),
    );
  }
}

class _SkeTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  const _SkeTextField({
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: skeSunken(radius: 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: SkeColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: SkeColors.textSecondary, fontSize: 14),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }
}

class _ValidateButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;
  const _ValidateButton({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: loading ? null : onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: SkeColors.accent,
        side: const BorderSide(color: SkeColors.accentDim),
      ),
      child: loading
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('Validate Key'),
    );
  }
}

class _ApplyButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;
  const _ApplyButton({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: SkeColors.accent,
          foregroundColor: SkeColors.background,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: loading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: SkeColors.background))
            : const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final String message;
  final bool ok;
  const _StatusBanner({required this.message, required this.ok});

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.greenAccent.withValues(alpha: 0.15) : SkeColors.mic.withValues(alpha: 0.15);
    final border = ok ? Colors.greenAccent : SkeColors.mic;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(color: ok ? Colors.greenAccent : SkeColors.mic, fontSize: 13),
      ),
    );
  }
}
