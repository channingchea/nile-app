import 'profile_service.dart';
import 'supabase_client.dart';

/// A camera slot for an event (e.g. "Camera 1", optionally Master Audio).
class EventCamera {
  final String id;
  final String eventId;
  final int slotIndex;
  final String label;
  final bool isMasterAudio;

  const EventCamera({
    required this.id,
    required this.eventId,
    required this.slotIndex,
    required this.label,
    required this.isMasterAudio,
  });

  factory EventCamera.fromJson(Map<String, dynamic> json) => EventCamera(
        id: json['id'] as String,
        eventId: json['event_id'] as String,
        slotIndex: (json['slot_index'] as num).toInt(),
        label: json['label'] as String,
        isMasterAudio: json['is_master_audio'] as bool? ?? false,
      );
}

/// An assigned operator with their profile and the camera slot index they're
/// on (1-based), or null for "any camera". Used by the host-facing crew editor.
class AssignedOperator {
  final UserProfile profile;
  final int? slotIndex;
  final bool isAudioOperator;
  const AssignedOperator(
      {required this.profile, this.slotIndex, this.isAudioOperator = false});
}

/// A chosen operator and the camera slot index they're assigned to (1-based),
/// or null for "unassigned / any camera". Mutable working state for the crew
/// picker, shared by the create flow and the edit screen.
class OperatorPick {
  final UserProfile profile;
  int? slotIndex;
  bool isAudioOperator;
  OperatorPick(this.profile, {this.slotIndex, this.isAudioOperator = false});
}

/// The current user's operator assignment for an event, with the assigned
/// camera slot (if any) resolved.
class MyOperatorAssignment {
  final String eventId;
  final EventCamera? camera; // null = assigned to "any camera"
  final bool isAudioOperator;
  const MyOperatorAssignment(
      {required this.eventId, this.camera, this.isAudioOperator = false});

  /// Camera name to pre-fill when entering the stream, or null if unassigned.
  String? get cameraLabel => camera?.label;
}

class CrewService {
  /// Replace the camera slots for [eventId] with [count] default slots (host
  /// only). Slots get auto labels ("Camera 1"…) and no master-audio flag;
  /// labels and master/device roles are assigned later on the Sound Check page.
  /// Clears existing slots first so the call is idempotent across edits, then
  /// returns the persisted rows (with ids) in slot order.
  static Future<List<EventCamera>> saveCameras({
    required String eventId,
    required int count,
  }) async {
    await supabase.from('event_cameras').delete().eq('event_id', eventId);
    if (count <= 0) return [];

    final payload = [
      for (var i = 0; i < count; i++)
        {
          'event_id': eventId,
          'slot_index': i + 1,
          'label': 'Camera ${i + 1}',
          'is_master_audio': false,
        }
    ];

    final rows = await supabase
        .from('event_cameras')
        .insert(payload)
        .select()
        .order('slot_index');
    return (rows as List)
        .map((r) => EventCamera.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Adjust the number of camera slots for [eventId] to [count] without
  /// disturbing slots that stay (host only). Grows by appending new slots and
  /// shrinks by removing the highest slots; when removing, any operator pointed
  /// at a vanishing slot is first reset to "any camera" to satisfy the FK.
  /// Used by Edit Event so camera/device roles set during Sound Check survive.
  static Future<void> setCameraCount({
    required String eventId,
    required int count,
  }) async {
    final existing = await fetchCameras(eventId);
    final current = existing.length;
    if (count == current) return;

    if (count > current) {
      final payload = [
        for (var i = current; i < count; i++)
          {
            'event_id': eventId,
            'slot_index': i + 1,
            'label': 'Camera ${i + 1}',
            'is_master_audio': false,
          }
      ];
      await supabase.from('event_cameras').insert(payload);
      return;
    }

    // Shrinking: clear operator references to the slots being removed, then
    // delete those slots.
    final removedIds =
        existing.where((c) => c.slotIndex > count).map((c) => c.id).toList();
    if (removedIds.isNotEmpty) {
      await supabase
          .from('event_operators')
          .update({'camera_id': null})
          .eq('event_id', eventId)
          .inFilter('camera_id', removedIds);
      await supabase
          .from('event_cameras')
          .delete()
          .eq('event_id', eventId)
          .gt('slot_index', count);
    }
  }

  /// All camera slots for [eventId] in slot order (host or operator read).
  static Future<List<EventCamera>> fetchCameras(String eventId) async {
    final rows = await supabase
        .from('event_cameras')
        .select()
        .eq('event_id', eventId)
        .order('slot_index');
    return (rows as List)
        .map((r) => EventCamera.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// All assigned operators for [eventId] with their profile and camera slot.
  /// Host-only in practice (RLS `event_operators_host_all`); used by the crew
  /// editor. The joined camera row resolves each operator's 1-based slot index.
  static Future<List<AssignedOperator>> fetchOperators(String eventId) async {
    final rows = await supabase
        .from('event_operators')
        .select(
            'camera_id, is_audio_operator, profiles!event_operators_operator_id_fkey(*), event_cameras(slot_index)')
        .eq('event_id', eventId);
    final out = <AssignedOperator>[];
    for (final r in rows as List) {
      final row = r as Map<String, dynamic>;
      final prof = row['profiles'] as Map<String, dynamic>?;
      if (prof == null) continue;
      final cam = row['event_cameras'] as Map<String, dynamic>?;
      out.add(AssignedOperator(
        profile: UserProfile.fromMap(prof),
        slotIndex: cam == null ? null : (cam['slot_index'] as num).toInt(),
        isAudioOperator: row['is_audio_operator'] as bool? ?? false,
      ));
    }
    return out;
  }

  /// Assign [operatorId] to [eventId] (optionally to [cameraId]) and notify
  /// them. Idempotent per (event, operator); notification fires once and only
  /// if the operator hasn't disabled the operator_assigned preference.
  static Future<void> assignOperator({
    required String eventId,
    required String operatorId,
    String? cameraId,
    bool isAudioOperator = false,
  }) async {
    await supabase.rpc('assign_event_operator', params: {
      'p_event_id': eventId,
      'p_operator_id': operatorId,
      'p_camera_id': cameraId,
      'p_is_audio_operator': isAudioOperator,
    });
  }

  /// Remove an operator from an event (host only).
  static Future<void> removeOperator({
    required String eventId,
    required String operatorId,
  }) async {
    await supabase
        .from('event_operators')
        .delete()
        .eq('event_id', eventId)
        .eq('operator_id', operatorId);
  }

  /// The current user's operator assignment for [eventId], or null if they
  /// aren't crew. Joins the assigned camera slot so callers can pre-fill the
  /// camera name on entry. RLS scopes this to the user's own row.
  static Future<MyOperatorAssignment?> myAssignment(String eventId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final rows = await supabase
        .from('event_operators')
        .select('event_id, is_audio_operator, event_cameras(*)')
        .eq('event_id', eventId)
        .eq('operator_id', uid)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    final row = list.first as Map<String, dynamic>;
    final cam = row['event_cameras'] as Map<String, dynamic>?;
    return MyOperatorAssignment(
      eventId: eventId,
      camera: cam == null ? null : EventCamera.fromJson(cam),
      isAudioOperator: row['is_audio_operator'] as bool? ?? false,
    );
  }

  /// True if the current user is an assigned operator for [eventId]. Used as a
  /// free-access grant alongside ownership and paid tickets.
  static Future<bool> isOperator(String eventId) async {
    return (await myAssignment(eventId)) != null;
  }
}
