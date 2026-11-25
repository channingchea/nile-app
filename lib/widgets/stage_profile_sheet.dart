import 'package:flutter/material.dart';

import '../services/interview_viewer.dart';
import '../theme.dart';
import 'interview_stage.dart' show StageAvatar;

/// Who's on stage, under an Interview show: avatar, name, title. Guests and
/// the host open their profile sheet; crew phones just say which camera.
class StagePeopleStrip extends StatelessWidget {
  const StagePeopleStrip({
    super.key,
    required this.people,
    required this.onTap,
    this.vertical = false,
  });

  final List<StagePerson> people;
  final ValueChanged<StagePerson> onTap;

  /// A column down the side (phone landscape) instead of a row.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final list = ListView.separated(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      padding: const EdgeInsets.all(NileSpacing.s8),
      itemCount: people.length,
      separatorBuilder: (_, _) =>
          const SizedBox(width: NileSpacing.s8, height: NileSpacing.s8),
      itemBuilder: (_, i) => _Person(
        person: people[i],
        vertical: vertical,
        onTap: people[i].hasProfile ? () => onTap(people[i]) : null,
      ),
    );
    return ColoredBox(
      color: NileColors.bgPage,
      child: vertical ? list : SizedBox(height: 64, child: list),
    );
  }
}

class _Person extends StatelessWidget {
  const _Person({required this.person, required this.vertical, this.onTap});

  final StagePerson person;
  final bool vertical;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NileTextStyles.labelSm(),
        ),
        if (p.title != null && p.title!.isNotEmpty)
          Text(
            p.title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NileTextStyles.caption().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
      ],
    );
    return Semantics(
      button: onTap != null,
      label: p.title == null ? p.name : '${p.name}, ${p.title}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s4,
            NileSpacing.s4,
            NileSpacing.s12,
            NileSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: NileColors.bgSurface,
            borderRadius: BorderRadius.circular(NileRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 36,
                child: p.kind == StagePersonKind.crew
                    ? CircleAvatar(
                        backgroundColor: NileColors.bgRaised,
                        child: Icon(
                          Icons.videocam_outlined,
                          size: 18,
                          color: NileColors.txtSecondary,
                        ),
                      )
                    : StageAvatar(
                        name: p.name,
                        avatarUrl: p.avatarUrl,
                        small: true,
                      ),
              ),
              const SizedBox(width: NileSpacing.s8),
              // A row scrolls sideways (unbounded), so cap each name; the
              // side column is a fixed width, so names fit what's left.
              if (vertical)
                Flexible(child: text)
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: text,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A guest's (or the host's) profile, over the show: the show keeps playing.
/// [isFollowing] and [onFollow] are null when following isn't possible
/// (signed out, or it's you); [onViewProfile] opens their full profile.
Future<void> showStageProfileSheet(
  BuildContext context, {
  required StagePerson person,
  Future<bool> Function()? isFollowing,
  Future<void> Function(bool follow)? onFollow,
  VoidCallback? onViewProfile,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: NileColors.bgSurface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
  ),
  builder: (_) => StageProfileSheet(
    person: person,
    isFollowing: isFollowing,
    onFollow: onFollow,
    onViewProfile: onViewProfile,
  ),
);

class StageProfileSheet extends StatefulWidget {
  const StageProfileSheet({
    super.key,
    required this.person,
    this.isFollowing,
    this.onFollow,
    this.onViewProfile,
  });

  final StagePerson person;
  final Future<bool> Function()? isFollowing;
  final Future<void> Function(bool follow)? onFollow;
  final VoidCallback? onViewProfile;

  @override
  State<StageProfileSheet> createState() => _StageProfileSheetState();
}

class _StageProfileSheetState extends State<StageProfileSheet> {
  /// Null until we know (the button waits rather than guessing).
  bool? _following;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.isFollowing?.call().then(
      (v) {
        if (mounted) setState(() => _following = v);
      },
      onError: (_) {
        if (mounted) setState(() => _following = false);
      },
    );
  }

  Future<void> _toggle() async {
    final was = _following;
    if (was == null || _busy || widget.onFollow == null) return;
    // Optimistic, undone if the write fails.
    setState(() {
      _following = !was;
      _busy = true;
    });
    try {
      await widget.onFollow!(!was);
    } catch (_) {
      if (mounted) setState(() => _following = was);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final canFollow = widget.isFollowing != null && widget.onFollow != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 72,
              child: StageAvatar(name: p.name, avatarUrl: p.avatarUrl),
            ),
            const SizedBox(height: NileSpacing.s12),
            Text(
              p.name,
              textAlign: TextAlign.center,
              style: NileTextStyles.headingMd(),
            ),
            if (p.username != null) ...[
              const SizedBox(height: NileSpacing.s2),
              Text(
                '@${p.username}',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
            if (p.title != null && p.title!.isNotEmpty) ...[
              const SizedBox(height: NileSpacing.s8),
              Text(
                p.title!,
                textAlign: TextAlign.center,
                style: NileTextStyles.bodyMd(),
              ),
            ],
            const SizedBox(height: NileSpacing.s24),
            Row(
              children: [
                if (canFollow) ...[
                  Expanded(
                    child: FilledButton(
                      onPressed: _following == null || _busy ? null : _toggle,
                      style: FilledButton.styleFrom(
                        backgroundColor: _following == true
                            ? NileColors.bgRaised
                            : NileColors.volt,
                        foregroundColor: _following == true
                            ? NileColors.txtPrimary
                            : NileColors.onVolt,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(_following == true ? 'Following' : 'Follow'),
                    ),
                  ),
                  const SizedBox(width: NileSpacing.s12),
                ],
                if (widget.onViewProfile != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onViewProfile!();
                      },
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                      ),
                      child: const Text('View profile'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
