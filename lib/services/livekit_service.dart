import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

/// Client for the `livekit` Supabase Edge Function (the former nile-backend).
///
/// All calls go through `supabase.functions.invoke`, which attaches the signed-in
/// user's JWT automatically — the Edge Function derives identity from that token,
/// so we never send a userId/viewerId in the body.
class LivekitService {
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
  static Future<LivekitToken> cameraToken({
    required String eventId,
    required String cameraId,
    required String cameraName,
  }) async {
    final d = await _invoke<Map>({
      'action': 'camera-token',
      'eventId': eventId,
      'cameraId': cameraId,
      'cameraName': cameraName,
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

  /// Crew: flag the caller's own feed as ready (or not) during Sound Check.
  /// The Edge Function matches the caller's publisher(s) by the userId in
  /// their token metadata — no identity is sent from the client.
  static Future<void> setReady({
    required String eventId,
    required bool ready,
  }) => _invoke<Map>({'action': 'set-ready', 'eventId': eventId, 'ready': ready});

  /// Host: stamp the show's wall-clock anchor (showStartedAt) into room metadata.
  /// Call alongside EventService.goLive when Start Show is pressed.
  static Future<void> startShow({required String eventId}) =>
      _invoke<Map>({'action': 'start-show', 'eventId': eventId});

  /// Host: stop the replay egress so the recording finalizes. Call when ending
  /// the show. Best-effort — the live show already ended via EventService.end,
  /// and the server-side auto-end + stuck-row sweep cover any missed call.
  static Future<void> stopEgress({required String eventId}) =>
      _invoke<Map>({'action': 'stop-egress', 'eventId': eventId});

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
      );
    } catch (_) {
      return const ReplayAvailability(available: false, authorized: false, hasReplay: false);
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
  static Future<ViewerConnection> viewerToken({required String eventId}) async {
    final d = await _invoke<Map>({
      'action': 'viewer-token',
      'eventId': eventId,
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
  /// `available && !authorized` is exactly the "buy a ticket to watch" case.
  final bool hasReplay;

  const ReplayAvailability({
    required this.available,
    required this.authorized,
    required this.hasReplay,
  });
}
