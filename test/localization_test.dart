import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nile_app/l10n/app_localizations.dart';
import 'package:nile_app/services/formats.dart';

/// P4 #41. Two different things are being defended here.
///
/// The scaffolding works — .arb compiles, plurals resolve, delegates are
/// reachable — so adding a second locale is a config change rather than a
/// project.
///
/// And the hand-rolled date code doesn't come back. Ten screens each had their
/// own `const m = ['Jan', ...]` and their own AM/PM arithmetic, which is what
/// made "the app doesn't respect your locale" a fifty-file problem instead of
/// a one-file one.
void main() {
  setUpAll(() async {
    // intl needs symbol data for any locale other than the process default.
    await initializeDateFormatting();
  });

  group('string catalogue', () {
    test('English strings load and interpolate', () {
      final l = lookupAppLocalizations(const Locale('en'));
      expect(l.appTitle, 'Nile');
      expect(l.ticketRefundPolicyShort(24), contains('24 hours'));
      expect(l.cancelTicketBody('\$12.00 USD', 'Sunday Service'),
          contains('Sunday Service'));
    });

    test('plurals actually pluralise', () {
      // The reason likeCount is an ICU plural and not '$n like${n == 1 ? "" : "s"}'
      // is that the second form cannot be translated into a language with
      // more than two plural categories.
      final l = lookupAppLocalizations(const Locale('en'));
      expect(l.likeCount(0), '0 likes');
      expect(l.likeCount(1), '1 like');
      expect(l.likeCount(2), '2 likes');
    });

    test('every supported locale is actually delegated', () {
      expect(AppLocalizations.supportedLocales, isNotEmpty);
      expect(AppLocalizations.localizationsDelegates, isNotEmpty);
      for (final locale in AppLocalizations.supportedLocales) {
        expect(AppLocalizations.delegate.isSupported(locale), isTrue,
            reason: '$locale is listed but the delegate refuses it');
      }
    });
  });

  group('NileFormats', () {
    final dt = DateTime(2026, 6, 21, 21, 5); // Sunday 21 June 2026, 21:05

    // CLDR separates the time from AM/PM with a NARROW NO-BREAK SPACE, not an
    // ordinary one, so "PM" can never wrap onto its own line. It is invisible
    // in a diff, so it is named here rather than pasted into the expectations.
    const nb = '\u202f';

    test('formats an American locale the way it always did', () {
      expect(NileFormats.dayMonth(dt, 'en_US'), 'Jun 21');
      expect(NileFormats.time(dt, 'en_US'), '9:05${nb}PM');
      expect(NileFormats.dayMonthYear(dt, 'en_US'), 'Jun 21, 2026');
    });

    test('and stops imposing it on everyone else', () {
      // This is the actual bug: a 24-hour-clock locale used to be shown
      // "9:05 PM" because the AM/PM was computed by hand.
      expect(NileFormats.time(dt, 'en_GB'), '21:05');
      expect(NileFormats.dayMonth(dt, 'en_GB'), '21 Jun');
    });

    test('counts get locale-appropriate separators', () {
      expect(NileFormats.count(1234567, 'en_US'), '1,234,567');
      expect(NileFormats.count(1234567, 'de'), '1.234.567');
    });

    test('upcoming() switches shape at the one-week boundary', () {
      // `now` is injected so the boundary is asserted exactly rather than
      // racing the clock — same reason canCancelTicket takes one.
      final now = DateTime(2026, 6, 21, 12);
      expect(NileFormats.upcoming(DateTime(2026, 6, 23, 21, 5),
          now: now, locale: 'en_US'), 'Tue · 9:05${nb}PM');
      expect(NileFormats.upcoming(DateTime(2026, 7, 30, 21, 5),
          now: now, locale: 'en_US'), 'Jul 30 · 9:05${nb}PM');
    });
  });

  test('no new hand-rolled month tables', () {
    // The pattern that made this a fifty-file problem. NileFormats exists so
    // nobody needs to write it again; this fails the moment somebody does.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // Skip the generated catalogue, which legitimately contains month names,
      // and formats.dart, whose doc comment quotes the pattern it replaced.
      if (file.path.contains('/l10n/')) continue;
      if (file.path.endsWith('services/formats.dart')) continue;
      final source = file.readAsStringSync();
      if (RegExp(r"'Jan'\s*,\s*\n?\s*'Feb'").hasMatch(source) ||
          source.contains("'Jan', 'Feb', 'Mar'")) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'use NileFormats instead of a literal month table:\n  '
            '${offenders.join('\n  ')}');
  });
}
