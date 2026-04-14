import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../avatar/avatar_widget.dart';
import '../../chat/chat_provider.dart';
import '../../theme/ske_theme.dart';
import '../interview_provider.dart';

class InterviewerPanel extends ConsumerStatefulWidget {
  const InterviewerPanel({super.key});

  @override
  ConsumerState<InterviewerPanel> createState() => _InterviewerPanelState();
}

class _InterviewerPanelState extends ConsumerState<InterviewerPanel> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    await ref.read(interviewProvider.notifier).sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final state = ref.watch(interviewProvider);
    final messages = state.visibleMessages;
    final locked = state.sessionState != SessionState.active;

    // Scroll when new messages arrive
    ref.listen<InterviewState>(interviewProvider, (prev, next) {
      if ((prev?.messages.length ?? 0) < next.messages.length) {
        _scrollToBottom();
      }
    });

    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(left: BorderSide(color: c.borderLight)),
      ),
      child: Column(
        children: [
          // Avatar
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: AvatarWidget(size: 100)),
          ),
          Divider(color: c.borderLight, height: 1),
          // Transcript
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'Waiting for interviewer…',
                      style: TextStyle(
                          color: c.textSecondary, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(10),
                    itemCount:
                        messages.length + (state.aiThinking ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (state.aiThinking && i == messages.length) {
                        return _ThinkingBubble(c: c);
                      }
                      final msg = messages[i];
                      return _Bubble(
                        text: msg.text,
                        isUser: msg.role == MessageRole.user,
                        c: c,
                      );
                    },
                  ),
          ),
          Divider(color: c.borderLight, height: 1),
          // Input
          if (!locked)
            _InputBar(
              controller: _ctrl,
              onSend: _send,
              loading: state.aiThinking,
              c: c,
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final AppColors c;
  const _Bubble({required this.text, required this.isUser, required this.c});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.32),
        decoration: isUser
            ? c.raised(radius: 12, color: c.userBubble)
            : c.sunken(radius: 12, color: c.aiBubble),
        child: SelectableText(
          text,
          style: TextStyle(color: c.textPrimary, fontSize: 12),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  final AppColors c;
  const _ThinkingBubble({required this.c});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: SizedBox(
          width: 32,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.accent),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool loading;
  final AppColors c;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.loading,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: c.sunken(radius: 10),
              child: TextField(
                controller: controller,
                onSubmitted: (_) => loading ? null : onSend(),
                style: TextStyle(color: c.textPrimary, fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Ask the interviewer…',
                  hintStyle: TextStyle(color: c.textSecondary, fontSize: 12),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                maxLines: null,
                textInputAction: TextInputAction.send,
              ),
            ),
          ),
          const SizedBox(width: 6),
          loading
              ? SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: c.accent),
                )
              : GestureDetector(
                  onTap: onSend,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: c.raised(radius: 16),
                    child: Icon(Icons.send, color: c.accent, size: 16),
                  ),
                ),
        ],
      ),
    );
  }
}
