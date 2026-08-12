import 'dart:convert';

import 'package:share_plus/share_plus.dart';

import 'event_service.dart';
import 'share_urls.dart';

/// Builds and shares iCalendar (.ics) "add to calendar" files for events.
///
/// Shared via the system share sheet so the user can open it in any calendar
/// app. Only meaningful for events with a [Event.scheduledAt].
class CalendarIcs {
  CalendarIcs._();

  /// Whether an "Add to calendar" affordance makes sense for [e].
  ///
  /// `status != 'ended'` let a ticket holder export a past no-show to their
  /// calendar, and allowed drafts through — a host could put an unpublished
  /// event on someone's calendar.
  static bool canAdd(Event e) =>
      e.scheduledAt != null && !e.isDraft && !e.isOver;

  /// The raw .ics file contents for [e].
  static String build(Event e) {
    final start = e.scheduledAt!.toUtc();
    final end = (e.endAt ?? e.scheduledAt!.add(const Duration(hours: 1)))
        .toUtc();
    final url = ShareUrls.event(e.id);
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Nile//Nile App//EN',
      'BEGIN:VEVENT',
      'UID:${e.id}@${ShareUrls.shareDomain}',
      'DTSTAMP:${_fmt(DateTime.now().toUtc())}',
      'DTSTART:${_fmt(start)}',
      'DTEND:${_fmt(end)}',
      'SUMMARY:${_escape(e.title)}',
      'DESCRIPTION:${_escape('Live on Nile — hosted by @${e.hostUsername}. Watch: $url')}',
      'URL:$url',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return lines.map(_fold).join('\r\n');
  }

  /// Builds the .ics for [e] and opens the system share sheet.
  static Future<void> share(Event e) async {
    final file = XFile.fromData(
      utf8.encode(build(e)),
      mimeType: 'text/calendar',
      name: '${_slug(e.title)}.ics',
    );
    await Share.shareXFiles([file], subject: e.title);
  }

  // ── iCalendar formatting helpers ────────────────────────────────────────────

  /// UTC timestamp: 20260610T193000Z
  static String _fmt(DateTime d) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p(d.month)}${p(d.day)}T${p(d.hour)}${p(d.minute)}${p(d.second)}Z';
  }

  /// RFC 5545 text escaping.
  static String _escape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\n', '\\n');

  /// RFC 5545 line folding: max 75 octets, continuation lines start with a space.
  static String _fold(String line) {
    if (line.length <= 75) return line;
    final out = StringBuffer(line.substring(0, 75));
    var i = 75;
    while (i < line.length) {
      final end = (i + 74).clamp(0, line.length);
      out.write('\r\n ${line.substring(i, end)}');
      i = end;
    }
    return out.toString();
  }

  static String _slug(String s) {
    final cleaned = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'(^-+|-+$)'), '');
    return cleaned.isEmpty ? 'event' : cleaned;
  }
}
