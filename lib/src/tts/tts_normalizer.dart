/// Text normalisation for espeak-ng / Kokoro TTS.
///
/// All logic lives here so it can be unit-tested without any Flutter or Rust
/// dependencies.  [tts_pipeline.dart] simply calls [cleanForTts].
library;

// ═══════════════════════════════════════════════════════════════════════════════
// Lookup tables  (top-level so they are compiled once, not per-call)
// ═══════════════════════════════════════════════════════════════════════════════

/// Tech terms & acronyms → phonetic spellings espeak-ng handles correctly.
const _kTechTerms = <String, String>{
  r'\bPostgreSQL\b': 'post gres Q L',
  r'\bKubernetes\b': 'koo ber net eez',
  r'\bNaN\b':        'N A N',
  r'\bJSON\b':       'jay son',
  r'\bSQL\b':        'sequel',
  r'\bJWT\b':        'J W T',
  r'\bOAuth\b':      'O auth',
  r'\b[Nn]ginx\b':   'engine X',
  r'\bGraphQL\b':    'graph Q L',
  r'\bRedis\b':      'red iss',
  r'\bYAML\b':       'yam el',
  r'\bHTTPS\b': 'H T T P S',
  r'\bHTTP\b':  'H T T P',
  r'\bAPI\b':   'A P I',
  r'\bCLI\b':   'C L I',
  r'\bGUI\b':   'G U I',
  r'\bSDK\b':   'S D K',
  r'\bURL\b':   'U R L',
  r'\bURI\b':   'U R I',
  r'\bCPU\b':   'C P U',
  r'\bGPU\b':   'G P U',
  r'\bRAM\b':   'R A M',
  r'\bIDE\b':   'I D E',
  r'\bCSS\b':   'C S S',
  r'\bHTML\b':  'H T M L',
  r'\bXML\b':   'X M L',
  r'\bTCP\b':   'T C P',
  r'\bUDP\b':   'U D P',
  r'\bDNS\b':   'D N S',
  r'\bSSH\b':   'S S H',
  r'\bSSL\b':   'S S L',
  r'\bTLS\b':   'T L S',
  r'\bUX\b':    'U X',
  r'\bUI\b':    'U I',
};

/// Big-O / complexity patterns (longest / most-specific first).
const _kBigO = <String, String>{
  r'O\(n log n\)': 'O of n log n',
  r'O\(log n\)':   'O of log n',
  r'O\(n\^?2\)':   'O of n squared',
  r'O\(n²\)':      'O of n squared',
  r'O\(n\^?3\)':   'O of n cubed',
  r'O\(n³\)':      'O of n cubed',
  r'O\(n\)':       'O of n',
  r'O\(1\)':       'O of one',
  r'Θ\(':          'theta of ',
  r'Ω\(':          'omega of ',
};

/// Common abbreviations.
const _kAbbreviations = <String, String>{
  r'\be\.g\.':   'for example',
  r'\bi\.e\.':   'that is',
  r'\betc\.':    'et cetera',
  r'\bvs\.':     'versus',
  r'\bDr\.':     'Doctor',
  r'\bMr\.':     'Mister',
  r'\bMs\.':     'Miss',
  r'\bProf\.':   'Professor',
  r'\bSr\.':     'Senior',
  r'\bJr\.':     'Junior',
};

/// Operator / symbol → spoken form.
/// IMPORTANT: longer / more-specific tokens must appear before their prefixes.
const _kOperators = <String, String>{
  // Compound assignment (before bare = or arithmetic ops)
  '+=':  'plus equals',
  '-=':  'minus equals',
  '*=':  'times equals',
  '/=':  'divided by equals',
  // Strict equality (before == and !=)
  '!==': 'strictly not equals',
  '===': 'strictly equals',
  // Comparison multi-char (before bare = > <)
  '!=':  'not equals',
  '==':  'equals to',
  '<=':  'less than or equal to',
  '>=':  'greater than or equal to',
  // Arrow operators (before bare = and >)
  '=>':  'goes to',
  '->':  'returns',
  // Bare single-char comparison / assignment
  '<':   'less than',
  '>':   'greater than',
  '=':   'equals',
  // Logical
  '&&':  'and',
  '||':  'or',
  // Unicode math
  '≈':   'approximately equals',
  '~=':  'approximately equals',
  '≠':   'not equals',
  '≤':   'less than or equal to',
  '≥':   'greater than or equal to',
  '∞':   'infinity',
  '±':   'plus or minus',
  '√':   'square root of',
};

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

String _applyRegexMap(String t, Map<String, String> map, {bool caseSensitive = true}) {
  for (final entry in map.entries) {
    t = t.replaceAll(RegExp(entry.key, caseSensitive: caseSensitive), entry.value);
  }
  return t;
}

String _applyLiteralMap(String t, Map<String, String> map) {
  for (final entry in map.entries) {
    t = t.replaceAll(entry.key, entry.value);
  }
  return t;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase functions
// ═══════════════════════════════════════════════════════════════════════════════

String _stripPhoneticHints(String t) => t.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(/([^)/]+)/\)'),
      (m) => m.group(2)!,
    );

String _stripMarkdown(String t) {
  t = t.replaceAll(r'\n', ' ').replaceAll(r'\t', ' ').replaceAll(r'\r', ' ');
  t = t.replaceAll(RegExp(r'```[^\n]*\n[\s\S]*?```'), ' ');
  t = t.replaceAll(RegExp(r'^#{1,6}\s*',                     multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*_]{3,}\s*$',             multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*\|[-|\s:]+\|\s*$',          multiLine: true), '');
  t = t.replaceAllMapped(
    RegExp(r'^\s*\|(.+)\|\s*$', multiLine: true),
    (m) => m.group(1)!.split('|').map((c) => c.trim()).join(', '),
  );
  t = t.replaceAll(RegExp(r'^\s*-\s+\[[ xX]\]\s+',          multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-•*]\s+',                  multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*\d+[.)]\s+',                multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*>\s*',                       multiLine: true), '');
  t = t.replaceAll(RegExp(r'<[^>]{1,40}>'),                                   '');
  t = t.replaceAllMapped(
    RegExp(r'`([^`\n]+)`'),
    // Replace `_` and hyphenated-word separators (my-var → my var) but leave
    // spaced arithmetic minus (target - num) intact for the code-syntax phase.
    (m) => m.group(1)!
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp(r'(\w)-(\w)'), (h) => '${h.group(1)} ${h.group(2)}'),
  );
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
  t = t.replaceAllMapped(RegExp(r'\*{1,3}([^*\n]+)\*{1,3}'), (m) => m.group(1)!);
  t = t.replaceAllMapped(RegExp(r'_{1,2}([^_\n]+)_{1,2}'),   (m) => m.group(1)!);
  t = t.replaceAllMapped(RegExp(r'~~([^~\n]+)~~'),             (m) => m.group(1)!);
  // * and _ are handled in code-syntax phase; only strip remaining ` and ~ here.
  t = t.replaceAll(RegExp(r'[`~]+'), '');
  t = t.replaceAll(RegExp(r'https?://\S+'), '');
  t = t.replaceAll(RegExp(r'\S+@\S+\.\S+'), '');
  t = t.replaceAll('（', '(').replaceAll('）', ')');
  t = t.replaceAllMapped(
    RegExp(r"(?<!\w)'([A-Za-z])'(?!\w)"),
    (m) => 'the letter ${m.group(1)!.toUpperCase()}',
  );
  // Strip terminal punctuation from inside quotes before removing the quotes.
  // "Two Sum." → "Two Sum" → Two Sum  (avoids an unwanted pause mid-sentence).
  t = t.replaceAllMapped(
    RegExp(r'"([^"]{1,60})"'),
    (m) => m.group(1)!.replaceAll(RegExp(r'[.!?]+$'), ''),
  );
  t = t.replaceAll('"', ' ');
  return t;
}

String _normalizeCodeSyntax(String t) {
  // Arithmetic operators — must run before markdown stray-marker stripping
  // removes bare `*` characters. Spaces ensure no token merging (n**2 → n to the power of 2).
  t = t.replaceAll('**', ' to the power of ');
  t = t.replaceAll('*', ' times ');

  t = t.replaceAllMapped(RegExp(r'(\w+)\+\+'), (m) => '${m.group(1)} plus plus');
  t = t.replaceAllMapped(RegExp(r'(\w+)--'),   (m) => '${m.group(1)} minus minus');
  // Arithmetic minus: `word - word` → `word minus word`.
  // Must run before _normalizePunctuation which converts spaced dashes to pauses,
  // silently dropping the operator (e.g. "target - num" was read as "target num").
  t = t.replaceAllMapped(
    RegExp(r'(\w)\s+-\s+(\w)'),
    (m) => '${m.group(1)} minus ${m.group(2)}',
  );
  t = t.replaceAll('_', ' ');
  t = t.replaceAllMapped(
    RegExp(r'\b(\w+)\.(\w+)\b'),
    (m) => '${m.group(1)} dot ${m.group(2)}',
  );
  t = t.replaceAllMapped(RegExp(r'(?<!\d)\s*%\s*'), (_) => ' modulo ');
  t = t.replaceAllMapped(RegExp(r'!(\w)'), (m) => 'not ${m.group(1)}');
  return t;
}

String _expandSymbols(String t) {
  t = _applyRegexMap(t, _kTechTerms);
  t = _applyRegexMap(t, _kBigO);
  t = t.replaceAll('²', ' squared').replaceAll('³', ' cubed');
  t = t.replaceAllMapped(RegExp(r'\bn\^(\d)\b'), (m) {
    return switch (m.group(1)) {
      '2' => 'n squared',
      '3' => 'n cubed',
      final e => 'n to the $e',
    };
  });
  t = t.replaceAllMapped(
    RegExp(r'\b([A-Za-z])\(([^)]+)\)'),
    (m) => '${m.group(1)} of ${m.group(2)}',
  );
  t = t.replaceAllMapped(
    RegExp(r'\b([A-Za-z ]\w*)\(([^)]*)\)'),
    (m) => '${m.group(1)} of ${m.group(2)}',
  );
  for (var pass = 0; pass < 3; pass++) {
    final before = t;
    t = t.replaceAllMapped(
      RegExp(r'(\w[\w ]*)\[([^\]]+)\]'),
      (m) => '${m.group(1)} of ${m.group(2)}',
    );
    if (t == before) break;
  }
  t = t.replaceAll(RegExp(r'[()[\]{}]'), '');
  t = _applyLiteralMap(t, _kOperators);
  return t;
}

String _expandNumbers(String t) {
  t = t.replaceAllMapped(RegExp(r'(\d+\.?\d*)%'), (m) => '${m.group(1)} percent');
  t = t.replaceAllMapped(RegExp(r'\$(\d+\.?\d*)'), (m) => '${m.group(1)} dollars');
  t = t.replaceAllMapped(RegExp(r'£(\d+\.?\d*)'), (m) => '${m.group(1)} pounds');
  t = t.replaceAllMapped(RegExp(r'€(\d+\.?\d*)'), (m) => '${m.group(1)} euros');
  t = t.replaceAllMapped(
    RegExp(r'\b(\d{1,2}):(\d{2})\b'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );
  const digits = ['zero','one','two','three','four','five','six','seven','eight','nine'];
  t = t.replaceAllMapped(
    RegExp(r'\b([0-9])\b'),
    (m) => digits[int.parse(m.group(1)!)],
  );
  return t;
}

String _expandAbbreviations(String t) =>
    _applyRegexMap(t, _kAbbreviations, caseSensitive: false);

String _normalizePunctuation(String t) {
  t = t.replaceAllMapped(RegExp(r'(?<!\d),(?!\d)\s+'), (_) => '. ');
  t = t.replaceAll(RegExp(r'\s*;\s*'),                          '. ');
  t = t.replaceAllMapped(RegExp(r'(?<!\d):(\s+|$)'),   (_) => '. '); // also catches trailing ':'
  t = t.replaceAll(RegExp(r'\s*—+\s*'),                         '. ');
  t = t.replaceAll(RegExp(r'\s*-{2,}\s*'),                      '. ');
  t = t.replaceAll(RegExp(r'\s+-\s+'),                          '. ');
  return t;
}

String _finalizeWhitespace(String t) {
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isNotEmpty && !RegExp(r'[.!?]$').hasMatch(t)) t = '$t.';
  return t;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════════

/// Normalise [text] so espeak-ng / Kokoro reads it naturally.
///
/// Exposed publicly so it can be unit-tested without Flutter or Rust deps.
String cleanForTts(String text) {
  var t = text;
  t = _stripPhoneticHints(t);   // 0 – phonetic hints (before markdown stripper)
  t = _stripMarkdown(t);         // 1 – markdown / formatting noise
  t = _expandAbbreviations(t);  // 2 – e.g./i.e. before dot-access transforms them
  t = _normalizeCodeSyntax(t);  // 3 – context-sensitive code patterns
  t = _expandSymbols(t);        // 4 – tech terms, Big-O, operators
  t = _expandNumbers(t);        // 5 – numbers & currency
  t = _normalizePunctuation(t); // 6 – pause punctuation → '.'
  t = _finalizeWhitespace(t);   // 7 – collapse whitespace + trailing stop
  return t;
}
