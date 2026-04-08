import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../audio/audio_provider.dart';
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
    state = AsyncData(
        [...current, ChatMessage(role: MessageRole.user, text: userText)]);
    state = const AsyncLoading<List<ChatMessage>>().copyWithPrevious(state);

    ref.read(audioStateProvider.notifier).state = AudioState.speaking;

    final response = await bridge.chat(userMessage: userText);
    final updated = state.valueOrNull ?? [];
    state = AsyncData([
      ...updated,
      ChatMessage(role: MessageRole.assistant, text: response),
    ]);

    // Synthesise speech, play it, and extract visemes for avatar animation.
    final pcm = await bridge.synthesiseText(text: response);
    if (pcm.isNotEmpty) {
      // Fire-and-forget — audio plays asynchronously while visemes are computed.
      unawaited(bridge.playAudio(pcmBytes: pcm.toList()));
    }
    final visemesJson =
        await bridge.extractVisemes(pcmBytes: pcm.toList());
    ref.read(pendingVisemesProvider.notifier).state = visemesJson;

    // If no visemes (no TTS), go idle immediately.
    if (visemesJson == '[]') {
      ref.read(audioStateProvider.notifier).state = AudioState.idle;
    }
  }

  Future<void> switchMode(bool isTest) async {
    await bridge.setInteractionMode(isTest: isTest);
    state = const AsyncData([]);
  }
}

final conversationProvider =
    AsyncNotifierProvider<ConversationNotifier, List<ChatMessage>>(
  ConversationNotifier.new,
);
