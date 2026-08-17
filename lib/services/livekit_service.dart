import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

/// Client for the `livekit` Supabase Edge Function (the former nile-backend).
///
/// All calls go through `supabase.functions.invoke`, which attaches the signed-in
/// user's JWT automatically — the Edge Function derives identity from that token,
/// so we never send a userId/viewerId in the body.
class LivekitService {
  /// The most viewers one event can admit.
  ///
  /// A LiveKit room holds 1050 participants, but the host, camera operators, a
  /// Stream Audio operator and the egress recorder all take slots — so the
  /// number of seats we can actually honour is lower. Keep in step with
  /// MAX_VIEWERS in supabase/functions/livekit/index.ts and the CHECK
  /// constraint in migration 0105.
  static const int maxViewersPerEvent = 1000;

  static Future<T> _invoke<T>(Map<String, dynamic> body) async {
    try {
      final res = await supabase.functions.invoke('livekit', body: body);
      final data = res.data;
      // 200-with-error-body (the function returns 200 for some soft failures).
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString());
      }
      return data as T;
    } on FunctionException catch (e) {
      // Non-2xx (401/403/404/…): the JSON body is in e.details.
      final details = e.details;
      final msg = details is Map ? details['error']?.toString() : null;
      throw Exception(msg ?? 'livekit function failed (${e.status})');
    }
  }

  /// Host: create the LiveKit room for an event. → { roomName, eventName }
  static Future<void> createRoom({
    required String eventId,
    required String eventName,
  }) => _invoke<Map>({
    'action': 'create-room',
    'eventId': eventId,
    'eventName': eventName,
  });

  /// Host: publisher token for a camera. → (token, wsUrl, isMasterAudio)
  ///
  /// [monitor] asks for subscribe rights so the Studio can show crew feeds.
  /// The server grants it to the host only, and only when asked — a client that
  /// doesn't send it gets a publish-only token, which is what every build
  /// before the Studio relies on (they connect with LiveKit's default
  /// autoSubscribe and would otherwise start pulling feeds they cannot render).
  /// Send it only if you also connect with `autoSubscribe: false`.
  static Future<LivekitToken> cameraToken({
    required String eventId,
    required String cameraId,
    required String cameraName,
    bool monitor = false,
  }) async {
    final d = await _invoke<Map>({
      'action': 'camera-token',
      'eventId': eventId,
      'cameraId': cameraId,
      'cameraName': cameraName,
      if (monitor) 'monitor': true,
    });
    return LivekitToken(
      token: d['token'] as String,
      wsUrl: d['wsUrl'] as String,
      isMasterAudio: d['isMasterAudio'] == true,
    );
  }

  /// Host: audio-only master publisher token. → (token, wsUrl)
  static Future<LivekitToken> audioToken({required String eventId}) async {
    final d = await _invoke<Map>({'action': 'audio-token', 'eventId': eventId});
    return LivekitToken(
      token: d['token'] as String,
      wsUrl: d['wsUrl'] as String,
    );
  }

  /// Host: reassign the master-audio flag across cameras.
  static Future<void> setMasterAudio({
    required String eventId,
    required String cameraIdentity,
  }) => _invoke<Map>({
    'action': 'set-master-audio',
    'eventId': eventId,
    'cameraIdentity': cameraIdentity,
  });

  /// Host: report whether the replay recording actually started.
  ///
  /// Returns false when the egress never came up — misconfigured replay storage
  /// or a LiveKit error. The show is live either way; what changes is that the
  /// host finds out now instead of after the show, with nothing to sell.
  /// Old servers omit the flag; absence is treated as "started", which is the
  /// behaviour that shipped before this existed.
  static Future<bool> startShow({required String eventId}) async {
    final d = await _invoke<Map>({'action': 'start-show', 'eventId': eventId});
    return d['egressStarted'] != false;
  }

  /// Host: disconnect one participant from the live room.
  ///
  /// LiveKit drops them immediately. Whether they can rejoin is decided by the
  /// token gate they next hit — a de-assigned operator and a refunded ticket
  /// holder are both refused there, so for those this is final.
  static Future<void> removeParticipant({
    required String eventId,
    required String identity,
  }) => _invoke<Map>({
    'action': 'remove-participant',
    'eventId': eventId,
    'identity': identity,
  });

  /// Crew: flag the caller's own feed as ready (or not) during Sound Check.
  /// The Edge Function matches the caller's publisher(s) by the userId in
  /// their token metadata — no identity is sent from the client.
  static Future<void> setReady({
    required String eventId,
    required bool ready,
  }) => _invoke<Map>({'action': 'set-ready', 'eventId': eventId, 'ready': ready});

  /// Host: stop the replay egress so the recording finalizes. Call when ending
  /// the show. Best-effort — the live show already ended via EventService.end,
  /// and the server-side auto-end + stuck-row sweep cover any missed call.
  static Future<void> stopEgress({required String eventId}) =>
      _invoke<Map>({'action': 'stop-egress', 'eventId': eventId});

  /// Write the true live viewer count (from LiveKit participants) into the event.
  ///
  /// ⚠️ DEPRECATED for new call sites, and no longer called by the viewer.
  /// Having every viewer drive this on a timer is what made it an O(N²) storm:
  /// N clients each triggering a recount and a write to one hot events row,
  /// which realtime then fanned back out to all N of them. The `livekit-sweep`
  /// cron does it once per live event now and clients simply read the row.
  ///
  /// Kept because builds shipped before that sweep still call it, and it is
  /// harmless at their scale.
  static Future<void> reconcileViewers({
    required String eventId,
    bool excludeSelf = false,
  }) => _invoke<Map>({
    'action': 'reconcile-viewers',
    'eventId': eventId,
    'excludeSelf': excludeSelf,
  });

  /// Viewer: whether a ready replay exists that this user may watch, plus whether
  /// the caller is authorized at all (so a paid event with no ticket can still
  /// surface a "buy to watch the replay" CTA). Returns a falsey default on error.
  static Future<ReplayAvailability> replayExists({required String eventId}) async {
    try {
      final d = await _invoke<Map>({'action': 'replay-exists', 'eventId': eventId});
      return ReplayAvailability(
        available: d['available'] as bool? ?? false,
        authorized: d['authorized'] as bool? ?? false,
        hasReplay: d['hasReplay'] as bool? ?? false,
        published: d['published'] as bool? ?? false,
        replayPrice: (d['replayPrice'] as num?)?.toInt(),
      );
    } catch (_) {
      return const ReplayAvailability(
        available: false,
        authorized: false,
        hasReplay: false,
        published: false,
      );
    }
  }

  /// Viewer: signed playback URL for a ready replay (ticket-gated). Returns null
  /// if no replay is available or the user isn't authorized.
  static Future<ReplayPlayback?> replayUrl({required String eventId}) async {
    try {
      final d = await _invoke<Map>({'action': 'replay-url', 'eventId': eventId});
      final url = d['url'] as String?;
      if (url == null) return null;
      return ReplayPlayback(url: url, durationMs: (d['durationMs'] as num?)?.toInt());
    } catch (_) {
      // 403/404 → no replay for this user; treat as "not available".
      return null;
    }
  }

  /// Viewer: ticket-gated connection descriptor. Identity comes from the JWT.
  /// Today `mode` is always "webrtc"; the seam allows "hls" at much higher scale.
  ///
  /// `lobbySafe` tells the server this client re-mints its token when the event
  /// flips to 'live', so it is safe to withhold subscribe rights during Sound
  /// Check (otherwise ticket holders can hear the rehearsal). Same
  /// capability-flag pattern as [cameraToken]'s `monitor`: a build that predates
  /// the re-mint doesn't send it and keeps the old behaviour, because a token
  /// with no subscribe grant and no re-mint would leave it watching nothing.
  static Future<ViewerConnection> viewerToken({required String eventId}) async {
    final d = await _invoke<Map>({
      'action': 'viewer-token',
      'eventId': eventId,
      'lobbySafe': true,
    });
    return ViewerConnection(
      mode: (d['mode'] as String?) ?? 'webrtc',
      token: d['token'] as String,
      wsUrl: d['wsUrl'] as String,
    );
  }
}

class LivekitToken {
  final String token;
  final String wsUrl;
  final bool isMasterAudio;
  const LivekitToken({
    required this.token,
    required this.wsUrl,
    this.isMasterAudio = false,
  });
}

class ViewerConnection {
  final String mode; // "webrtc" today; "hls" reserved for future scale
  final String token;
  final String wsUrl;
  const ViewerConnection({
    required this.mode,
    required this.token,
    required this.wsUrl,
  });
}

class ReplayPlayback {
  final String url; // short-lived signed URL to the composited replay MP4
  final int? durationMs;
  const ReplayPlayback({required this.url, this.durationMs});
}

class ReplayAvailability {
  /// A ready replay exists AND the caller may watch it now → show "Watch Replay".
  final bool available;

  /// The caller passes the paid-ticket gate (host/operator/ticket or free event).
  final bool authorized;

  /// A ready replay exists for the event, regardless of this caller's access.
  final bool hasReplay;

  /// The host has published the replay (or the 48h cron did). Fans only see a
  /// purchase CTA once this is true; before that only crew can watch.
  final bool published;

  /// Cents. 0 = free, null = not yet priced. `hasReplay && published &&
  /// !authorized` is exactly the "Get Replay — $X" case.
  final int? replayPrice;

  const ReplayAvailability({
    required this.available,
    required this.authorized,
    required this.hasReplay,
    required this.published,
    this.replayPrice,
  });
}
