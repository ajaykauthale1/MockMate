import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Placeholder home renders text', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('MockMate — Phase 1'))),
      ),
    );
    expect(find.text('MockMate — Phase 1'), findsOneWidget);
  });
}
