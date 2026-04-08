import 'dart:async';

import '../bridge/bridge.dart' as bridge;

/// Normalise [text] so espeak-ng reads it naturally.
String _cleanForTts(String text) {
  var t = text;

  // ── Markdown / formatting ─────────────────────────────────────────────────
  // Links: [label](url) → label
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
  // Inline code / bold / italic / strikethrough markers
  t = t.replaceAll(RegExp(r'[*_`~]+'), '');
  // Headings
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  // Bullet points
  t = t.replaceAll(RegExp(r'^\s*[-•*]\s+', multiLine: true), '');

  // ── URLs / emails ─────────────────────────────────────────────────────────
  t = t.replaceAll(RegExp(r'https?://\S+'), '');
  t = t.replaceAll(RegExp(r'\S+@\S+\.\S+'), '');

  // ── Numbers & units ───────────────────────────────────────────────────────
  // Percentages: "42%" → "42 percent"
  t = t.replaceAllMapped(RegExp(r'(\d+\.?\d*)%'), (m) => '${m.group(1)} percent');
  // Currency: "$5" / "£10" → "5 dollars" / "10 pounds"
  t = t.replaceAllMapped(RegExp(r'\$(\d+\.?\d*)'), (m) => '${m.group(1)} dollars');
  t = t.replaceAllMapped(RegExp(r'£(\d+\.?\d*)'), (m) => '${m.group(1)} pounds');
  t = t.replaceAllMapped(RegExp(r'€(\d+\.?\d*)'), (m) => '${m.group(1)} euros');
  // Time: "3:45" → "3 45"
  t = t.replaceAllMapped(RegExp(r'\b(\d{1,2}):(\d{2})\b'), (m) => '${m.group(1)} ${m.group(2)}');
  // Single-digit numbers to words for fluency
  const _digits = ['zero','one','two','three','four','five','six','seven','eight','nine'];
  t = t.replaceAllMapped(RegExp(r'\b([0-9])\b'), (m) => _digits[int.parse(m.group(1)!)]);

  // ── Common abbreviations ──────────────────────────────────────────────────
  const _abbr = {
    r'\be\.g\.': 'for example',
    r'\bi\.e\.': 'that is',
    r'\betc\.': 'et cetera',
    r'\bvs\.': 'versus',
    r'\bDr\.': 'Doctor',
    r'\bMr\.': 'Mister',
    r'\bMs\.': 'Miss',
    r'\bProf\.': 'Professor',
    r'\bSr\.': 'Senior',
    r'\bJr\.': 'Junior',
  };
  for (final entry in _abbr.entries) {
    t = t.replaceAll(RegExp(entry.key, caseSensitive: false), entry.value);
  }

  // ── Punctuation cleanup ───────────────────────────────────────────────────
  t = t.replaceAll(RegExp(r'\.{2,}'), '.'); // ellipsis → period
  t = t.replaceAll(RegExp(r'\s*[;:]\s*'), ', ');
  t = t.replaceAll(RegExp(r'\s*—+\s*'), ', ');
  t = t.replaceAll(RegExp(r'\s+-\s+'), ', ');   // "two - three" → "two, three"
  t = t.replaceAll(RegExp(r'\s*-{2,}\s*'), ', ');
  t = t.replaceAll(RegExp(r'[()[\]{}]'), '');

  // ── Whitespace ────────────────────────────────────────────────────────────
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

  return t;
}

final _sentenceBoundary = RegExp(r'[.!?]\s');

/// Returns true when [buf] has accumulated a phrase worth synthesising.
bool _shouldFlush(String buf) {
  if (_sentenceBoundary.hasMatch(buf)) return true;
  if (buf.length >= 80) return true;
  if (buf.trim().split(RegExp(r'\s+')).length >= 10) return true;
  return false;
}

/// Receives a stream of raw LLM tokens, batches them into speakable phrases,
/// strips markdown noise, synthesises each phrase, and enqueues audio in order.
///
/// Token reading is decoupled from synthesis: we never block the LLM stream
/// waiting for ONNX — chunks are queued and synthesised as fast as possible.
///
/// Returns a Future that completes when all audio has been enqueued.
Future<void> run(Stream<String> tokens) async {
  final chunkController = StreamController<String>();

  // Synthesis consumer — runs concurrently with token reading.
  final synthDone = () async {
    await for (final chunk in chunkController.stream) {
      final clean = _cleanForTts(chunk);
      if (clean.isEmpty) continue;
      final pcm = await bridge.synthesiseText(text: clean);
      if (pcm.isNotEmpty) {
        // playAudio enqueues into the AudioPlayer's sequential queue —
        // order is preserved even though we don't await playback completion.
        unawaited(bridge.playAudio(pcmBytes: pcm.toList()));
      }
    }
  }();

  final wordBuf = StringBuffer();

  void tryFlush() {
    final buf = wordBuf.toString();
    if (!_shouldFlush(buf)) return;

    if (_sentenceBoundary.hasMatch(buf)) {
      // Sentence boundary: flush everything.
      wordBuf.clear();
      chunkController.add(buf);
    } else {
      // Length / word-count limit: flush only up to the last space so we
      // never cut a word in half (e.g. "t" | "wo" → espeak reads "T" then "wo").
      final lastSpace = buf.lastIndexOf(' ');
      if (lastSpace > 0) {
        chunkController.add(buf.substring(0, lastSpace));
        wordBuf.clear();
        wordBuf.write(buf.substring(lastSpace + 1));
      }
      // No space found → keep buffering until a boundary appears.
    }
  }

  await for (final token in tokens) {
    wordBuf.write(token);
    tryFlush();
  }

  // Flush any trailing text.
  if (wordBuf.isNotEmpty) {
    chunkController.add(wordBuf.toString());
  }

  await chunkController.close();
  await synthDone;
}

/// Convenience wrapper — identical signature used by both providers.
abstract class TtsPipeline {
  static Future<void> run(Stream<String> tokens) => _run(tokens);
}

Future<void> _run(Stream<String> tokens) => run(tokens);
