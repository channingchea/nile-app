import 'studio_roles.dart';

/// How the Studio runs a show (docs/plans/studio-modes.md).
///
/// Stored in `events.studio_mode` (0145) and mirrored into the LiveKit room
/// metadata as `mode` by the livekit `set-mode` action, so viewers already in
/// the lobby follow a change without refetching the event.
enum StudioMode {
  multicam('Multicam', 'Several cameras. Viewers pick their own angle.'),
  interview(
    'Interview',
    'A green room and a stage of up to 6 people, including remote guests.',
  ),
  premiere(
    'Premiere',
    'Play an uploaded film in sync for every viewer, then take questions.',
  );

  const StudioMode(this.label, this.description);

  final String label;
  final String description;

  /// The value stored in the database and room metadata.
  String get wire => name;

  /// Unknown or missing values read as [multicam], the mode every show had
  /// before modes existed.
  static StudioMode fromWire(Object? value) {
    for (final m in values) {
      if (m.name == value) return m;
    }
    return multicam;
  }

  /// The room metadata's `mode`, or null when the Studio never set one (the
  /// event row's value stands).
  static StudioMode? fromRoomMetadata(String? raw) {
    final v = parseParticipantMeta(raw)['mode'];
    return v is String ? fromWire(v) : null;
  }

  /// The mode can change until the show goes live; then it is locked.
  static bool canSwitch({required bool isLive}) => !isLive;
}
