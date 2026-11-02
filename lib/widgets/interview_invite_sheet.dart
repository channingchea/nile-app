import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/interview.dart';
import '../services/interview_service.dart';
import '../services/livekit_service.dart';
import '../services/profile_service.dart' show UserProfile;
import '../services/search_service.dart';
import '../theme.dart';
import 'interview_stage.dart' show StageAvatar;

/// Interview mode: invite guests by username or with a share link. A dialog
/// on desktop, where the Studio lives. [eventId] is the LiveKit slug.
Future<void> showInterviewInviteSheet(
  BuildContext context, {
  required String eventId,
  required ValueListenable<List<InterviewGuest>> guests,
  String? hostId,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
      child: InterviewInviteSheet(
        eventId: eventId,
        guests: guests,
        hostId: hostId,
      ),
    ),
  ),
);

Future<List<UserProfile>> _searchUsers(String q) async =>
    (await SearchService.searchUsers(q)).items;

class InterviewInviteSheet extends StatefulWidget {
  const InterviewInviteSheet({
    super.key,
    required this.eventId,
    required this.guests,
    this.hostId,
    this.search = _searchUsers,
    this.invite = LivekitService.inviteGuest,
    this.link = LivekitService.guestLink,
  });

  final String eventId;

  /// The guest list, kept live by the Studio.
  final ValueListenable<List<InterviewGuest>> guests;

  /// Left out of the results — the host is already on the show.
  final String? hostId;
  final Future<List<UserProfile>> Function(String query) search;
  final Future<void> Function({
    required String eventId,
    required String userId,
    String? title,
  })
  invite;
  final Future<String> Function({required String eventId, bool rotate}) link;

  static const debounce = Duration(milliseconds: 300);

  @override
  State<InterviewInviteSheet> createState() => _InterviewInviteSheetState();
}

class _InterviewInviteSheetState extends State<InterviewInviteSheet> {
  final _query = TextEditingController();
  final _title = TextEditingController();
  Timer? _debounce;
  List<UserProfile> _results = const [];
  bool _searching = false;
  int _searchSeq = 0;

  /// Invited this session — shown at once, before the list catches up.
  final Set<String> _invited = {};
  final Set<String> _inviting = {};
  String? _error;
  String? _code;
  bool _linkBusy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _title.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(InterviewInviteSheet.debounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      final r = await widget.search(q.trim());
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = [
          for (final u in r)
            if (u.id != widget.hostId) u,
        ];
        _searching = false;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _error = 'Search didn’t work. Try again.';
      });
    }
  }

  Future<void> _invite(UserProfile u) async {
    final title = _title.text.trim();
    setState(() {
      _inviting.add(u.id);
      _error = null;
    });
    try {
      await widget.invite(
        eventId: widget.eventId,
        userId: u.id,
        title: title.isEmpty ? null : title,
      );
      if (mounted) setState(() => _invited.add(u.id));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _inviting.remove(u.id));
    }
  }

  Future<void> _getLink({bool rotate = false}) async {
    if (rotate) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text('Make a new link?', style: NileTextStyles.headingMd()),
          content: Text(
            'The old link stops working. Guests already on the list stay on it.',
            style: NileTextStyles.bodyMd(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('New link'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _linkBusy = true;
      _error = null;
    });
    try {
      final code = await widget.link(eventId: widget.eventId, rotate: rotate);
      if (mounted) setState(() => _code = code);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _linkBusy = false);
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(
      top: NileSpacing.s16,
      bottom: NileSpacing.s8,
    ),
    child: Text(
      text,
      style: NileTextStyles.labelSm().copyWith(
        color: NileColors.txtTertiary,
        letterSpacing: 1.2,
      ),
    ),
  );

  InputDecoration _field(String hint, {IconData? icon}) => InputDecoration(
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon, size: 18),
    isDense: true,
    filled: true,
    fillColor: NileColors.bgRaised,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(NileRadius.sm),
      borderSide: BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.guests,
    builder: (context, guests, _) {
      final onList = {
        for (final g in guests)
          if (g.status != GuestStatus.removed) g.userId,
        ..._invited,
      };
      final url = _code == null ? null : InterviewService.guestUrl(_code!);
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(NileSpacing.s24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Invite guests', style: NileTextStyles.headingMd()),
              ),
              IconButton(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          Text(
            'Guests need a Nile account. They wait in the green room until '
            'you bring them on stage.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: NileSpacing.s16),
          TextField(
            controller: _query,
            onChanged: _onQuery,
            autofocus: true,
            decoration: _field('Search by username', icon: Icons.search),
          ),
          const SizedBox(height: NileSpacing.s8),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: _field(
              'Title on their name tag (optional)',
            ).copyWith(counterText: ''),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(NileSpacing.s12),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_query.text.trim().isNotEmpty && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: NileSpacing.s12),
              child: Text(
                'No one matches “${_query.text.trim()}”.',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ),
          for (final u in _results)
            ListTile(
              key: ValueKey('result-${u.id}'),
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 40,
                height: 40,
                child: StageAvatar(
                  name: u.displayName.isEmpty ? u.username : u.displayName,
                  avatarUrl: u.avatarUrl,
                  small: true,
                ),
              ),
              title: Text(
                u.displayName.isEmpty ? '@${u.username}' : u.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('@${u.username}'),
              trailing: onList.contains(u.id)
                  ? Text(
                      'Invited',
                      style: NileTextStyles.labelSm().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    )
                  : FilledButton(
                      onPressed: _inviting.contains(u.id)
                          ? null
                          : () => _invite(u),
                      child: const Text('Invite'),
                    ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: NileSpacing.s8),
              child: Text(
                _error!,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.error,
                ),
              ),
            ),
          _heading('GUESTS'),
          if (guests.isEmpty)
            Text(
              'No one yet.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          for (final g in guests)
            ListTile(
              key: ValueKey('guest-${g.userId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: g.title == null || g.title!.isEmpty
                  ? null
                  : Text(g.title!, maxLines: 1),
              trailing: Text(
                g.status.label,
                style: NileTextStyles.labelSm().copyWith(
                  color: g.status == GuestStatus.onStage
                      ? NileColors.coral
                      : NileColors.txtTertiary,
                ),
              ),
            ),
          _heading('SHARE LINK'),
          Text(
            'Anyone with a Nile account who opens it joins the guest list.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: NileSpacing.s8),
          if (url == null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _linkBusy ? null : _getLink,
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Get link'),
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s12,
                vertical: NileSpacing.s8,
              ),
              decoration: BoxDecoration(
                color: NileColors.bgRaised,
                borderRadius: BorderRadius.circular(NileRadius.sm),
              ),
              child: SelectableText(url, style: NileTextStyles.bodySm()),
            ),
            const SizedBox(height: NileSpacing.s8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => _copy(url),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
                const SizedBox(width: NileSpacing.s8),
                TextButton(
                  onPressed: _linkBusy ? null : () => _getLink(rotate: true),
                  child: const Text('New link'),
                ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
