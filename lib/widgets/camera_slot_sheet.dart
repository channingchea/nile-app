import 'package:flutter/material.dart';

import '../services/livekit_service.dart';
import '../theme.dart';

/// What the host's phone answered to "Which camera is this?".
class CameraSlotChoice {
  const CameraSlotChoice.slot(CameraSlot this.slot) : streamAudio = false;
  const CameraSlotChoice.streamAudio() : slot = null, streamAudio = true;

  final CameraSlot? slot;
  final bool streamAudio;
}

/// "Which camera is this?" — the host's phone picks one of the event's camera
/// slots (or Stream Audio) instead of typing a camera name. Slots another
/// device is on are shown with who has them, and can't be picked. Null when
/// dismissed.
Future<CameraSlotChoice?> showCameraSlotSheet(
  BuildContext context, {
  required Future<CameraSlots> Function() load,
  required String myIdentity,
}) {
  final slots = load(); // once — not on every rebuild of the sheet
  return showModalBottomSheet<CameraSlotChoice>(
    context: context,
    backgroundColor: NileColors.bgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
    ),
    builder: (ctx) => SafeArea(
      child: FutureBuilder<CameraSlots>(
        future: slots,
        builder: (ctx, snap) {
          final data = snap.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s24,
                  NileSpacing.s24,
                  NileSpacing.s24,
                  NileSpacing.s4,
                ),
                child: Text(
                  'Which camera is this?',
                  style: NileTextStyles.headingMd(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s24,
                ),
                child: Text(
                  'Pick the spot this device is filming from.',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
              ),
              const SizedBox(height: NileSpacing.s12),
              if (snap.hasError)
                _Message(
                  'Couldn’t load this event’s cameras. Check your connection '
                  'and try again.',
                )
              else if (data == null)
                const Padding(
                  padding: EdgeInsets.all(NileSpacing.s32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                // An event created before camera slots existed has none —
                // offer a single unnamed camera rather than a dead end.
                if (data.slots.isEmpty)
                  _SlotTile(
                    icon: Icons.videocam_outlined,
                    title: 'Camera 1',
                    onTap: () => Navigator.pop(
                      ctx,
                      const CameraSlotChoice.slot(
                        CameraSlot(id: '', slotIndex: 1, label: 'Camera 1'),
                      ),
                    ),
                  ),
                for (final slot in data.slots)
                  _SlotTile(
                    icon: Icons.videocam_outlined,
                    title: slot.label,
                    subtitle: slot.takenFor(myIdentity)
                        ? 'In use${_who(slot)}'
                        : null,
                    onTap: slot.takenFor(myIdentity)
                        ? null
                        : () => Navigator.pop(ctx, CameraSlotChoice.slot(slot)),
                  ),
                const Divider(height: 1),
                _SlotTile(
                  icon: Icons.graphic_eq,
                  title: 'Stream Audio',
                  subtitle: data.streamAudioTaken
                      ? 'In use on another device'
                      : 'This device carries the show’s sound',
                  onTap: data.streamAudioTaken
                      ? null
                      : () => Navigator.pop(
                          ctx,
                          const CameraSlotChoice.streamAudio(),
                        ),
                ),
              ],
              const SizedBox(height: NileSpacing.s12),
            ],
          );
        },
      ),
    ),
  );
}

String _who(CameraSlot slot) {
  final parts = [
    if (slot.heldByUsername != null) '@${slot.heldByUsername}',
    if (slot.heldByDevice != null) slot.heldByDevice!,
  ];
  return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? NileColors.txtPrimary : NileColors.txtTertiary;
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
      leading: Icon(icon, color: fg),
      title: Text(title, style: NileTextStyles.bodyLg().copyWith(color: fg)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
      trailing: enabled
          ? Icon(Icons.chevron_right, color: NileColors.txtTertiary)
          : null,
      onTap: onTap,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(NileSpacing.s24),
    child: Text(
      text,
      style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
    ),
  );
}

/// Rename a camera. Returns the trimmed new name (1–40 characters), or null
/// when cancelled.
Future<String?> showRenameCameraDialog(
  BuildContext context, {
  required String current,
}) async {
  final controller = TextEditingController(text: current);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final v = controller.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (v.isNotEmpty) Navigator.pop(ctx, v);
      }

      return AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Rename camera', style: NileTextStyles.headingMd()),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: NileTextStyles.bodyLg(),
          decoration: const InputDecoration(hintText: 'e.g. Stage Left'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: submit,
            child: Text(
              'Rename',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return name;
}
