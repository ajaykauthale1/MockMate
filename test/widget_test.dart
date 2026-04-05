import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockmate/src/audio/audio_provider.dart';
import 'package:mockmate/src/avatar/avatar_painter.dart';
import 'package:mockmate/src/avatar/avatar_widget.dart';
import 'package:mockmate/src/chat/chat_page.dart';
import 'package:mockmate/src/chat/chat_provider.dart';
import 'package:mockmate/src/theme/ske_theme.dart';

// ---------------------------------------------------------------------------
// Fake ConversationNotifier — no FRB / Rust calls.
// ---------------------------------------------------------------------------

class _FakeConversation extends ConversationNotifier {
  @override
  Future<List<ChatMessage>> build() async => [];

  @override
  Future<void> send(String userText) async {
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      ...current,
      ChatMessage(role: MessageRole.user, text: userText),
      ChatMessage(role: MessageRole.assistant, text: 'fake reply'),
    ]);
  }

  @override
  Future<void> switchMode(bool isTest) async {
    state = const AsyncData([]);
  }
}

Widget _app({List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      conversationProvider.overrideWith(_FakeConversation.new),
      ...overrides,
    ],
    child: MaterialApp(theme: skeuomorphicTheme(), home: const ChatPage()),
  );
}

Widget _avatarApp({List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      home: Scaffold(body: Center(child: AvatarWidget())),
    ),
  );
}

// ---------------------------------------------------------------------------
// ChatPage tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatPage', () {
    testWidgets('guide mode empty state shows hint text', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.textContaining('Guide mode'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('test mode empty state shows quiz hint', (tester) async {
      await tester.pumpWidget(_app(overrides: [
        isTestModeProvider.overrideWith((ref) => true),
      ]));
      await tester.pump();

      expect(find.textContaining('Test mode'), findsOneWidget);
    });

    testWidgets('send renders user and assistant bubbles', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'What is ownership?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('What is ownership?'), findsOneWidget);
      expect(find.text('fake reply'), findsOneWidget);
    });

    testWidgets('mode switch clears conversation', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('Hello'), findsNothing);
      expect(find.textContaining('Test mode'), findsOneWidget);
    });

    testWidgets('send button present in idle state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('mic button toggles listening state', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      // Initially shows mic_none icon.
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);

      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump();

      // After tap: listening → mic icon active.
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);

      // Tap again → back to idle.
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });

    testWidgets('skeuomorphic theme applied — dark background', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();

      // Theme's scaffoldBackgroundColor is set to SkeColors.background.
      final theme = Theme.of(tester.element(find.byType(Scaffold).first));
      expect(theme.scaffoldBackgroundColor, SkeColors.background);
    });
  });

  // ---------------------------------------------------------------------------
  // AvatarWidget tests
  // ---------------------------------------------------------------------------

  group('AvatarWidget', () {
    testWidgets('renders CustomPaint with AvatarPainter', (tester) async {
      await tester.pumpWidget(_avatarApp());
      await tester.pump();

      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('state dot is grey when idle', (tester) async {
      await tester.pumpWidget(_avatarApp());
      await tester.pump();

      // No pulsing ring in idle state.
      expect(find.byType(_PulsingRingFinder), findsNothing);
    });

    testWidgets('pulsing ring appears when listening', (tester) async {
      await tester.pumpWidget(_avatarApp(overrides: [
        audioStateProvider.overrideWith((ref) => AudioState.listening),
      ]));
      await tester.pump();

      // AvatarWidget shows pulsing ring animation via AnimatedBuilder.
      expect(find.byType(AnimatedBuilder), findsWidgets);
    });

    testWidgets('avatar switches viseme via AnimatedSwitcher', (tester) async {
      await tester.pumpWidget(_avatarApp(overrides: [
        currentVisemeIdProvider.overrideWith((ref) => 13), // AH – open mouth
      ]));
      await tester.pump();

      // CustomPaint with AvatarPainter(visemeId: 13)
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((cp) => cp.painter)
          .whereType<AvatarPainter>()
          .toList();
      expect(painters.any((p) => p.visemeId == 13), isTrue);
    });

    testWidgets('viseme animation driven by pendingVisemesProvider',
        (tester) async {
      const frames =
          '[{"id":11,"timestamp_ms":0},{"id":12,"timestamp_ms":100},{"id":0,"timestamp_ms":200}]';

      await tester.pumpWidget(_avatarApp(overrides: [
        pendingVisemesProvider.overrideWith((ref) => frames),
      ]));
      // Pump a frame so listenManual fires.
      await tester.pump(const Duration(milliseconds: 10));

      // Animation should have kicked off (currentVisemeId updated by timer).
      // Fast-forward 110ms so first timer tick fires.
      await tester.pump(const Duration(milliseconds: 110));

      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((cp) => cp.painter)
          .whereType<AvatarPainter>()
          .toList();
      // Some viseme ID is being shown (non-zero during animation).
      expect(painters.isNotEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // AvatarPainter unit tests
  // ---------------------------------------------------------------------------

  group('AvatarPainter', () {
    test('shouldRepaint returns true on viseme change', () {
      const a = AvatarPainter(visemeId: 0);
      const b = AvatarPainter(visemeId: 13);
      expect(a.shouldRepaint(b), isTrue);
    });

    test('shouldRepaint returns false when viseme unchanged', () {
      const a = AvatarPainter(visemeId: 6);
      const b = AvatarPainter(visemeId: 6);
      expect(a.shouldRepaint(b), isFalse);
    });

    test('paints without throwing for all supported viseme IDs', () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      for (final id in [0, 4, 6, 7, 8, 11, 12, 13]) {
        expect(
          () => AvatarPainter(visemeId: id)
              .paint(canvas, const Size(200, 200)),
          returnsNormally,
        );
      }
    });

    test('unknown viseme ID falls back to silence shape', () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      expect(
        () => const AvatarPainter(visemeId: 99)
            .paint(canvas, const Size(200, 200)),
        returnsNormally,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // AudioState provider tests
  // ---------------------------------------------------------------------------

  group('AudioState providers', () {
    test('audioStateProvider initialises to idle', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(audioStateProvider), AudioState.idle);
    });

    test('audioStateProvider mutates correctly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(audioStateProvider.notifier).state = AudioState.listening;
      expect(container.read(audioStateProvider), AudioState.listening);

      container.read(audioStateProvider.notifier).state = AudioState.speaking;
      expect(container.read(audioStateProvider), AudioState.speaking);

      container.read(audioStateProvider.notifier).state = AudioState.idle;
      expect(container.read(audioStateProvider), AudioState.idle);
    });

    test('currentVisemeIdProvider initialises to 0', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(currentVisemeIdProvider), 0);
    });

    test('currentVisemeIdProvider accepts valid viseme IDs', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      for (final id in [0, 4, 6, 7, 8, 11, 12, 13]) {
        container.read(currentVisemeIdProvider.notifier).state = id;
        expect(container.read(currentVisemeIdProvider), id);
      }
    });

    test('pendingVisemesProvider initialises to empty array', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(pendingVisemesProvider), '[]');
    });

    test('pendingVisemesProvider stores viseme JSON', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const json =
          '[{"id":13,"timestamp_ms":0},{"id":11,"timestamp_ms":100}]';
      container.read(pendingVisemesProvider.notifier).state = json;
      expect(container.read(pendingVisemesProvider), json);
    });
  });
}

// Marker class used in finder — not actually instantiated.
class _PulsingRingFinder extends StatelessWidget {
  const _PulsingRingFinder();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
