// Beta testers reported "Sign up with Apple/Google doesn't show up" on the
// signup screen, then finding it after email confirmation. The buttons were
// never conditional — they sat at the tail of a five-field form and fell below
// the fold on every iPhone, while the two-field login screen still fit them.
//
// The invariant this locks in: on both auth screens the providers render in the
// first screenful, above the email form. Asserting the layout maths rather than
// eyeballing a simulator.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/screens/auth/login_screen.dart';
import 'package:nile_app/screens/auth/signup_screen.dart';

// iPhone 15 logical size, and the smallest phone still supported (SE).
const _iphone15 = Size(393, 852);
const _iphoneSE = Size(375, 667);

Future<void> _pump(WidgetTester tester, Widget screen, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pump();
}

void main() {
  // Apple is iOS-only, and the test host is macOS, so Google is the provider
  // present in every run.
  final google = find.text('Continue with Google');

  group('signup screen', () {
    testWidgets('providers are visible without scrolling', (tester) async {
      await _pump(tester, const SignupScreen(), _iphone15);

      expect(google, findsOneWidget);
      expect(
        tester.getBottomLeft(google).dy,
        lessThan(_iphone15.height),
        reason: 'social buttons fell below the fold again',
      );
    });

    testWidgets('providers sit above the email form', (tester) async {
      await _pump(tester, const SignupScreen(), _iphone15);

      expect(
        tester.getTopLeft(google).dy,
        lessThan(tester.getTopLeft(find.text('Username')).dy),
      );
      // The divider reads as a lead-in to the fields below it.
      expect(find.text('or sign up with email'), findsOneWidget);
    });

    testWidgets('still visible on the smallest supported phone',
        (tester) async {
      await _pump(tester, const SignupScreen(), _iphoneSE);

      expect(tester.getBottomLeft(google).dy, lessThan(_iphoneSE.height));
    });
  });

  group('login screen', () {
    testWidgets('providers sit above the email form', (tester) async {
      await _pump(tester, const LoginScreen(), _iphone15);

      expect(google, findsOneWidget);
      expect(
        tester.getTopLeft(google).dy,
        lessThan(tester.getTopLeft(find.text('Email')).dy),
      );
      expect(find.text('or sign in with email'), findsOneWidget);
    });

    testWidgets('still visible on the smallest supported phone',
        (tester) async {
      await _pump(tester, const LoginScreen(), _iphoneSE);

      expect(tester.getBottomLeft(google).dy, lessThan(_iphoneSE.height));
    });
  });
}
