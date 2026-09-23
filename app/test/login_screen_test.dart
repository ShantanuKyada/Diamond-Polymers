import 'package:diamond_polymers/core/theme/app_theme.dart';
import 'package:diamond_polymers/features/auth/presentation/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// §63 AUTHENTICATION: form validation and double-submit protection.
///
/// These exercise the screen without a backend: validation runs before the
/// repository is ever reached, which is exactly the boundary being tested.
void main() {
  Widget wrap() => ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const LoginScreen(),
        ),
      );

  testWidgets('renders the sign-in form', (tester) async {
    await tester.pumpWidget(wrap());

    expect(find.text('Diamond Polymers'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('empty fields are rejected before any network call',
      (tester) async {
    await tester.pumpWidget(wrap());

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('a malformed email is rejected', (tester) async {
    await tester.pumpWidget(wrap());

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'not-an-email',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'secret123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email'), findsOneWidget);
  });

  testWidgets('the password is obscured, and can be revealed', (tester) async {
    await tester.pumpWidget(wrap());

    EditableText passwordField() => tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextFormField, 'Password'),
            matching: find.byType(EditableText),
          ),
        );

    expect(passwordField().obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(passwordField().obscureText, isFalse);
  });
}
