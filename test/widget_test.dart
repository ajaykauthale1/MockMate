import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockmate/main.dart';

void main() {
  testWidgets('App smoke test — MockMateApp builds', (WidgetTester tester) async {
    await tester.pumpWidget(const MockMateApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
