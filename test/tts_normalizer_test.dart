import 'package:flutter_test/flutter_test.dart';
import 'package:mockmate/src/tts/tts_normalizer.dart';

void main() {
  // Helper: assert input → expected output (case-insensitive trim).
  void check(String input, String expected) {
    final result = cleanForTts(input);
    expect(
      result,
      expected,
      reason: 'cleanForTts("$input")',
    );
  }

  // ── Pause punctuation ────────────────────────────────────────────────────────
  group('pause punctuation', () {
    test('comma → period pause', () => check('order, and', 'order. and.'));
    test('semicolon → period pause', () => check('first; second', 'first. second.'));
    test('colon → period pause', () => check('result: done', 'result. done.'));
    test('em-dash → period pause', () => check('left — right', 'left. right.'));
    test('double-dash → period pause', () => check('left -- right', 'left. right.'));
    test('spaced dash → period pause', () => check('left - right', 'left. right.'));
    test('number comma not touched', () => check('1,000 items', 'one,000 items.'));
    test('time colon not touched', () => check('at 10:30', 'at 10 30.'));
  });

  // ── Operators ────────────────────────────────────────────────────────────────
  group('operators', () {
    test('== → equals to',  () => check('if a == b', 'if a equals to b.'));
    test('=== → strictly equals', () => check('a === b', 'a strictly equals b.'));
    test('!= → not equals', () => check('a != b', 'a not equals b.'));
    test('!== → strictly not equals', () => check('a !== b', 'a strictly not equals b.'));
    test('<= → less than or equal to', () => check('n <= 5', 'n less than or equal to five.'));
    test('>= → greater than or equal to', () => check('n >= 0', 'n greater than or equal to zero.'));
    test('< → less than', () => check('a < b', 'a less than b.'));
    test('> → greater than', () => check('a > b', 'a greater than b.'));
    test('= → equals', () => check('x = 5', 'x equals five.'));
    test('+= → plus equals', () => check('i += 1', 'i plus equals one.'));
    test('-= → minus equals', () => check('i -= 1', 'i minus equals one.'));
    test('&& → and', () => check('a && b', 'a and b.'));
    test('|| → or', () => check('a || b', 'a or b.'));
    test('** → to the power of', () => check('n**2', 'n to the power of two.'));
    test('* → times', () => check('a * b', 'a times b.'));
    test('=> → goes to', () => check('x => y', 'x goes to y.'));
    test('-> → returns', () => check('fn -> int', 'fn returns int.'));
  });

  // ── Logical NOT ──────────────────────────────────────────────────────────────
  group('logical NOT', () {
    test('!found → not found', () => check('!found', 'not found.'));
    test('!true → not true',   () => check('!true',  'not true.'));
    test('!present → not present', () => check('!present', 'not present.'));
  });

  // ── Increment / decrement ────────────────────────────────────────────────────
  group('increment/decrement', () {
    test('i++ → i plus plus',   () => check('i++', 'i plus plus.'));
    test('i-- → i minus minus', () => check('i--', 'i minus minus.'));
  });

  // ── Array subscript ──────────────────────────────────────────────────────────
  group('array subscript', () {
    test('nums[i] → nums of i',         () => check('nums[i]',    'nums of i.'));
    test('a[0][1] → a of 0 of 1',       () => check('a[0][1]',   'a of zero of one.'));
    test('map[key] → map of key',       () => check('map[key]',   'map of key.'));
  });

  // ── Object dot access ────────────────────────────────────────────────────────
  group('dot access', () {
    test('obj.method → obj dot method', () => check('obj.method', 'obj dot method.'));
    test('list.length → list dot length', () => check('list.length', 'list dot length.'));
  });

  // ── snake_case ───────────────────────────────────────────────────────────────
  group('snake_case', () {
    test('my_var → my var', () => check('my_var', 'my var.'));
    test('two_sum → two sum', () => check('two_sum', 'two sum.'));
  });

  // ── Percent vs modulo ────────────────────────────────────────────────────────
  group('percent vs modulo', () {
    test('50% → 50 percent', () => check('50%', '50 percent.'));
    test('n % 2 → n modulo 2', () => check('n % 2', 'n modulo two.'));
    test('i%2 → i modulo 2',   () => check('i%2',   'i modulo two.'));
  });

  // ── Function calls ───────────────────────────────────────────────────────────
  group('function calls', () {
    test('len(nums) → len of nums',   () => check('len(nums)',   'len of nums.'));
    test('range(n) → range of n',     () => check('range(n)',    'range of n.'));
    test('f(x) → f of x',            () => check('f(x)',        'f of x.'));
  });

  // ── Big-O notation ───────────────────────────────────────────────────────────
  group('Big-O', () {
    test('O(n) → O of n',           () => check('O(n)',        'O of n.'));
    test('O(1) → O of one',         () => check('O(1)',        'O of one.'));
    test('O(n log n) → O of n log n', () => check('O(n log n)', 'O of n log n.'));
    test('O(n^2) → O of n squared', () => check('O(n^2)',      'O of n squared.'));
  });

  // ── Tech terms ───────────────────────────────────────────────────────────────
  group('tech terms', () {
    test('API → A P I',          () => check('use the API',      'use the A P I.'));
    test('SQL → sequel',         () => check('write SQL',        'write sequel.'));
    test('JSON → jay son',       () => check('parse JSON',       'parse jay son.'));
    test('nginx → engine X',     () => check('run nginx',        'run engine X.'));
    test('PostgreSQL phonetic',  () => check('use PostgreSQL',   'use post gres Q L.'));
  });

  // ── Numbers ──────────────────────────────────────────────────────────────────
  group('numbers', () {
    test('single digit → word', () => check('index 0', 'index zero.'));
    test('currency \$',         () => check('\$10 fee', '10 dollars fee.'));
  });

  // ── Trailing stop ────────────────────────────────────────────────────────────
  group('trailing stop', () {
    test('adds period if missing',    () => check('solution',  'solution.'));
    test('keeps existing period',     () => check('done.',     'done.'));
    test('approach gets period',      () => check('approach',  'approach.'));
  });

  // ── Markdown stripping ───────────────────────────────────────────────────────
  group('markdown', () {
    test('bold stripped',       () => check('**bold** text',  'bold text.'));
    test('inline code → clean', () => check('use `my_var`',  'use my var.'));
    test('heading stripped',    () => check('## Title\ntext', 'Title text.'));
    test('url stripped',        () => check('see https://example.com here', 'see here.'));
  });

  // ── Abbreviations ────────────────────────────────────────────────────────────
  group('abbreviations', () {
    test('e.g. → for example', () => check('e.g. arrays',  'for example arrays.'));
    test('i.e. → that is',     () => check('i.e. sorted',  'that is sorted.'));
    test('etc. → et cetera',   () => check('lists, etc.',  'lists. et cetera.'));
  });

  // ── Real-world LLM response ───────────────────────────────────────────────
  group('real-world', () {
    test('two-sum algorithm explanation', () {
      const input = '''
Steps:
1. Initialize an empty dictionary `complements`.
2. Loop through the array with index `i` and value `num`:
   - Calculate the complement: `complement = target - num`
   - Check if `complement` exists in `complements`:
     - If it does, return `[complements[complement], i]`
     - Otherwise, store `num` with index `i` in `complements`.
3. Return the result.

Example Python code:

```python
def two_sum(nums, target):
    complements = {}
    for i, num in enumerate(nums):
        complement = target - num
        if complement in complements:
            return [complements[complement], i]
        complements[num] = i
```

This approach ensures that you find the solution efficiently without needing to sort or use nested loops.
''';
      final result = cleanForTts(input);
      // Code block removed (pipeline handles pause separately).
      expect(result, isNot(contains('def two_sum')));
      // Markdown structure stripped.
      expect(result, isNot(contains('```')));
      expect(result, isNot(contains('##')));
      // Backtick identifiers cleaned.
      expect(result, isNot(contains('`')));
      // Subscript notation (complements[complement] → complements of complement).
      expect(result, contains('complements of complement'));
      // snake_case in inline code expanded (complement = target - num).
      expect(result, contains('complement'));
      // Ends with terminal punctuation.
      expect(result, matches(RegExp(r'[.!?]$')));
    });
  });
}
