import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' show ConnectionQuality;

import '../services/backstage.dart';
import '../theme.dart';
import 'nile_studio.dart' show NileStudioIconButton;

/// The pieces of the guest's green room (GuestGreenRoomScreen) that don't
/// touch LiveKit, split out so they can be pumped in tests.

/// Before joining: the preview, the name tag and the join button.
class GuestPreJoinForm extends StatelessWidget {
  const GuestPreJoinForm({
    super.key,
    required this.preview,
    required this.name,
    required this.titleController,
    required this.onJoin,
    this.controls,
    this.eventTitle,
    this.joining = false,
    this.error,
  });

  /// Camera preview with its meter, drawn by the screen.
  final Widget preview;

  /// Mic/camera toggles and device pickers under the preview.
  final Widget? controls;
  final String name;
  final TextEditingController titleController;
  final VoidCallback onJoin;
  final String? eventTitle;
  final bool joining;
  final String? error;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(NileSpacing.s16),
    children: [
      if (eventTitle != null) ...[
        Text('You’re a guest on', style: NileTextStyles.caption()),
        Text(eventTitle!, style: NileTextStyles.headingSm()),
        const SizedBox(height: NileSpacing.s16),
      ],
      ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.md),
        child: preview,
      ),
      if (controls != null) ...[
        const SizedBox(height: NileSpacing.s12),
        controls!,
      ],
      const SizedBox(height: NileSpacing.s24),
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'From your profile',
        ),
        child: Text(name, style: NileTextStyles.bodyMd()),
      ),
      const SizedBox(height: NileSpacing.s16),
      TextField(
        controller: titleController,
        maxLength: 60,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Title (optional)',
          hintText: 'e.g. Director',
        ),
      ),
      const SizedBox(height: NileSpacing.s8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 16, color: NileColors.txtSecondary),
          const SizedBox(width: NileSpacing.s8),
          Expanded(
            child: Text(
              'Only the host and crew can see and hear you until you’re '
              'brought on stage.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
        ],
      ),
      if (error != null) ...[
        const SizedBox(height: NileSpacing.s16),
        Text(
          error!,
          style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
        ),
      ],
      const SizedBox(height: NileSpacing.s24),
      FilledButton(
        onPressed: joining ? null : onJoin,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          backgroundColor: NileColors.volt,
          foregroundColor: NileColors.onVolt,
        ),
        child: joining
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Join green room'),
      ),
    ],
  );
}

/// "You're on in 5…" — shown over everything when the host brings you on.
class GuestCountdown extends StatelessWidget {
  const GuestCountdown({super.key, required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'You’re on in',
        style: NileTextStyles.headingSm().copyWith(color: Colors.white),
      ),
      const SizedBox(height: NileSpacing.s8),
      AnimatedSwitcher(
        duration: NileMotion.fast,
        child: Text(
          '$seconds',
          key: ValueKey(seconds),
          style: NileTextStyles.displayLg().copyWith(color: NileColors.volt),
        ),
      ),
      const SizedBox(height: NileSpacing.s8),
      Text(
        'Get ready',
        style: NileTextStyles.bodyMd().copyWith(color: Colors.white70),
      ),
    ],
  );
}

/// Connection, mic and camera at a glance.
class GuestHealthRow extends StatelessWidget {
  const GuestHealthRow({
    super.key,
    required this.quality,
    required this.micOn,
    required this.cameraOn,
    this.reconnecting = false,
  });

  final ConnectionQuality quality;
  final bool micOn;
  final bool cameraOn;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final (label, color) = reconnecting
        ? ('Reconnecting…', NileColors.warning)
        : switch (quality) {
            ConnectionQuality.excellent => (
              'Connection excellent',
              NileColors.success,
            ),
            ConnectionQuality.good => ('Connection good', NileColors.success),
            ConnectionQuality.poor => ('Connection poor', NileColors.warning),
            ConnectionQuality.lost => ('Connection lost', NileColors.error),
            ConnectionQuality.unknown => (
              'Checking connection',
              NileColors.txtTertiary,
            ),
          };
    return Wrap(
      spacing: NileSpacing.s8,
      runSpacing: NileSpacing.s8,
      children: [
        _Chip(icon: Icons.network_check, label: label, color: color),
        _Chip(
          icon: micOn ? Icons.mic : Icons.mic_off,
          label: micOn ? 'Mic on' : 'Mic muted',
          color: micOn ? NileColors.success : NileColors.error,
        ),
        _Chip(
          icon: cameraOn ? Icons.videocam : Icons.videocam_off,
          label: cameraOn ? 'Camera on' : 'Camera off',
          color: cameraOn ? NileColors.success : NileColors.txtTertiary,
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s8,
      vertical: NileSpacing.s4,
    ),
    decoration: BoxDecoration(
      color: NileColors.bgRaised,
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: NileSpacing.s4),
        Text(label, style: NileTextStyles.caption()),
      ],
    ),
  );
}

/// "The host is talking to you" — the backstage line is open to this guest.
class GuestTalkbackPill extends StatelessWidget {
  const GuestTalkbackPill({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s12,
      vertical: NileSpacing.s6,
    ),
    decoration: BoxDecoration(
      color: NileColors.volt,
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.record_voice_over, size: 16, color: NileColors.onVolt),
        const SizedBox(width: NileSpacing.s6),
        Text(
          'The host is talking to you',
          style: NileTextStyles.labelSm().copyWith(color: NileColors.onVolt),
        ),
      ],
    ),
  );
}

/// The guest's buttons. Null callbacks hide their button.
class GuestControlBar extends StatelessWidget {
  const GuestControlBar({
    super.key,
    required this.micOn,
    required this.cameraOn,
    required this.onMic,
    required this.onCamera,
    required this.onLeave,
    this.devicePickers = const [],
    this.onFlip,
    this.sharing = false,
    this.onShare,
    this.showAudioMuted = false,
    this.onShowAudio,
    this.onNameTag,
    this.chatUnread = 0,
    this.onChat,
  });

  final bool micOn;
  final bool cameraOn;
  final VoidCallback onMic;
  final VoidCallback onCamera;
  final VoidCallback? onLeave;

  /// Camera and mic menus (iPad and Mac), from nile_studio.dart.
  final List<Widget> devicePickers;
  final VoidCallback? onFlip;
  final bool sharing;
  final VoidCallback? onShare;
  final bool showAudioMuted;
  final VoidCallback? onShowAudio;
  final VoidCallback? onNameTag;
  final int chatUnread;
  final VoidCallback? onChat;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: NileSpacing.s8,
    runSpacing: NileSpacing.s8,
    children: [
      NileStudioIconButton(
        onPressed: onMic,
        tooltip: micOn ? 'Mute mic' : 'Unmute mic',
        icon: micOn ? Icons.mic : Icons.mic_off,
        active: !micOn,
      ),
      NileStudioIconButton(
        onPressed: onCamera,
        tooltip: cameraOn ? 'Turn camera off' : 'Turn camera on',
        icon: cameraOn ? Icons.videocam : Icons.videocam_off,
        active: !cameraOn,
      ),
      if (onFlip != null)
        NileStudioIconButton(
          onPressed: onFlip,
          tooltip: 'Flip camera',
          icon: Icons.flip_camera_ios_outlined,
        ),
      ...devicePickers,
      if (onShare != null)
        NileStudioIconButton(
          onPressed: onShare,
          tooltip: sharing ? 'Stop sharing screen' : 'Share screen',
          icon: sharing
              ? Icons.stop_screen_share_outlined
              : Icons.screen_share_outlined,
          active: sharing,
        ),
      if (onShowAudio != null)
        NileStudioIconButton(
          onPressed: onShowAudio,
          tooltip: showAudioMuted ? 'Unmute show audio' : 'Mute show audio',
          icon: showAudioMuted ? Icons.volume_off : Icons.volume_up,
          active: showAudioMuted,
        ),
      if (onNameTag != null)
        NileStudioIconButton(
          onPressed: onNameTag,
          tooltip: 'Edit name tag',
          icon: Icons.badge_outlined,
        ),
      if (onChat != null)
        Badge(
          isLabelVisible: chatUnread > 0,
          label: Text('$chatUnread'),
          child: NileStudioIconButton(
            onPressed: onChat,
            tooltip: 'Backstage chat',
            icon: Icons.chat_bubble_outline,
          ),
        ),
      if (onLeave != null)
        FilledButton.icon(
          onPressed: onLeave,
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.error,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.logout),
          label: const Text('Leave'),
        ),
    ],
  );
}

/// Backstage chat: host, crew and guests only. Nothing is stored.
class GuestChatPanel extends StatefulWidget {
  const GuestChatPanel({
    super.key,
    required this.messages,
    required this.onSend,
  });

  /// Newest last.
  final List<BackstageMessage> messages;
  final ValueChanged<String> onSend;

  @override
  State<GuestChatPanel> createState() => _GuestChatPanelState();
}

class _GuestChatPanelState extends State<GuestChatPanel> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final msgs = widget.messages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Backstage chat', style: NileTextStyles.labelMd()),
        Text(
          'Only the host, crew and guests see this.',
          style: NileTextStyles.caption(),
        ),
        const SizedBox(height: NileSpacing.s8),
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Text(
                    'No messages yet',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[msgs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: NileSpacing.s4,
                      ),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: m.mine ? 'You  ' : '${m.name}  ',
                              style: NileTextStyles.labelSm().copyWith(
                                color: m.mine
                                    ? NileColors.volt
                                    : NileColors.txtSecondary,
                              ),
                            ),
                            TextSpan(
                              text: m.text,
                              style: NileTextStyles.bodySm(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                maxLength: BackstageMessage.maxLength,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Message the host',
                  counterText: '',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Send',
              onPressed: _send,
              icon: const Icon(Icons.send_rounded),
              color: NileColors.volt,
            ),
          ],
        ),
      ],
    );
  }
}

/// A full-screen message: removed, ended, a bad link, the host's own link.
class GuestNotice extends StatelessWidget {
  const GuestNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NileSpacing.s40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: NileColors.txtTertiary),
          const SizedBox(height: NileSpacing.s16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: NileTextStyles.headingSm(),
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: NileSpacing.s24),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
