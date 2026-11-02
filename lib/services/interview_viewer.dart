import 'package:flutter/foundation.dart';

import 'interview.dart';
import 'live_elements.dart' show elementIdOfAngle, isElementAngleId;
import 'studio_roles.dart';

/// What a ticket holder watching an Interview show pulls and sees
/// (docs/plans/studio-modes.md, phase 5). Pure, so the rules are tested
/// without a room; viewer_screen applies them to the live participants.

/// The extra angle the host can add next to the stage: one participant's
/// screen share, or a live element drawn full screen.
@immutable
class ContentAngle {
  const ContentAngle.share(String identity) : this._(identity, null);
  const ContentAngle.element(String elementId) : this._(null, elementId);
  const ContentAngle._(this.shareOf, this.elementId);

  /// The participant whose screen share this is, or null.
  final String? shareOf;

  /// The live element shown, or null.
  final String? elementId;

  /// Room metadata `stage.content`: `<identity>#share` or `el:<id>`. Anything
  /// else (or nothing) is no content angle.
  static ContentAngle? parse(String? content) {
    if (content == null || content.isEmpty) return null;
    if (isElementAngleId(content)) {
      final id = elementIdOfAngle(content)!;
      return id.isEmpty ? null : ContentAngle.element(id);
    }
    const tail = '#share';
    if (content.endsWith(tail) && content.length > tail.length) {
      return ContentAngle.share(
        content.substring(0, content.length - tail.length),
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ContentAngle &&
      other.shareOf == shareOf &&
      other.elementId == elementId;
  @override
  int get hashCode => Object.hash(shareOf, elementId);
}

/// The angles a viewer can pick: the stage always (null), plus the content
/// angle while the host has one up. An element angle whose element is gone
/// ([hasElement] says no) isn't offered.
List<ContentAngle?> interviewAngles(
  String? content, {
  bool Function(String elementId)? hasElement,
}) {
  final c = ContentAngle.parse(content);
  final id = c?.elementId;
  final gone = id != null && hasElement != null && !hasElement(id);
  return [null, if (c != null && !gone) c];
}

/// Who is on the viewer's stage at [nowMs] (server time), in layout order:
/// countdowns run out, actually in the room ([present]), and never the
/// backstage talkback connection.
List<String> stageLineup(
  StageState stage,
  int nowMs, {
  required Map<String, String?> present,
}) => [
  for (final id in stage.visibleAt(nowMs))
    if (present.containsKey(id) && present[id] != NileRole.backstage) id,
];

/// Milliseconds until the next countdown on stage runs out, or null when
/// nobody is waiting — so the viewer wakes exactly then instead of polling.
int? nextStageReveal(StageState stage, int nowMs) {
  int? next;
  for (final e in stage.entries) {
    final wait = e.at - nowMs;
    if (wait > 0 && (next == null || wait < next)) next = wait;
  }
  return next;
}

/// The feeds an Interview viewer subscribes to; everything else is dropped.
@immutable
class StageFeeds {
  const StageFeeds({this.video = const {}, this.audio = const {}, this.share});

  /// Identities whose camera video is pulled.
  final Set<String> video;

  /// Identities whose audio plays.
  final Set<String> audio;

  /// The identity whose screen share is pulled (the content angle), or null.
  final String? share;
}

/// The viewer audio/video rule for Interview.
///
///  * Video: everyone on stage, including those still counting down, so their
///    picture is already there when the countdown ends. A guest still in the
///    green room refuses the subscribe (SFU permissions); the viewer retries
///    when that changes.
///  * Audio: the show's master audio plus every guest whose countdown has run
///    out ([visible]). Crew phones are video only unless they carry the
///    master audio. Nothing at all while the viewer has muted.
///  * Never the backstage connection.
StageFeeds stageFeeds({
  required StageState stage,
  required List<String> visible,
  required Map<String, String?> roles,
  String? masterAudio,
  bool audioOn = true,
}) {
  bool ok(String id) => roles[id] != NileRole.backstage;
  final content = ContentAngle.parse(stage.content);
  return StageFeeds(
    video: {
      for (final id in stage.ids)
        if (ok(id)) id,
    },
    audio: !audioOn
        ? const {}
        : {
            if (masterAudio != null && ok(masterAudio)) masterAudio,
            for (final id in visible)
              if (roles[id] == NileRole.guest) id,
          },
    share: content?.shareOf != null && ok(content!.shareOf!)
        ? content.shareOf
        : null,
  );
}

enum StagePersonKind { guest, host, crew }

/// One person on stage as the avatar strip and profile sheet show them.
@immutable
class StagePerson {
  const StagePerson({
    required this.identity,
    required this.kind,
    required this.name,
    this.title,
    this.avatarUrl,
    this.userId,
    this.username,
  });

  final String identity;
  final StagePersonKind kind;
  final String name;
  final String? title;
  final String? avatarUrl;

  /// Their Nile account; null for crew phones, which have no profile.
  final String? userId;
  final String? username;

  bool get hasProfile => userId != null;
}

/// Who [identity] is, from its token metadata: a guest (their own profile),
/// the Studio (the event's host) or a crew camera (its camera name only).
StagePerson stagePersonOf(
  String identity,
  Map<String, dynamic> meta, {
  String? hostId,
  String? hostName,
  String? hostUsername,
  String? hostAvatarUrl,
  String? participantName,
}) {
  final guest = GuestMeta.fromJson(meta);
  if (guest != null) {
    return StagePerson(
      identity: identity,
      kind: StagePersonKind.guest,
      name: guest.name,
      title: guest.title,
      avatarUrl: guest.avatarUrl,
      userId: guest.userId,
      username: guest.username,
    );
  }
  if (meta['role'] == NileRole.studio) {
    return StagePerson(
      identity: identity,
      kind: StagePersonKind.host,
      name: hostName ?? hostUsername ?? 'Host',
      title: 'Host',
      avatarUrl: hostAvatarUrl,
      userId: hostId,
      username: hostUsername,
    );
  }
  final camera = meta['cameraName'];
  return StagePerson(
    identity: identity,
    kind: StagePersonKind.crew,
    name: camera is String && camera.isNotEmpty
        ? camera
        : (participantName?.isNotEmpty ?? false)
        ? participantName!
        : 'Camera',
  );
}
