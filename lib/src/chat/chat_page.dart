import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_provider.dart';
import '../avatar/avatar_widget.dart';
import '../bridge/bridge.dart' as bridge;
import '../settings/settings_screen.dart';
import '../theme/ske_theme.dart';
import 'chat_provider.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    bridge.stopAudio();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await ref.read(conversationProvider.notifier).send(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final isTest = ref.watch(isTestModeProvider);
    final conversation = ref.watch(conversationProvider);

    return Scaffold(
      appBar: _SkeAppBar(isTest: isTest),
      body: Column(
        children: [
          // Avatar panel
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: AvatarWidget(size: 160)),
          ),
          // Message list
          Expanded(
            child: conversation.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                  child: Text('Error: $e',
                      style: TextStyle(color: c.textSecondary))),
              data: (messages) {
                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      isTest
                          ? 'Test mode: I\'ll quiz you. Ask me anything.'
                          : 'Guide mode: Ask me anything from your KB.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: c.textSecondary,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                _scrollToBottom();
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (_, i) =>
                      _MessageBubble(message: messages[i]),
                );
              },
            ),
          ),
          // Input bar
          _SkeInputBar(
            controller: _controller,
            onSend: _send,
            loading: conversation.isLoading,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom AppBar
// ---------------------------------------------------------------------------

class _SkeAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final bool isTest;
  const _SkeAppBar({required this.isTest});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.appColors;
    return AppBar(
      title: Text('MockMate',
          style: TextStyle(
              color: c.accent,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
      actions: [
        const ThemeToggleButton(),
        IconButton(
          icon: Icon(Icons.settings_outlined, color: c.textSecondary),
          tooltip: 'Settings',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isTest ? 'Test' : 'Guide',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(width: 4),
              Switch(
                value: isTest,
                onChanged: (v) async {
                  ref.read(isTestModeProvider.notifier).state = v;
                  await ref
                      .read(conversationProvider.notifier)
                      .switchMode(v);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Message bubble
// ---------------------------------------------------------------------------

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final isUser = message.role == MessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: isUser
            ? c.raised(radius: 16, color: c.userBubble)
            : c.sunken(radius: 16, color: c.aiBubble),
        child: message.thinking
            ? SizedBox(
                width: 20,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.accent),
              )
            : SelectableText(
                message.text,
                style: TextStyle(
                  color: isUser
                      ? c.textPrimary
                      : c.textPrimary.withValues(alpha: 0.90),
                  fontSize: 14,
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Input bar
// ---------------------------------------------------------------------------

class _SkeInputBar extends ConsumerWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool loading;

  const _SkeInputBar({
    required this.controller,
    required this.onSend,
    required this.loading,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.appColors;
    final audioState = ref.watch(audioStateProvider);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: c.raised(radius: 20),
        child: Row(
          children: [
            // Mic button
            _SkeIconButton(
              icon: audioState == AudioState.listening
                  ? Icons.mic
                  : Icons.mic_none,
              color: audioState == AudioState.listening
                  ? Colors.greenAccent
                  : c.textSecondary,
              pressed: audioState == AudioState.listening,
              onTap: () {
                final notifier = ref.read(audioStateProvider.notifier);
                notifier.state = audioState == AudioState.listening
                    ? AudioState.idle
                    : AudioState.listening;
              },
            ),
            const SizedBox(width: 6),
            // Text field
            Expanded(
              child: Container(
                decoration: c.sunken(radius: 14),
                child: TextField(
                  controller: controller,
                  onSubmitted: (_) => loading ? null : onSend(),
                  style: TextStyle(color: c.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Ask a question…',
                    hintStyle: TextStyle(color: c.textSecondary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Send button
            loading
                ? SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.accent),
                  )
                : _SkeIconButton(
                    icon: Icons.send,
                    color: c.accent,
                    pressed: false,
                    onTap: onSend,
                  ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Icon button
// ---------------------------------------------------------------------------

class _SkeIconButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool pressed;
  final VoidCallback onTap;

  const _SkeIconButton({
    required this.icon,
    required this.color,
    required this.pressed,
    required this.onTap,
  });

  @override
  State<_SkeIconButton> createState() => _SkeIconButtonState();
}

class _SkeIconButtonState extends State<_SkeIconButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final depressed = _down || widget.pressed;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 40,
        height: 40,
        decoration: depressed ? c.sunken(radius: 20) : c.raised(radius: 20),
        child: Icon(widget.icon, color: widget.color, size: 20),
      ),
    );
  }
}
