import 'dart:async';

import '../bridge/bridge.dart' as bridge;

/// Normalise [text] so espeak-ng reads it naturally.
String _cleanForTts(String text) {
  var t = text;

  // ── 0. Phonetic hint syntax: [word](/phonetic/) → phonetic ────────────────
  // Must run BEFORE the generic markdown-link stripper below.
  t = t.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\(/([^)/]+)/\)'),
    (m) => m.group(2)!,
  );

  // ── Markdown / formatting ─────────────────────────────────────────────────
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
  t = t.replaceAll(RegExp(r'[*_`~]+'), '');
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-•*]\s+', multiLine: true), '');

  // ── URLs / emails ─────────────────────────────────────────────────────────
  t = t.replaceAll(RegExp(r'https?://\S+'), '');
  t = t.replaceAll(RegExp(r'\S+@\S+\.\S+'), '');

  // ── Unicode paren normalisation (LLM fullwidth forms) ─────────────────────
  t = t.replaceAll('（', '(').replaceAll('）', ')');

  // ── Technical term dictionary ─────────────────────────────────────────────
  // Rewrite terms to a form espeak-ng phonemises correctly.
  const _techTerms = {
    r'\bPostgreSQL\b': 'post gres Q L',
    r'\bKubernetes\b': 'koo ber net eez',
    r'\bNaN\b': 'N A N',
    r'\bJSON\b': 'jay son',
    r'\bSQL\b': 'sequel',
    r'\bJWT\b': 'J W T',
    r'\bOAuth\b': 'O auth',
    r'\b[Nn]ginx\b': 'engine X',
    r'\bGraphQL\b': 'graph Q L',
    r'\bRedis\b': 'red iss',
    r'\bYAML\b': 'yam el',
    // Acronyms — spaced letters force espeak-ng to spell them out.
    r'\bHTTPS\b': 'H T T P S',
    r'\bHTTP\b': 'H T T P',
    r'\bAPI\b': 'A P I',
    r'\bCLI\b': 'C L I',
    r'\bGUI\b': 'G U I',
    r'\bSDK\b': 'S D K',
    r'\bURL\b': 'U R L',
    r'\bURI\b': 'U R I',
    r'\bCPU\b': 'C P U',
    r'\bGPU\b': 'G P U',
    r'\bRAM\b': 'R A M',
    r'\bIDE\b': 'I D E',
    r'\bCSS\b': 'C S S',
    r'\bHTML\b': 'H T M L',
    r'\bXML\b': 'X M L',
    r'\bTCP\b': 'T C P',
    r'\bUDP\b': 'U D P',
    r'\bDNS\b': 'D N S',
    r'\bSSH\b': 'S S H',
    r'\bSSL\b': 'S S L',
    r'\bTLS\b': 'T L S',
    r'\bUX\b': 'U X',
    r'\bUI\b': 'U I',
  };
  for (final entry in _techTerms.entries) {
    t = t.replaceAll(RegExp(entry.key), entry.value);
  }

  // ── "Thanks" fix — espeak-ng splits the final /s/ as a separate phoneme ───
  t = t.replaceAll(RegExp(r'\bThanks\b'), 'Thank you');
  t = t.replaceAll(RegExp(r'\bthanks\b'), 'thank you');

  // ── Superscripts (standalone) ─────────────────────────────────────────────
  t = t.replaceAll('²', ' squared').replaceAll('³', ' cubed');
  t = t.replaceAllMapped(RegExp(r'\bn\^(\d)\b'), (m) {
    final exp = m.group(1);
    if (exp == '2') return 'n squared';
    if (exp == '3') return 'n cubed';
    return 'n to the $exp';
  });

  // ── Big-O / complexity notation ───────────────────────────────────────────
  // Explicit patterns first so they win over the generic fallback.
  const _bigO = <String, String>{
    r'O\(1\)': 'O of one',
    r'O\(n\)': 'O of n',
    r'O\(log n\)': 'O of log n',
    r'O\(n log n\)': 'O of n log n',
    r'O\(n\^?2\)': 'O of n squared',
    r'O\(n²\)': 'O of n squared',
    r'O\(n\^?3\)': 'O of n cubed',
    r'O\(n³\)': 'O of n cubed',
    r'Θ\(': 'theta of ',
    r'Ω\(': 'omega of ',
  };
  for (final entry in _bigO.entries) {
    t = t.replaceAll(RegExp(entry.key), entry.value);
  }
  // Generic fallback: single-letter prefix like T(n) → "T of n"
  t = t.replaceAllMapped(
    RegExp(r'\b([A-Za-z])\(([^)]+)\)'),
    (m) => '${m.group(1)} of ${m.group(2)}',
  );
  // Remaining brackets / braces
  t = t.replaceAll(RegExp(r'[()[\]{}]'), '');

  // ── Numbers & units ───────────────────────────────────────────────────────
  t = t.replaceAllMapped(RegExp(r'(\d+\.?\d*)%'), (m) => '${m.group(1)} percent');
  t = t.replaceAllMapped(RegExp(r'\$(\d+\.?\d*)'), (m) => '${m.group(1)} dollars');
  t = t.replaceAllMapped(RegExp(r'£(\d+\.?\d*)'), (m) => '${m.group(1)} pounds');
  t = t.replaceAllMapped(RegExp(r'€(\d+\.?\d*)'), (m) => '${m.group(1)} euros');
  t = t.replaceAllMapped(RegExp(r'\b(\d{1,2}):(\d{2})\b'), (m) => '${m.group(1)} ${m.group(2)}');
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
  t = t.replaceAll(RegExp(r'\s*;\s*'), '; ');
  t = t.replaceAll(RegExp(r'\s*:\s*'), ': ');
  t = t.replaceAll(RegExp(r'\s*—+\s*'), ', ');
  t = t.replaceAll(RegExp(r'\s+-\s+'), ', ');
  t = t.replaceAll(RegExp(r'\s*-{2,}\s*'), ', ');

  // ── Whitespace ────────────────────────────────────────────────────────────
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

  return t;
}

final _sentenceBoundary = RegExp(r'[.!?]\s');

// Commas, semicolons, colons — phrase-level pauses that espeak-ng honours.
final _phraseBoundary = RegExp(r'[,;:]\s');

// Matches a complete phonetic hint: [word](/phonetic/).
final _completeHint = RegExp(r'\[[^\]]+\]\(/[^)]+/\)');

/// True when [buf] contains an open [ that has not yet been closed by /).
/// Prevents flushing a buffer while a cross-token phonetic hint is incomplete.
bool _hasOpenHint(String buf) {
  final lastOpen = buf.lastIndexOf('[');
  if (lastOpen < 0) return false;
  return !_completeHint.hasMatch(buf.substring(lastOpen));
}

/// Returns true when [buf] has accumulated a phrase worth synthesising.
/// Longer thresholds (~350 chars / 25 words) give Kokoro more prosodic context,
/// producing smoother, less robotic delivery.
bool _shouldFlush(String buf) {
  // Never flush while a phonetic hint spans a token boundary.
  if (_hasOpenHint(buf)) return false;
  if (_sentenceBoundary.hasMatch(buf)) return true;
  final words = buf.trim().split(RegExp(r'\s+'));
  if (_phraseBoundary.hasMatch(buf) && words.length >= 8) return true;
  if (buf.length >= 350) return true;
  if (words.length >= 25) return true;
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
      // Sentence end: flush everything.
      wordBuf.clear();
      chunkController.add(buf);
    } else if (_phraseBoundary.hasMatch(buf)) {
      // Phrase boundary (,;:): flush up to and including the last boundary so
      // espeak-ng receives the punctuation and generates a natural pause.
      final match = _phraseBoundary.allMatches(buf).last;
      final toFlush = buf.substring(0, match.start + 1); // include punctuation
      final remaining = buf.substring(match.end);         // skip trailing space
      chunkController.add(toFlush);
      wordBuf.clear();
      wordBuf.write(remaining);
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
