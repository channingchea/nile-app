import 'package:flutter/material.dart';
import '../services/notification_preferences_service.dart';
import '../theme.dart';

/// Per-type notification toggles. Each switch persists immediately; on failure
/// the toggle rolls back and a snackbar is shown.
class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key});

  @override
  State<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends State<NotificationPreferencesScreen> {
  NotificationPreferences? _prefs;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final p = await NotificationPreferencesService.get();
      if (mounted) setState(() => _prefs = p);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(
    NotificationPreferences next,
    NotificationPreferences prev,
  ) async {
    setState(() => _prefs = next);
    try {
      await NotificationPreferencesService.save(next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _prefs = prev);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save — try again")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Notifications')),
      body: NileMaxWidth(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error || _prefs == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Couldn't load preferences",
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final p = _prefs!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
      children: [
        _section('Posts'),
        _toggle(
          'Likes',
          'When someone likes your post',
          p.postLike,
          (v) => _set(p.copyWith(postLike: v), p),
        ),
        _toggle(
          'Comments',
          'When someone comments on your post',
          p.postComment,
          (v) => _set(p.copyWith(postComment: v), p),
        ),
        _section('People'),
        _toggle(
          'New followers',
          'When someone follows you',
          p.follow,
          (v) => _set(p.copyWith(follow: v), p),
        ),
        _section('Events'),
        _toggle(
          'Starting soon',
          'Events you hold tickets to or follow the host',
          p.eventStarting,
          (v) => _set(p.copyWith(eventStarting: v), p),
        ),
        _toggle(
          'Now live',
          'When an event you follow goes live',
          p.eventLive,
          (v) => _set(p.copyWith(eventLive: v), p),
        ),
        _toggle(
          'Ended',
          'When an event you attended ends',
          p.eventEnded,
          (v) => _set(p.copyWith(eventEnded: v), p),
        ),
        _toggle(
          'Replay ready',
          'When an event’s replay is ready to watch',
          p.replayReady,
          (v) => _set(p.copyWith(replayReady: v), p),
        ),
        _toggle(
          'Crew invites',
          'When a host adds you as a camera operator',
          p.operatorAssigned,
          (v) => _set(p.copyWith(operatorAssigned: v), p),
        ),
        _toggle(
          'Sound check open',
          'When a host you’re crewing for opens sound check',
          p.soundcheckOpen,
          (v) => _set(p.copyWith(soundcheckOpen: v), p),
        ),
        _toggle(
          'Price your replay',
          'When your show’s replay is ready to be priced and published',
          p.replayPricePrompt,
          (v) => _set(p.copyWith(replayPricePrompt: v), p),
        ),
        _section('Earnings'),
        // P4 #38. This column has always existed and always been honoured;
        // the switch was simply never drawn, so a host taking tips through a
        // three-hour show got a push per tip with no way to silence them.
        _toggle(
          'Tips',
          'When someone tips you during a show',
          p.tipReceived,
          (v) => _set(p.copyWith(tipReceived: v), p),
        ),
        _section('Sponsorship'),
        // One switch for both offer types: the 24-hour warning is only useful
        // to someone who wanted the offer notification in the first place.
        _toggle(
          'Sponsorship offers',
          'When a brand offers to sponsor one of your events',
          p.sponsorshipOffer,
          (v) => _set(p.copyWith(sponsorshipOffer: v), p),
        ),
        _section('Support'),
        _toggle(
          'Report updates',
          'When a bug or idea you reported is resolved',
          p.feedbackResolved,
          (v) => _set(p.copyWith(feedbackResolved: v), p),
        ),
        _section('Messages'),
        _toggle(
          'Direct messages',
          'When someone sends you a message',
          p.newMessage,
          (v) => _set(p.copyWith(newMessage: v), p),
        ),
        _toggle(
          'Reactions',
          'When someone reacts to your message',
          p.messageReaction,
          (v) => _set(p.copyWith(messageReaction: v), p),
        ),
        _section('Quiet hours'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeThumbColor: NileColors.volt,
          title: Text('Hold notifications overnight',
              style: NileTextStyles.bodyMd()),
          subtitle: Text(
            p.quietHoursOn
                ? 'Silent from ${_fmtMinutes(p.quietHoursStartMinutes!)} '
                    'to ${_fmtMinutes(p.quietHoursEndMinutes!)}'
                : 'Off',
            style: NileTextStyles.caption()
                .copyWith(color: NileColors.txtSecondary),
          ),
          value: p.quietHoursOn,
          onChanged: (on) => _set(
            on
                // 22:00–07:00 is the default people expect; they can move it.
                ? p.copyWith(
                    quietHoursStartMinutes: 22 * 60,
                    quietHoursEndMinutes: 7 * 60,
                    quietHoursUtcOffsetMinutes:
                        DateTime.now().timeZoneOffset.inMinutes,
                  )
                : p.copyWith(clearQuietHours: true),
            p,
          ),
        ),
        if (p.quietHoursOn) ...[
          Row(
            children: [
              Expanded(
                child: _timeField('From', p.quietHoursStartMinutes!,
                    (m) => _set(p.copyWith(quietHoursStartMinutes: m), p)),
              ),
              const SizedBox(width: NileSpacing.s12),
              Expanded(
                child: _timeField('To', p.quietHoursEndMinutes!,
                    (m) => _set(p.copyWith(quietHoursEndMinutes: m), p)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s8),
            child: Text(
              'Notifications still arrive in the app — your phone just stays '
              'quiet. Alerts about a show starting, going live, or a '
              'soundcheck you\'re crewing always come through.',
              style: NileTextStyles.caption()
                  .copyWith(color: NileColors.txtTertiary),
            ),
          ),
        ],
      ],
    );
  }

  static String _fmtMinutes(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';

  Widget _timeField(String label, int minutes, ValueChanged<int> onPicked) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
        );
        if (picked != null) onPicked(picked.hour * 60 + picked.minute);
      },
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s12),
        side: BorderSide(color: NileColors.border),
      ),
      child: Text('$label  ${_fmtMinutes(minutes)}',
          style: NileTextStyles.bodyMd()),
    );
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(NileSpacing.s4, NileSpacing.s16, NileSpacing.s4, NileSpacing.s8),
    child: Text(
      label,
      style: NileTextStyles.labelSm().copyWith(color: NileColors.txtTertiary),
    ),
  );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Container(
    margin: const EdgeInsets.only(bottom: NileSpacing.s8),
    padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
    decoration: BoxDecoration(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: NileTextStyles.labelLg()),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? NileColors.onVolt
                : NileColors.txtSecondary,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? NileColors.volt
                : NileColors.bgRaised,
          ),
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ],
    ),
  );
}
