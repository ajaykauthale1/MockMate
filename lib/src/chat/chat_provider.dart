import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bridge/bridge.dart' as bridge;

// ---------------------------------------------------------------------------
// Mode state
// ---------------------------------------------------------------------------

final isTestModeProvider = StateProvider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// Chat message model
// ---------------------------------------------------------------------------

enum MessageRole { user, assistant }

class ChatMessage {
  final MessageRole role;
  final String text;
  const ChatMessage({required this.role, required this.text});
}

// ---------------------------------------------------------------------------
// Conversation notifier
// ---------------------------------------------------------------------------

class ConversationNotifier extends AsyncNotifier<List<ChatMessage>> {
  @override
  Future<List<ChatMessage>> build() async => [];

  Future<void> send(String userText) async {
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, ChatMessage(role: MessageRole.user, text: userText)]);
    state = const AsyncLoading<List<ChatMessage>>().copyWithPrevious(state);

    final response = await bridge.chat(userMessage: userText);
    final updated = state.valueOrNull ?? [];
    state = AsyncData([
      ...updated,
      ChatMessage(role: MessageRole.assistant, text: response),
    ]);
  }

  Future<void> switchMode(bool isTest) async {
    await bridge.setInteractionMode(isTest: isTest);
    // Wipe conversation history — new mode, fresh context.
    state = const AsyncData([]);
  }
}

final conversationProvider =
    AsyncNotifierProvider<ConversationNotifier, List<ChatMessage>>(
  ConversationNotifier.new,
);
