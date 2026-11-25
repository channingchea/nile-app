import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'supabase_client.dart';

/// Show control (studio-edits plan, phase 5): which angles are off air, where
/// new viewers start, "Send everyone here", and the camera order.
///
/// Lives in the LiveKit room metadata, written by the `set-show` and
/// `reorder-cameras` actions (supabase/functions/_shared/show.ts). Viewers,
/// the Studio and the operator phones all read it from there.
@immutable
class ShowControl {
  const ShowControl({
    this.offAir = const {},
    this.defaultSlot,
    this.sendAll,
    this.slotOrder = const [],
  });

  static const empty = ShowControl();

  /// Slots viewers can't see right now.
  final Set<String> offAir;

  /// Where new viewers start. Null = the first on-air camera.
  final String? defaultSlot;

  /// "Send everyone here": each nonce is acted on once per viewer.
  final ({String slot, int nonce})? sendAll;

  /// Camera order (slot ids). Empty = the order slots were created in.
  final List<String> slotOrder;

  factory ShowControl.fromRoomMetadata(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map ? ShowControl.fromJson(m) : empty;
    } catch (_) {
      return empty;
    }
  }

  factory ShowControl.fromJson(Map m) {
    final off = m['offAir'];
    final order = m['slotOrder'];
    final send = m['sendAll'];
    return ShowControl(
      offAir: off is List ? off.whereType<String>().toSet() : const {},
      defaultSlot: m['defaultSlot'] is String ? m['defaultSlot'] as String : null,
      sendAll: send is Map && send['slot'] is String && send['nonce'] is num
          ? (slot: send['slot'] as String, nonce: (send['nonce'] as num).toInt())
          : null,
      slotOrder: order is List ? order.whereType<String>().toList() : const [],
    );
  }

  bool isOnAir(String? slotId) => slotId == null || !offAir.contains(slotId);

  /// [items] sorted by [slotOrder]; anything not in it keeps its place after
  /// the ordered ones. Stable.
  List<T> ordered<T>(List<T> items, String? Function(T item) slotOf) {
    if (slotOrder.isEmpty) return items;
    final rank = {for (var i = 0; i < slotOrder.length; i++) slotOrder[i]: i};
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    indexed.sort((a, b) {
      final ra = rank[slotOf(a.$2)] ?? slotOrder.length + a.$1;
      final rb = rank[slotOf(b.$2)] ?? slotOrder.length + b.$1;
      return ra != rb ? ra.compareTo(rb) : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// The angle a viewer starts on, from the slots they can see right now (in
  /// display order): the default angle if it is up, else the first on-air
  /// one. Null when nothing is on air.
  String? startSlot(List<String?> available) {
    final onAir = available.where(isOnAir).toList();
    if (defaultSlot != null && onAir.contains(defaultSlot)) return defaultSlot;
    return onAir.firstOrNull;
  }

  /// What a viewer on [watching] should do now. Returns the slot to move to
  /// and why, or null to stay. [seenNonce] is the last sendAll this viewer
  /// already acted on (pass the nonce present when they joined, so joining
  /// late never replays an old "Send everyone").
  ({String slot, ViewerMoveReason reason})? viewerMove({
    required String? watching,
    required List<String?> available,
    required int? seenNonce,
  }) {
    final send = sendAll;
    if (send != null &&
        send.nonce != seenNonce &&
        send.slot != watching &&
        isOnAir(send.slot) &&
        available.contains(send.slot)) {
      return (slot: send.slot, reason: ViewerMoveReason.sendAll);
    }
    if (watching != null && !isOnAir(watching)) {
      final next = startSlot(available);
      if (next != null && next != watching) {
        return (slot: next, reason: ViewerMoveReason.offAir);
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ShowControl &&
      setEquals(other.offAir, offAir) &&
      other.defaultSlot == defaultSlot &&
      other.sendAll == sendAll &&
      listEquals(other.slotOrder, slotOrder);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(offAir),
    defaultSlot,
    sendAll,
    Object.hashAll(slotOrder),
  );
}

enum ViewerMoveReason {
  /// The angle you were on went off air.
  offAir,

  /// The host sent everyone to this angle.
  sendAll,
}

/// Viewers per angle (migration 0134). Viewers report; host and crew read.
class AngleWatchers {
  /// Heartbeat interval for viewers; the counts window is 90 s.
  static const heartbeat = Duration(seconds: 60);

  /// How often the Studio polls the counts.
  static const poll = Duration(seconds: 15);

  /// A viewer on [slotId] (null = an angle with no slot). Best effort.
  static Future<void> report(String eventSlug, String? slotId) async {
    try {
      await supabase.rpc(
        'angle_heartbeat',
        params: {'p_slug': eventSlug, 'p_slot': slotId},
      );
    } catch (_) {}
  }

  /// slotId → viewers seen in the last 90 s. Empty for anyone but the host,
  /// crew and admins; null when the call failed (keep showing the last
  /// counts rather than a row of zeros).
  static Future<Map<String, int>?> counts(String eventSlug) async {
    try {
      final rows = await supabase.rpc(
        'angle_counts',
        params: {'p_slug': eventSlug},
      );
      return {
        for (final r in rows as List)
          (r as Map)['slot_id'] as String: (r['viewers'] as num).toInt(),
      };
    } catch (_) {
      return null;
    }
  }
}
