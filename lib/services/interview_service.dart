import 'package:supabase_flutter/supabase_flutter.dart';

import 'interview.dart';
import 'share_urls.dart';
import 'supabase_client.dart';

/// The guest list and the host's private notes (0147). Writes to the guest
/// list go through the livekit function (`LivekitService.inviteGuest`,
/// `moveGuest`, …); this is the read side plus notes.
abstract final class InterviewService {
  /// The share link a host sends to guests.
  static String guestUrl(String code) =>
      'https://${ShareUrls.shareDomain}/g/$code';

  /// Everyone on the guest list (removed guests too, last), host only.
  static Future<List<InterviewGuest>> guests(String eventPk) async {
    final rows = await supabase
        .from('event_guests')
        .select(InterviewGuest.select)
        .eq('event_id', eventPk)
        .order('created_at');
    final out = [
      for (final r in rows as List)
        InterviewGuest.fromRow(Map<String, dynamic>.from(r as Map)),
    ];
    out.sort(
      (a, b) => (a.status == GuestStatus.removed ? 1 : 0).compareTo(
        b.status == GuestStatus.removed ? 1 : 0,
      ),
    );
    return out;
  }

  /// The signed-in user's own invitation to [eventPk], if any.
  static Future<InterviewGuest?> myInvite(String eventPk) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await supabase
        .from('event_guests')
        .select(InterviewGuest.select)
        .eq('event_id', eventPk)
        .eq('user_id', uid)
        .maybeSingle();
    return row == null ? null : InterviewGuest.fromRow(row);
  }

  /// Calls [onChange] whenever the guest list for [eventPk] changes. Re-read
  /// with [guests]; the payload doesn't carry the profile join.
  static RealtimeChannel watch(String eventPk, void Function() onChange) =>
      supabase
          .channel('event_guests:$eventPk')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'event_guests',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'event_id',
              value: eventPk,
            ),
            callback: (_) => onChange(),
          )
          .subscribe();

  static Future<String> notes(String eventPk) async {
    final row = await supabase
        .from('event_host_notes')
        .select('body')
        .eq('event_id', eventPk)
        .maybeSingle();
    return row?['body'] as String? ?? '';
  }

  static Future<void> saveNotes(String eventPk, String body) =>
      supabase.from('event_host_notes').upsert({
        'event_id': eventPk,
        'host_id': supabase.auth.currentUser!.id,
        'body': body,
      });
}
