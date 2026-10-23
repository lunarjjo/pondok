import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pondok/app.dart';
import 'package:pondok/screens/home_screen.dart';

void main() {
  testWidgets('home screen renders the honest M1 state', (tester) async {
    await tester.pumpWidget(const PondokApp());
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Pondok'), findsOneWidget);
    // The three status cards, in milestone order.
    expect(find.text('Phase 0 complete'), findsOneWidget);
    expect(find.text('Core library onboard'), findsOneWidget);
    expect(find.text('On-device runtime: not installed yet'), findsOneWidget);
    // Badges must state verification truthfully.
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
  });

  testWidgets('theme follows the platform brightness', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const PondokApp());
    await tester.pumpAndSettle();
    expect(
      (tester.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!.brightness),
      Brightness.dark,
    );
  });
}
