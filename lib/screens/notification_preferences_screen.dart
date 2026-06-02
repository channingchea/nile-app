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
            Text("Couldn't load preferences",
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.txtSecondary)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final p = _prefs!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _section('Posts'),
        _toggle('Likes', 'When someone likes your post', p.postLike,
            (v) => _set(p.copyWith(postLike: v), p)),
        _toggle('Comments', 'When someone comments on your post', p.postComment,
            (v) => _set(p.copyWith(postComment: v), p)),
        _section('People'),
        _toggle('New followers', 'When someone follows you', p.follow,
            (v) => _set(p.copyWith(follow: v), p)),
        _section('Events'),
        _toggle('Starting soon', 'Events you hold tickets to or follow the host',
            p.eventStarting, (v) => _set(p.copyWith(eventStarting: v), p)),
        _toggle('Now live', 'When an event you follow goes live', p.eventLive,
            (v) => _set(p.copyWith(eventLive: v), p)),
        _toggle('Ended', 'When an event you attended ends', p.eventEnded,
            (v) => _set(p.copyWith(eventEnded: v), p)),
      ],
    );
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(label,
            style: NileTextStyles.labelSm()
                .copyWith(color: NileColors.txtTertiary)),
      );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: NileTextStyles.labelLg()),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: NileTextStyles.bodySm()
                          .copyWith(color: NileColors.txtTertiary)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              thumbColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? NileColors.bgPage
                      : NileColors.txtSecondary),
              trackColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? NileColors.volt
                      : NileColors.bgRaised),
              trackOutlineColor:
                  WidgetStateProperty.all(Colors.transparent),
            ),
          ],
        ),
      );
}
