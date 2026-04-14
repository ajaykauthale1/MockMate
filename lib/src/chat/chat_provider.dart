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
  final bool thinking;
  const ChatMessage({required this.role, required this.text, this.thinking = false});
}

// ---------------------------------------------------------------------------
// Conversation notifier
// ---------------------------------------------------------------------------

class ConversationNotifier extends AsyncNotifier<List<ChatMessage>> {
  bool _cancelled = false;
  StreamController<String>? _synthQueue;

  @override
  Future<List<ChatMessage>> build() async {
    ref.onDispose(() {
      _cancelled = true;
      _synthQueue?.close();
      bridge.stopAudio();
    });
    return [];
  }

  Future<void> send(String userText) async {
    // Cancel any in-flight TTS/LLM.
    _cancelled = true;
    await _synthQueue?.close();
    await bridge.stopAudio();
    _cancelled = false;

    final current = state.valueOrNull ?? [];

    // Add user message + empty assistant placeholder; keep thinking=true until
    // first audio chunk is ready so text and audio start simultaneously.
    state = AsyncData([
      ...current,
      ChatMessage(role: MessageRole.user, text: userText),
      ChatMessage(role: MessageRole.assistant, text: '', thinking: true),
    ]);

    ref.read(audioStateProvider.notifier).state = AudioState.speaking;

    // All raw tokens accumulated for fallback and pre-audio buffering.
    final tokenBuffer = StringBuffer();
    // Display buffer — grows as tokens are revealed.
    final displayBuffer = StringBuffer();
    // Set to true when first audio chunk starts — releases pre-buffered tokens.
    bool firstChunkReady = false;

    void _updateDisplay() {
      if (_cancelled) return;
      final msgs = state.valueOrNull ?? [];
      if (msgs.isEmpty) return;
      state = AsyncData([
        ...msgs.sublist(0, msgs.length - 1),
        ChatMessage(
          role: MessageRole.assistant,
          text: displayBuffer.toString(),
          thinking: false,
        ),
      ]);
    }

    void revealChunk(String rawChunk) {
      if (_cancelled) return;
      if (!firstChunkReady) {
        // First audio chunk ready: flush all pre-buffered tokens to display.
        firstChunkReady = true;
        displayBuffer.write(
            _stripPhoneticHintsForDisplay(tokenBuffer.toString()));
        _updateDisplay();
      }
      // Subsequent chunk boundaries are transparent — tokens stream in real-time.
    }

    final synthQueue = StreamController<String>();
    _synthQueue = synthQueue;
    final synthDone = TtsPipeline.run(synthQueue.stream, onChunkReady: revealChunk);

    await for (final token in bridge.chatStream(userMessage: userText)) {
      if (_cancelled) break;
      if (token.startsWith('\nerror:')) break;
      tokenBuffer.write(token);
      if (!synthQueue.isClosed) synthQueue.add(token);

      // Once first audio chunk is ready, reveal tokens in real-time (typing effect).
      if (firstChunkReady) {
        displayBuffer.write(_stripPhoneticHintsForDisplay(token));
        _updateDisplay();
      }
    }

    if (!synthQueue.isClosed) await synthQueue.close();
    await synthDone;

    // Flush if TTS never fired (very short response / TTS disabled).
    if (!_cancelled) {
      final msgs = state.valueOrNull ?? [];
      if (msgs.isNotEmpty && msgs.last.thinking) {
        state = AsyncData([
          ...msgs.sublist(0, msgs.length - 1),
          ChatMessage(
            role: MessageRole.assistant,
            text: _stripPhoneticHintsForDisplay(tokenBuffer.toString()),
            thinking: false,
          ),
        ]);
      }
    }

    if (!_cancelled) {
      final visemesJson = await bridge.extractVisemes(pcmBytes: []);
      ref.read(pendingVisemesProvider.notifier).state = visemesJson;
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
