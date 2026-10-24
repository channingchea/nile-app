import 'package:supabase_flutter/supabase_flutter.dart';
import 'live_elements.dart';
import 'overlay_layout.dart';
import 'studio_graphics.dart';
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

  /// Host/crew: publisher token for a camera. → [LivekitToken]
  ///
  /// [monitor] asks for subscribe rights so the Studio can show crew feeds.
  /// The server grants it to the host only, and only when asked — a client that
  /// doesn't send it gets a publish-only token, which is what every build
  /// before the Studio relies on (they connect with LiveKit's default
  /// autoSubscribe and would otherwise start pulling feeds they cannot render).
  /// Send it only if you also connect with `autoSubscribe: false`.
  ///
  /// [slotId] is the camera slot picked in "Which camera is this?"; the server
  /// refuses it (409) if another device holds it. Without it the server uses
  /// the caller's crew assignment, then the first open slot. The token's
  /// [LivekitToken.cameraName] is the slot's label when a slot was resolved.
  static Future<LivekitToken> cameraToken({
    required String eventId,
    required String cameraId,
    required String cameraName,
    bool monitor = false,
    String? slotId,
    String? device,
  }) async {
    final d = await _invoke<Map>({
      'action': 'camera-token',
      'eventId': eventId,
      'cameraId': cameraId,
      'cameraName': cameraName,
      if (monitor) 'monitor': true,
      'slotId': ?slotId,
      'device': ?device,
    });
    return LivekitToken.fromJson(d, fallbackName: cameraName);
  }

  /// Host: audio-only master publisher token. → (token, wsUrl)
  static Future<LivekitToken> audioToken({
    required String eventId,
    String? device,
  }) async {
    final d = await _invoke<Map>({
      'action': 'audio-token',
      'eventId': eventId,
      'device': ?device,
    });
    return LivekitToken.fromJson(d);
  }

  /// Host: the desktop Studio joins as the show's control room — not a
  /// camera, subscribe rights on. One per event: a second Studio evicts the
  /// first. Connect with `autoSubscribe: false`.
  static Future<LivekitToken> studioToken({
    required String eventId,
    String? device,
  }) async {
    final d = await _invoke<Map>({
      'action': 'studio-token',
      'eventId': eventId,
      'device': ?device,
    });
    return LivekitToken.fromJson(d, fallbackName: 'Studio');
  }

  /// Host (Studio): turn the Studio's own webcam on or off. Turning it on
  /// counts toward the event's cameras (refused when full) and takes the first
  /// open slot. Call BEFORE publishing the camera; returns the slot label.
  static Future<String> studioCamera({
    required String eventId,
    required bool enabled,
  }) async {
    final d = await _invoke<Map>({
      'action': 'studio-camera',
      'eventId': eventId,
      'enabled': enabled,
    });
    return d['cameraName'] as String? ?? 'Studio';
  }

  /// Host/crew: the event's camera slots and who is on each.
  static Future<CameraSlots> listSlots({required String eventId}) async {
    final d = await _invoke<Map>({'action': 'list-slots', 'eventId': eventId});
    return CameraSlots(
      slots: [
        for (final s in (d['slots'] as List? ?? const []))
          CameraSlot.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
      streamAudioTaken: d['streamAudioTaken'] == true,
    );
  }

  /// Host (Studio): rename a camera on the fly. With [slotId] the slot keeps
  /// the name for the rest of the event; [identity] alone renames a feed that
  /// has no slot.
  static Future<void> renameCamera({
    required String eventId,
    required String name,
    String? slotId,
    String? identity,
  }) => _invoke<Map>({
    'action': 'rename-camera',
    'eventId': eventId,
    'name': name,
    'slotId': ?slotId,
    'identity': ?identity,
  });

  /// Studio: put graphics on (or take them off) the air. Sends the whole
  /// on-air state; the server validates it, enforces the caps and writes it
  /// to the room metadata every viewer reads.
  ///
  /// [srcAgeMs]: how old the Studio's own picture is, when known — viewers
  /// further behind hold the change back to match.
  static Future<void> setGraphics({
    required String eventId,
    required GraphicsState graphics,
    int? srcAgeMs,
  }) => _invoke<Map>({
    'action': 'set-graphics',
    'eventId': eventId,
    'studio': true,
    'graphics': graphics.toJson(),
    'srcAgeMs': ?srcAgeMs,
  });

  /// Studio: push one live element (its next [LiveElement.version]) with any
  /// clock commands. Returns the element as stored — clocks stamped by the
  /// server. Throws [ElementStale] when the server holds a newer version.
  static Future<LiveElement> setElement({
    required String eventId,
    required LiveElement element,
    Map<String, ClockOp> clockOps = const {},
    int? srcAgeMs,
  }) async {
    final body = {
      'action': 'set-element',
      'eventId': eventId,
      'studio': true,
      'element': {
        ...element.toJson(),
        if (clockOps.isNotEmpty)
          'clockOps': {
            for (final e in clockOps.entries) e.key: e.value.toJson(),
          },
        'srcAgeMs': ?srcAgeMs,
      },
    };
    try {
      final res = await supabase.functions.invoke('livekit', body: body);
      final stored = LiveElement.fromJson((res.data as Map)['element']);
      if (stored == null) throw Exception('Unexpected reply');
      return stored;
    } on FunctionException catch (e) {
      final d = e.details;
      if (e.status == 409 && d is Map && d['error'] == 'stale') {
        throw ElementStale(LiveElement.fromJson(d['current']));
      }
      throw Exception(
        (d is Map ? d['error']?.toString() : null) ??
            'livekit function failed (${e.status})',
      );
    }
  }

  /// Studio: take an element out of the show entirely (its live values go).
  static Future<void> removeElement({
    required String eventId,
    required String id,
  }) => _invoke<Map>({
    'action': 'set-element',
    'eventId': eventId,
    'studio': true,
    'remove': id,
  });

  /// Studio: every element's live state in this show, on air or not.
  static Future<List<LiveElement>> listElements({
    required String eventId,
  }) async {
    final d = await _invoke<Map>({
      'action': 'list-elements',
      'eventId': eventId,
    });
    return [
      for (final j in (d['elements'] as List? ?? const []))
        ?LiveElement.fromJson(j),
    ];
  }

  /// Studio: where graphics and elements sit on each camera.
  static Future<void> setLayout({
    required String eventId,
    required OverlayLayout layout,
    int? srcAgeMs,
  }) => _invoke<Map>({
    'action': 'set-layout',
    'eventId': eventId,
    'studio': true,
    'layout': layout.toJson(),
    'srcAgeMs': ?srcAgeMs,
  });

  /// Show control: off-air angles, the default angle, "Send everyone here".
  /// Partial — pass only what changes. Host only.
  static Future<void> setShow({
    required String eventId,
    List<String>? offAir,
    String? defaultSlot,
    bool clearDefault = false,
    String? sendAll,
  }) => _invoke<Map>({
    'action': 'set-show',
    'eventId': eventId,
    'offAir': ?offAir,
    if (defaultSlot != null || clearDefault) 'defaultSlot': defaultSlot,
    'sendAll': ?sendAll,
  });

  /// New camera order (every slot id once). Default "Camera N" names follow
  /// their new position. Host only.
  static Future<void> reorderCameras({
    required String eventId,
    required List<String> order,
  }) => _invoke<Map>({
    'action': 'reorder-cameras',
    'eventId': eventId,
    'order': order,
  });

  /// Re-align every viewer's camera with the show audio. Once per 10 s.
  /// [studio]: see [startShow] — a host phone can only resync when no Studio
  /// is in the room.
  static Future<void> resync({required String eventId, bool studio = false}) =>
      _invoke<Map>({
        'action': 'resync',
        'eventId': eventId,
        if (studio) 'studio': true,
      });

  /// RealSync clock ping: when the server received the request and when it
  /// answered, in server ms.
  static Future<({int receivedAt, int sentAt})> serverClock() async {
    final d = await _invoke<Map>({'action': 'clock'});
    return (
      receivedAt: (d['receivedAt'] as num).toInt(),
      sentAt: (d['sentAt'] as num).toInt(),
    );
  }

  /// RealSync: record this publisher's clock offset (device − server) in its
  /// metadata so viewers can put every sender on one timeline.
  static Future<void> reportClock({
    required String eventId,
    required String identity,
    required int offsetMs,
    required int rttMs,
  }) => _invoke<Map>({
    'action': 'report-clock',
    'eventId': eventId,
    'identity': identity,
    'offsetMs': offsetMs,
    'rttMs': rttMs,
  });

  /// Choose which publisher carries the show's sound — a camera, the Studio,
  /// or Stream Audio. The server clears the flag everywhere else.
  static Future<void> setMasterAudio({
    required String eventId,
    required String identity,
  }) => _invoke<Map>({
    'action': 'set-master-audio',
    'eventId': eventId,
    'identity': identity,
    // Servers before the Studio read this name.
    'cameraIdentity': identity,
  });

  /// Host: report whether the replay recording actually started.
  ///
  /// Returns false when the egress never came up — misconfigured replay storage
  /// or a LiveKit error. The show is live either way; what changes is that the
  /// host finds out now instead of after the show, with nothing to sell.
  /// Old servers omit the flag; absence is treated as "started", which is the
  /// behaviour that shipped before this existed.
  ///
  /// [studio] marks the call as coming from the desktop Studio. While a Studio
  /// is in the room the server refuses Start Show from anywhere else.
  static Future<bool> startShow({
    required String eventId,
    bool studio = false,
  }) async {
    final d = await _invoke<Map>({
      'action': 'start-show',
      'eventId': eventId,
      if (studio) 'studio': true,
    });
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
  /// [studio]: see [startShow].
  static Future<void> stopEgress({
    required String eventId,
    bool studio = false,
  }) => _invoke<Map>({
    'action': 'stop-egress',
    'eventId': eventId,
    if (studio) 'studio': true,
  });

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

  /// Camera slot this token holds (event_cameras.id), when it has one.
  final String? slotId;

  /// The name the server gave this feed — a slot's label wins over what the
  /// device asked for.
  final String? cameraName;

  const LivekitToken({
    required this.token,
    required this.wsUrl,
    this.isMasterAudio = false,
    this.slotId,
    this.cameraName,
  });

  factory LivekitToken.fromJson(Map d, {String? fallbackName}) => LivekitToken(
    token: d['token'] as String,
    wsUrl: d['wsUrl'] as String,
    isMasterAudio: d['isMasterAudio'] == true,
    slotId: d['slotId'] as String?,
    cameraName: d['cameraName'] as String? ?? fallbackName,
  );
}

/// One camera slot for "Which camera is this?" and the Studio's source list.
class CameraSlot {
  final String id;
  final int slotIndex;
  final String label;

  /// LiveKit identity on this slot right now, or null when it is open.
  final String? heldBy;
  final String? heldByUsername;
  final String? heldByDevice;

  const CameraSlot({
    required this.id,
    required this.slotIndex,
    required this.label,
    this.heldBy,
    this.heldByUsername,
    this.heldByDevice,
  });

  factory CameraSlot.fromJson(Map<String, dynamic> j) => CameraSlot(
    id: j['id'] as String,
    slotIndex: (j['slotIndex'] as num).toInt(),
    label: j['label'] as String,
    heldBy: j['heldBy'] as String?,
    heldByUsername: j['heldByUsername'] as String?,
    heldByDevice: j['heldByDevice'] as String?,
  );

  /// Taken by some OTHER device. Your own install reconnecting keeps its slot.
  bool takenFor(String myIdentity) => heldBy != null && heldBy != myIdentity;
}

class CameraSlots {
  final List<CameraSlot> slots;
  final bool streamAudioTaken;
  const CameraSlots({required this.slots, required this.streamAudioTaken});
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

/// set-element refused a push: the server already holds a newer version.
/// [current] is that version (null if it couldn't be read).
class ElementStale implements Exception {
  const ElementStale(this.current);
  final LiveElement? current;

  @override
  String toString() => 'That element changed elsewhere — reloaded.';
}
