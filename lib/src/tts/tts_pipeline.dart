import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bridge.dart' as bridge;
import 'tts_normalizer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// All normalisation logic lives in tts_normalizer.dart (public + testable).
// This file owns only the streaming pipeline.
// ─────────────────────────────────────────────────────────────────────────────

/// Current time as HH:mm:ss.mmm for log timestamps.
String _ts() => DateTime.now().toIso8601String().substring(11, 23);

// Sentence end: period/exclamation/question followed by whitespace or EOL.
final _sentenceBoundary = RegExp(r'[.!?](?:\s|$)', multiLine: true);

// Colon followed by space or end-of-buffer — always flushes with long pause.
final _colonBoundary = RegExp(r':(?:\s|$)');

// Phrase-level boundary used only as a last-resort split point.
final _phraseBoundary = RegExp(r'[,;:]\s');

// Matches a complete phonetic hint: [word](/phonetic/).
final _completeHint = RegExp(r'\[[^\]]+\]\(/[^)]+/\)');

/// True when [buf] contains an open [ that has not yet been closed by /).
bool _hasOpenHint(String buf) {
  final lastOpen = buf.lastIndexOf('[');
  if (lastOpen < 0) return false;
  return !_completeHint.hasMatch(buf.substring(lastOpen));
}

/// True when [buf] has an unclosed code fence (odd number of ``` markers).
bool _insideCodeFence(String buf) =>
    RegExp(r'```').allMatches(buf).length.isOdd;

/// Minimum raw-buffer length before we flush at a sentence boundary.
///
/// Prevents standalone micro-chunks like "1." / "2." / "3." from being
/// synthesised alone — they play in ~1.4 s while the next chunk takes 3 s
/// to synthesise, causing an audible gap. Merging them with the following
/// text keeps the audio queue full.
const _kMinFlushLen = 12;

/// Flush only at natural speech boundaries so Kokoro has full prosodic context.
bool _shouldFlush(String buf) {
  if (_hasOpenHint(buf)) return false;
  if (_insideCodeFence(buf)) return false;
  if (buf.contains('\n\n')) return true;          // paragraph break always flushes
  if (buf.length >= 450) return true;             // MAX_TOKENS guard always flushes
  // If the buffer contains a code block (fence just closed), only paragraph /
  // overflow may flush it — never split it at a colon or sentence boundary,
  // otherwise the code block is torn apart before the normalizer can strip it.
  if (buf.contains('```')) return false;
  // Only flush at a sentence boundary when the buffer is long enough to
  // produce audio that outlasts the next synthesis cycle (~1–3 s).
  if (buf.trimRight().length >= _kMinFlushLen && _sentenceBoundary.hasMatch(buf)) return true;
  if (_colonBoundary.hasMatch(buf)) return true;   // colon always flushes
  return false;
}

/// Receives a stream of raw LLM tokens, batches them into speakable phrases,
/// strips markdown noise, synthesises each phrase, and enqueues audio in order.
/// 80 ms of silence at 24 kHz f32 LE mono = 1920 samples × 4 bytes.
final _silencePadding = List<int>.filled(1920 * 4, 0);

/// 500 ms pause used after code-snippet announcements to signal a context switch.
final _codeSnippetPadding = List<int>.filled(24000 ~/ 2 * 4, 0);

Future<void> run(Stream<String> tokens) async {
  final chunkController = StreamController<String>();

  // Synthesis consumer — runs concurrently with token reading.
  final synthDone = () async {
    await for (final chunk in chunkController.stream) {
      debugPrint('[TTS ${_ts()}] chunk_recv  : $chunk');
      final hasCodeBlock = chunk.contains('```');
      final hasTrailingColon = chunk.trimRight().endsWith(':');
      final clean = cleanForTts(chunk);
      debugPrint('[TTS ${_ts()}] chunk_clean : $clean');
      if (clean.isEmpty) continue;
      debugPrint('[TTS ${_ts()}] synth_start');
      final pcm = await bridge.synthesiseText(text: clean);
      debugPrint('[TTS ${_ts()}] synth_done  : ${pcm.length} bytes');
      if (pcm.isNotEmpty) {
        debugPrint('[TTS ${_ts()}] enqueue_audio');
        unawaited(bridge.playAudio(pcmBytes: pcm.toList()));
        // Longer pause after code blocks or colon introductions; normal gap otherwise.
        final padding = (hasCodeBlock || hasTrailingColon) ? _codeSnippetPadding : _silencePadding;
        unawaited(bridge.playAudio(pcmBytes: padding));
      }
    }
  }();

  final wordBuf = StringBuffer();

  void tryFlush() {
    final buf = wordBuf.toString();
    if (!_shouldFlush(buf)) return;

    // Paragraph break.
    final paraIdx = buf.indexOf('\n\n');
    if (paraIdx >= 0) {
      final pre  = buf.substring(0, paraIdx).trim();
      final post = buf.substring(paraIdx + 2).trimLeft();
      // Too short to synthesise alone — merge with what follows.
      if (pre.length < _kMinFlushLen) {
        wordBuf.clear();
        wordBuf.write(pre.isEmpty ? post : '$pre $post');
        return;
      }
      if (pre.isNotEmpty) chunkController.add(pre);
      wordBuf.clear();
      wordBuf.write(post);
      return;
    }

    // Colon — flush up to and including the colon, remainder continues.
    // Guard: skip if buffer contains a code block (would split it before normalizer strips it).
    if (_colonBoundary.hasMatch(buf) && !buf.contains('```')) {
      final match = _colonBoundary.allMatches(buf).first;
      final toFlush = buf.substring(0, match.start + 1).trim();
      final remaining = buf.substring(match.end).trimLeft();
      if (toFlush.isNotEmpty) chunkController.add(toFlush);
      wordBuf.clear();
      wordBuf.write(remaining);
      return;
    }

    // Sentence end — flush up to and including the last terminal punctuation.
    if (_sentenceBoundary.hasMatch(buf)) {
      final match = _sentenceBoundary.allMatches(buf).last;
      final toFlush = buf.substring(0, match.end).trim();
      final remaining = buf.substring(match.end).trimLeft();
      if (toFlush.isNotEmpty) chunkController.add(toFlush);
      wordBuf.clear();
      wordBuf.write(remaining);
      return;
    }

    // Safety split: prefer phrase boundary, fall back to last word boundary.
    final splitAt = () {
      final m = _phraseBoundary.allMatches(buf).lastOrNull;
      if (m != null) return m.start + 1;
      final sp = buf.lastIndexOf(' ');
      return sp > 0 ? sp : -1;
    }();
    if (splitAt > 0) {
      chunkController.add(buf.substring(0, splitAt).trim());
      wordBuf.clear();
      wordBuf.write(buf.substring(splitAt).trimLeft());
    }
  }

  await for (final token in tokens) {
    wordBuf.write(token);
    tryFlush();
  }

  // Flush trailing text split by sentence.
  if (wordBuf.isNotEmpty) {
    for (final s in wordBuf.toString().split(_sentenceBoundary)) {
      final trimmed = s.trim();
      if (trimmed.isNotEmpty) chunkController.add(trimmed);
    }
  }

  await chunkController.close();
  await synthDone;
}

/// Convenience wrapper — identical signature used by both providers.
abstract class TtsPipeline {
  static Future<void> run(Stream<String> tokens) => _run(tokens);
}

Future<void> _run(Stream<String> tokens) => run(tokens);
