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
  StreamController<({String text, int msPerChar})>? _typingQueue;

  @override
  Future<List<ChatMessage>> build() async {
    ref.onDispose(() {
      _cancelled = true;
      _synthQueue?.close();
      _typingQueue?.close();
      bridge.stopAudio();
    });
    return [];
  }

  Future<void> send(String userText) async {
    // Cancel any in-flight TTS/LLM/typing.
    _cancelled = true;
    await _synthQueue?.close();
    _typingQueue?.close();
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

    // All raw tokens accumulated for the TTS-never-fired fallback.
    final tokenBuffer = StringBuffer();
    // Text already committed to screen (no cursor).
    final displayBuffer = StringBuffer();
    var lastQueued = ''; // last char enqueued to typing stream (separator tracking)
    bool firstChunkReady = false;

    void _updateDisplay({bool cursor = false}) {
      if (_cancelled) return;
      final msgs = state.valueOrNull ?? [];
      if (msgs.isEmpty) return;
      state = AsyncData([
        ...msgs.sublist(0, msgs.length - 1),
        ChatMessage(
          role: MessageRole.assistant,
          text: displayBuffer.toString() + (cursor ? '▋' : ''),
          thinking: false,
        ),
      ]);
    }

    // Serial typing consumer: drains jobs one character at a time, each job
    // at its own speed derived from the audio duration of that chunk.
    final typingQueue =
        StreamController<({String text, int msPerChar})>();
    _typingQueue = typingQueue;

    final typingDone = () async {
      await for (final job in typingQueue.stream) {
        for (int i = 0; i < job.text.length; i++) {
          if (_cancelled) return;
          displayBuffer.write(job.text[i]);
          _updateDisplay(cursor: true);
          await Future.delayed(Duration(milliseconds: job.msPerChar));
        }
      }
      if (!_cancelled) _updateDisplay(cursor: false);
    }();

    void revealChunk(String rawChunk, Duration audioDuration) {
      if (_cancelled) return;
      if (!firstChunkReady) firstChunkReady = true;
      final display = _stripPhoneticHintsForDisplay(rawChunk);
      if (display.isEmpty) return;

      // Separator space between chunks (skip after newline).
      final sep = (lastQueued.isNotEmpty && lastQueued != '\n' &&
              !display.startsWith('\n'))
          ? ' '
          : '';
      final toType = sep + display;
      lastQueued = display[display.length - 1];

      // ms per character = audio duration / char count, clamped to sane range.
      final msPerChar = audioDuration.inMilliseconds > 0
          ? (audioDuration.inMilliseconds / toType.length).round().clamp(10, 120)
          : 25;

      if (!typingQueue.isClosed) {
        typingQueue.add((text: toType, msPerChar: msPerChar));
      }
    }

    final synthQueue = StreamController<String>();
    _synthQueue = synthQueue;
    final synthDone = TtsPipeline.run(synthQueue.stream, onChunkReady: revealChunk);

    await for (final token in bridge.chatStream(userMessage: userText)) {
      if (_cancelled) break;
      if (token.startsWith('\nerror:')) break;
      tokenBuffer.write(token);
      if (!synthQueue.isClosed) synthQueue.add(token);
    }

    if (!synthQueue.isClosed) await synthQueue.close();
    await synthDone;

    // Close typing queue and wait for animation to finish.
    if (!typingQueue.isClosed) await typingQueue.close();
    await typingDone;

    // Fallback if TTS never fired (very short response / TTS disabled).
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
