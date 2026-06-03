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
  }) =>
      _invoke<Map>({'action': 'create-room', 'eventId': eventId, 'eventName': eventName});

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
    return LivekitToken(token: d['token'] as String, wsUrl: d['wsUrl'] as String);
  }

  /// Host: reassign the master-audio flag across cameras.
  static Future<void> setMasterAudio({
    required String eventId,
    required String cameraIdentity,
  }) =>
      _invoke<Map>({
        'action': 'set-master-audio',
        'eventId': eventId,
        'cameraIdentity': cameraIdentity,
      });

  /// Viewer: ticket-gated connection descriptor. Identity comes from the JWT.
  /// Today `mode` is always "webrtc"; the seam allows "hls" at much higher scale.
  static Future<ViewerConnection> viewerToken({required String eventId}) async {
    final d = await _invoke<Map>({'action': 'viewer-token', 'eventId': eventId});
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
  const LivekitToken({required this.token, required this.wsUrl, this.isMasterAudio = false});
}

class ViewerConnection {
  final String mode; // "webrtc" today; "hls" reserved for future scale
  final String token;
  final String wsUrl;
  const ViewerConnection({required this.mode, required this.token, required this.wsUrl});
}
