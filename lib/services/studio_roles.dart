import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Who a LiveKit participant is, read from the role in its token metadata.
///
/// Publishers are cameras, the Stream Audio device and the host's desktop
/// Studio (the show's control room — see the `studio-token` action). Viewers
/// only watch. Mirrors PUBLISHER_ROLES in supabase/functions/_shared/studio.ts.
abstract final class NileRole {
  static const camera = 'camera';
  static const streamAudio = 'master-audio';
  static const studio = 'studio';

  /// Interview mode: a remote guest (green room / stage). Not a publisher in
  /// the camera sense — never an angle, never the show's master audio.
  static const guest = 'guest';

  /// The Studio's private talkback connection to the green room.
  static const backstage = 'backstage';

  static bool isPublisher(Object? role) =>
      role == camera || role == streamAudio || role == studio;
}

/// Token metadata as a map; empty when missing or malformed.
Map<String, dynamic> parseParticipantMeta(String? raw) {
  try {
    final m = jsonDecode(raw ?? '{}');
    return m is Map<String, dynamic> ? m : const {};
  } catch (_) {
    return const {};
  }
}

/// The fields the master-audio rule reads from one publisher.
@immutable
class PublisherInfo {
  const PublisherInfo({
    required this.identity,
    required this.role,
    this.isMasterAudio = false,
    this.joinedAt,
  });

  factory PublisherInfo.fromMeta(String identity, Map<String, dynamic> meta) =>
      PublisherInfo(
        identity: identity,
        role: meta['role'] as String?,
        isMasterAudio: meta['isMasterAudio'] == true,
        joinedAt: (meta['joinedAt'] as num?)?.toInt(),
      );

  final String identity;
  final String? role;
  final bool isMasterAudio;
  final int? joinedAt;
}

/// The identity whose audio the show carries.
///
/// One rule everywhere — viewers route to it, cameras and the Studio unmute
/// only if it is them: the publisher holding `isMasterAudio` (the server keeps
/// that to exactly one). With nobody flagged — the holder dropped and hasn't
/// come back — Stream Audio if it is connected, else the earliest camera.
String? resolveMasterAudio(Iterable<PublisherInfo> publishers) {
  final ps = publishers.where((p) => NileRole.isPublisher(p.role)).toList();
  for (final p in ps) {
    if (p.isMasterAudio) return p.identity;
  }
  for (final p in ps) {
    if (p.role == NileRole.streamAudio) return p.identity;
  }
  final cameras = ps.where((p) => p.role == NileRole.camera).toList()
    ..sort((a, b) => (a.joinedAt ?? 0).compareTo(b.joinedAt ?? 0));
  return cameras.firstOrNull?.identity;
}

/// Decides whether a host's phone runs the show or acts as a camera operator.
///
/// While the desktop Studio is in the room it is the master host, so the
/// host's phones hide Start/End Show and offer Ready to Stream instead. When
/// the Studio leaves, the phones wait out a grace period before taking the
/// controls back — a Mac dropping Wi-Fi for a few seconds shouldn't flip every
/// phone's UI mid-show.
class StudioHandover {
  StudioHandover({
    required this.onChange,
    this.grace = const Duration(seconds: 30),
  });

  final VoidCallback onChange;
  final Duration grace;

  bool _present = false;
  Timer? _graceTimer;

  /// True while the Studio is connected, or left less than [grace] ago.
  bool get studioInCharge => _present || _graceTimer != null;

  /// Report whether a Studio participant is in the room right now.
  void update({required bool studioPresent}) {
    final before = studioInCharge;
    if (studioPresent) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _present = true;
    } else if (_present) {
      _present = false;
      _graceTimer = Timer(grace, () {
        _graceTimer = null;
        onChange();
      });
    }
    if (before != studioInCharge) onChange();
  }

  /// Forget everything without notifying — the room is gone.
  void reset() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _present = false;
  }

  void dispose() => reset();
}

/// Short device label sent with a token and shown on the Studio's slot rows.
String nileDeviceLabel(BuildContext context) {
  if (kIsWeb) return 'Web';
  final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => tablet ? 'iPad' : 'iPhone',
    TargetPlatform.android => tablet ? 'Android tablet' : 'Android',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows',
    _ => 'Computer',
  };
}
