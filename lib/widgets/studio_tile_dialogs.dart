import 'package:flutter/material.dart';

import '../services/camera_status.dart';
import '../theme.dart';
import 'nile_studio.dart' show NileStudioSource;

/// "Nudge operator…": a preset or up to 80 characters of your own. Returns
/// the text to send, or null when cancelled.
Future<String?> showNudgeDialog(BuildContext context, String cameraLabel) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NudgeDialog(cameraLabel: cameraLabel),
    );

class _NudgeDialog extends StatefulWidget {
  const _NudgeDialog({required this.cameraLabel});
  final String cameraLabel;

  @override
  State<_NudgeDialog> createState() => _NudgeDialogState();
}

class _NudgeDialogState extends State<_NudgeDialog> {
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _sendCustom() {
    final text = cleanNudge(_custom.text);
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: NileColors.bgSurface,
    title: Text('Nudge ${widget.cameraLabel}', style: NileTextStyles.headingMd()),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Shows on their phone with a buzz. They tap 👍 when they’ve seen it.',
            style: NileTextStyles.bodySm().copyWith(color: NileColors.txtSecondary),
          ),
          const SizedBox(height: NileSpacing.s12),
          Wrap(
            spacing: NileSpacing.s8,
            runSpacing: NileSpacing.s8,
            children: [
              for (final p in NudgePresets.all)
                ActionChip(
                  label: Text(p),
                  onPressed: () => Navigator.pop(context, p),
                  backgroundColor: NileColors.bgRaised,
                  side: BorderSide(color: NileColors.border),
                  labelStyle: NileTextStyles.labelMd(),
                ),
            ],
          ),
          const SizedBox(height: NileSpacing.s16),
          TextField(
            controller: _custom,
            maxLength: NudgePresets.maxLength,
            style: NileTextStyles.bodyMd(),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendCustom(),
            decoration: const InputDecoration(labelText: 'Or write your own'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: cleanNudge(_custom.text).isEmpty ? null : _sendCustom,
        style: FilledButton.styleFrom(
          backgroundColor: NileColors.volt,
          foregroundColor: NileColors.onVolt,
        ),
        child: const Text('Send'),
      ),
    ],
  );
}

/// "Remote controls…" on a camera tile: flip, flashlight, zoom, focus and
/// exposure lock. Each control works straight away and the operator's phone
/// tells them what changed. Greyed where the phone said it can't.
Future<void> showRemoteControls(
  BuildContext context, {
  required NileStudioSource source,
  required void Function(StudioCommand command) onCommand,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RemoteControls(source: source, onCommand: onCommand),
);

class _RemoteControls extends StatefulWidget {
  const _RemoteControls({required this.source, required this.onCommand});
  final NileStudioSource source;
  final void Function(StudioCommand command) onCommand;

  @override
  State<_RemoteControls> createState() => _RemoteControlsState();
}

class _RemoteControlsState extends State<_RemoteControls> {
  late final CameraHealth? _h = widget.source.health;
  late bool _torch = _h?.torchOn ?? false;
  late double _zoom = _h?.zoom ?? 1;
  late bool _focus = _h?.focusLocked ?? false;
  late bool _exposure = _h?.exposureLocked ?? false;

  static const maxZoom = 3.0;

  CameraCaps get _caps => _h?.caps ?? const CameraCaps();

  void _send(StudioCommand c) => widget.onCommand(c);

  Widget _unsupported(String what) => Text(
    '$what isn’t available on this camera.',
    style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
  );

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text(
        'Remote controls · ${widget.source.label}',
        style: NileTextStyles.headingMd(),
      ),
      content: SizedBox(
        width: 380,
        child: _h == null
            ? Text(
                'This camera hasn’t said what it supports yet. It may be on an '
                'older version of Nile.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Changes happen right away, and the operator is told.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                  const SizedBox(height: NileSpacing.s12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: caps.flip
                          ? () => _send(const FlipCommand())
                          : null,
                      icon: const Icon(Icons.flip_camera_ios_outlined),
                      label: const Text('Flip camera'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Flashlight', style: NileTextStyles.bodyMd()),
                    subtitle: caps.torch ? null : _unsupported('A flashlight'),
                    value: _torch,
                    activeThumbColor: NileColors.volt,
                    onChanged: caps.torch
                        ? (v) {
                            setState(() => _torch = v);
                            _send(TorchCommand(v));
                          }
                        : null,
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Row(
                    children: [
                      Text('Zoom', style: NileTextStyles.bodyMd()),
                      const Spacer(),
                      SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1×')),
                          ButtonSegment(value: 2, label: Text('2×')),
                          ButtonSegment(value: 3, label: Text('3×')),
                        ],
                        emptySelectionAllowed: true,
                        selected: {
                          if ([1.0, 2.0, 3.0].contains(_zoom)) _zoom,
                        },
                        onSelectionChanged: caps.zoom
                            ? (s) {
                                if (s.isEmpty) return;
                                setState(() => _zoom = s.first);
                                _send(ZoomCommand(s.first));
                              }
                            : null,
                      ),
                    ],
                  ),
                  Slider(
                    value: _zoom.clamp(1, maxZoom),
                    min: 1,
                    max: maxZoom,
                    divisions: 20,
                    label: zoomLabel(_zoom),
                    activeColor: NileColors.volt,
                    onChanged: caps.zoom
                        ? (v) => setState(() => _zoom = v)
                        : null,
                    onChangeEnd: caps.zoom ? (v) => _send(ZoomCommand(v)) : null,
                  ),
                  if (!caps.zoom) _unsupported('Zoom'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Lock focus', style: NileTextStyles.bodyMd()),
                    subtitle: caps.focusLock ? null : _unsupported('Focus lock'),
                    value: _focus,
                    activeThumbColor: NileColors.volt,
                    onChanged: caps.focusLock
                        ? (v) {
                            setState(() => _focus = v);
                            _send(LockCommand(focus: v, exposure: _exposure));
                          }
                        : null,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Lock exposure', style: NileTextStyles.bodyMd()),
                    subtitle: caps.exposureLock
                        ? null
                        : _unsupported('Exposure lock'),
                    value: _exposure,
                    activeThumbColor: NileColors.volt,
                    onChanged: caps.exposureLock
                        ? (v) {
                            setState(() => _exposure = v);
                            _send(LockCommand(focus: _focus, exposure: v));
                          }
                        : null,
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
