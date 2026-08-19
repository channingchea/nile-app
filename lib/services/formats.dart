import 'package:intl/intl.dart';

/// Locale-aware date, time and number formatting.
///
/// P4 #41. Before this, every screen hand-rolled its own:
///
///     const m = ['Jan', 'Feb', ...];
///     final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
///     final ampm = dt.hour < 12 ? 'AM' : 'PM';
///
/// — ten copies of the same twenty lines across the app. That isn't only a
/// duplication problem. It hardcodes American conventions for everyone: a
/// 24-hour-clock locale still saw "9:00 PM", "Jun 21" never became "21 Jun",
/// and a large number was printed without separators because nobody wrote that
/// part twice.
///
/// intl reads the ambient locale, so these produce the right shape per user
/// without any per-screen branching — and they'll keep doing so when a second
/// locale is added, without revisiting ten files.
///
/// Kept deliberately small: these are the shapes Nile actually uses. A helper
/// nobody calls is a translation nobody checks.
class NileFormats {
  NileFormats._();

  /// "Jun 21" — a date without a year, for things happening soon.
  static String dayMonth(DateTime dt, [String? locale]) =>
      DateFormat.MMMd(locale).format(dt);

  /// "Jun 21, 2026" — when the year matters (receipts, past events).
  static String dayMonthYear(DateTime dt, [String? locale]) =>
      DateFormat.yMMMd(locale).format(dt);

  /// "9:00 PM", or "21:00" where that's the convention.
  static String time(DateTime dt, [String? locale]) =>
      DateFormat.jm(locale).format(dt);

  /// "Fri" — short weekday.
  static String weekday(DateTime dt, [String? locale]) =>
      DateFormat.E(locale).format(dt);

  /// "Tue, Jun 21", or with the year when it isn't the current one.
  static String weekdayDayMonth(DateTime dt,
          {bool withYear = false, String? locale}) =>
      (withYear ? DateFormat.yMMMEd(locale) : DateFormat.MMMEd(locale))
          .format(dt);

  /// "Jun 21, 2026 · 9:00 PM" — a full timestamp for schedules and receipts.
  static String dayMonthYearTime(DateTime dt, [String? locale]) =>
      '${dayMonthYear(dt, locale)} · ${time(dt, locale)}';

  /// "Jun 21 · 9:00 PM". The separator is ours, not the locale's, because it's
  /// a visual device rather than a date convention.
  static String dayMonthTime(DateTime dt, [String? locale]) =>
      '${dayMonth(dt, locale)} · ${time(dt, locale)}';

  /// "Fri · 9:00 PM" for something within the coming week, "Jun 21 · 9:00 PM"
  /// beyond it. [now] is injectable so the boundary is testable without
  /// racing the clock.
  static String upcoming(DateTime dt, {DateTime? now, String? locale}) {
    final today = now ?? DateTime.now();
    final days = dt.difference(DateTime(today.year, today.month, today.day)).inDays;
    return days >= 0 && days < 7
        ? '${weekday(dt, locale)} · ${time(dt, locale)}'
        : dayMonthTime(dt, locale);
  }

  /// "Jun 21, 9:00 PM" — the long form used in lists of past activity.
  static String dateTime(DateTime dt, [String? locale]) =>
      DateFormat.MMMd(locale).add_jm().format(dt);

  /// Thousands separators, per locale: 1,234 or 1.234 or 1 234.
  static String count(num value, [String? locale]) =>
      NumberFormat.decimalPattern(locale).format(value);

  /// Compact counts for dense UI: 1.2K, 3.4M.
  static String compactCount(num value, [String? locale]) =>
      NumberFormat.compact(locale: locale).format(value);
}
