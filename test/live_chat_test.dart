// Live chat moderation, phase 1 (P1 #16).
//
// Chat now has a server-side record, so a message can carry an id and be
// removed later. The awkward part is that the app has to keep working against
// three kinds of payload at once: messages from the new server path (with an
// id), messages from builds still broadcasting directly (no id), and forged
// system announcements. These lock in that contract — the rate limiter and the
// length cap are enforced in Postgres and the edge function and are verified
// there, not here.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/chat_service.dart';
import 'package:nile_app/services/report_service.dart';

Map<String, dynamic> _payload({String? id, String kind = 'user'}) => {
  'id': ?id,
  'sender_id': 'u1',
  'username': 'someone',
  'content': 'hello',
  'sent_at': DateTime.utc(2026, 8, 17, 12).toIso8601String(),
  'kind': kind,
};

void main() {
  group('ChatMessage', () {
    test('carries the server id when the message came through live-chat', () {
      final m = ChatMessage.fromJson(_payload(id: 'm-1'));
      expect(m.id, 'm-1');
      expect(m.toJson()['id'], 'm-1');
    });

    test('parses a message with no id — every build in the field on day one', () {
      // Shipped clients broadcast straight to the channel and send no id. If
      // this ever throws, chat goes silent for everyone who hasn't updated.
      final m = ChatMessage.fromJson(_payload());
      expect(m.id, isNull);
      expect(m.content, 'hello');
      expect(m.toJson().containsKey('id'), isFalse);
    });

    test('a system payload on the chat topic is recognisable as forged', () {
      // subscribe() drops these rather than rendering them in the announcement
      // style — only the service role may author on live_system.
      expect(ChatMessage.fromJson(_payload(kind: 'system')).isSystem, isTrue);
      expect(ChatMessage.fromJson(_payload()).isSystem, isFalse);
    });

    test('a garbled payload degrades instead of throwing', () {
      final m = ChatMessage.fromJson({'sent_at': 'not-a-date'});
      expect(m.senderId, '');
      expect(m.username, 'viewer');
      expect(m.content, '');
      expect(m.kind, 'user');
    });
  });

  group('send limits', () {
    test('the composer truncates well inside the server cap', () {
      // viewer_screen cuts at 250; the function refuses over
      // maxMessageLength. The gap is deliberate — a legitimate client should
      // never be the thing that trips the backstop.
      expect(250, lessThan(ChatService.maxMessageLength));
      expect(ChatService.maxMessageLength, 500);
    });
  });

  group('report target', () {
    test('every multi-word target serializes to its DB spelling', () {
      // ReportTargetTypeX falls through to Dart's `name` for single-word
      // values, which means a new multi-word one silently sends camelCase and
      // is rejected by the enum cast at insert time — a report that looks
      // filed and never lands.
      expect(ReportTargetType.liveChatMessage.dbValue, 'live_chat_message');
      expect(ReportTargetType.currentComment.dbValue, 'current_comment');
      expect(ReportTargetType.post.dbValue, 'post');
      for (final t in ReportTargetType.values) {
        expect(t.dbValue, matches(RegExp(r'^[a-z_]+$')), reason: '$t');
      }
    });
  });

  group('ChatSendException', () {
    test('reads as the server wording, with no Exception: prefix', () {
      // The message goes straight into a snackbar, so toString() leaking
      // "Exception: " would be user-visible.
      const e = ChatSendException("You're sending messages too quickly");
      expect(e.message, "You're sending messages too quickly");
      expect(e.toString(), "You're sending messages too quickly");
    });
  });
}
