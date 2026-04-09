import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../audio/audio_provider.dart';
import '../bridge/bridge.dart' as bridge;
import '../tts/tts_pipeline.dart';

// ---------------------------------------------------------------------------
// Phonetic hint helpers
// ---------------------------------------------------------------------------

/// Replace [word](/phonetic/) with `word` for chat bubble display.
String _stripPhoneticHintsForDisplay(String text) =>
    text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(/[^)]+/\)'),
      (m) => m.group(1)!,
    );

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

    // Add user message + empty assistant placeholder for streaming.
    state = AsyncData([
      ...current,
      ChatMessage(role: MessageRole.user, text: userText),
      ChatMessage(role: MessageRole.assistant, text: ''),
    ]);

    ref.read(audioStateProvider.notifier).state = AudioState.speaking;

    final fullBuffer = StringBuffer();
    final synthQueue = StreamController<String>();
    final synthDone = TtsPipeline.run(synthQueue.stream);

    await for (final token in bridge.chatStream(userMessage: userText)) {
      if (token.startsWith('\nerror:')) break;
      fullBuffer.write(token);

      // Display path: strip phonetic hints so the chat bubble shows only the
      // visible word, not the [word](/phonetic/) markup.
      final displayText = _stripPhoneticHintsForDisplay(fullBuffer.toString());

      final msgs = state.valueOrNull ?? [];
      state = AsyncData([
        ...msgs.sublist(0, msgs.length - 1),
        ChatMessage(role: MessageRole.assistant, text: displayText),
      ]);

      // TTS path: raw token — _cleanForTts in the pipeline extracts the
      // phonetic form from [word](/phonetic/) before sending to espeak-ng.
      synthQueue.add(token);
    }

    await synthQueue.close();
    await synthDone;

    final visemesJson = await bridge.extractVisemes(pcmBytes: []);
    ref.read(pendingVisemesProvider.notifier).state = visemesJson;
    ref.read(audioStateProvider.notifier).state = AudioState.idle;
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
