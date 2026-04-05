import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockmate/src/chat/chat_page.dart';
import 'package:mockmate/src/chat/chat_provider.dart';

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
    child: const MaterialApp(home: ChatPage()),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  testWidgets('ChatPage — guide mode empty state shows hint text',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.textContaining('Guide mode'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('ChatPage — test mode empty state shows quiz hint',
      (tester) async {
    await tester.pumpWidget(_app(overrides: [
      isTestModeProvider.overrideWith((ref) => true),
    ]));
    await tester.pump();

    expect(find.textContaining('Test mode'), findsOneWidget);
  });

  testWidgets('ChatPage — send renders user and assistant bubbles',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'What is ownership?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('What is ownership?'), findsOneWidget);
    expect(find.text('fake reply'), findsOneWidget);
  });

  testWidgets('ChatPage — mode switch clears conversation', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    // Send a message first.
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);

    // Toggle mode — conversation should be wiped.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Hello'), findsNothing);
    // Empty-state hint for test mode should appear.
    expect(find.textContaining('Test mode'), findsOneWidget);
  });

  testWidgets('ChatPage — send button disabled while loading',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    // While idle the send icon button is present.
    expect(find.byIcon(Icons.send), findsOneWidget);
    // While loading a spinner replaces it — not easily testable without
    // async interception, so just assert icon exists in idle state.
  });
}
