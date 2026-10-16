import 'package:flutter/material.dart';

import '../services/studio_prefs.dart';
import '../theme.dart';

/// The camera screen's Settings sheet, shared by the real Studio, the phone
/// layout and Studio Preview so all three offer the same switches.
///
/// State is read through getters rather than passed as values: flipping the
/// external-mic switch republishes the mic, and the sheet has to redraw both
/// as the change starts and when it lands.
///
/// [prefs] adds the Studio-only "Start with camera off" switch. The phone
/// layout passes null and gets exactly the sheet it always had.
Future<void> showStudioSettingsSheet(
  BuildContext context, {
  required bool Function() externalMic,
  required bool Function() switchingMic,
  required bool externalMicConnected,
  required bool connected,
  required Future<void> Function(bool enabled) onExternalMic,
  StudioPrefs? prefs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NileColors.bgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
    ),
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final disableAgc = externalMic();
          final switching = switchingMic();
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                32 + MediaQuery.of(sheetCtx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Settings', style: NileTextStyles.headingMd()),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          'Use external mic processing',
                          style: NileTextStyles.bodyLg(),
                        ),
                      ),
                      Switch(
                        value: disableAgc,
                        activeThumbColor: NileColors.volt,
                        onChanged: switching
                            ? null
                            : (v) {
                                final done = onExternalMic(v);
                                setSheetState(() {});
                                done.whenComplete(() {
                                  if (sheetCtx.mounted) setSheetState(() {});
                                });
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Off by default, this leaves automatic gain control, noise '
                    'reduction, and echo cancellation on — best for your phone\'s '
                    'built-in mic. Turn it on when a compatible USB-C or wireless '
                    'mic is connected: the phone\'s processing steps aside so the '
                    'mic\'s own tuning comes through cleanly, usually improving '
                    'audio quality.',
                    style: NileTextStyles.bodyMd().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                  if (externalMicConnected && !disableAgc) ...[
                    const SizedBox(height: 12),
                    Text(
                      'External mic detected — turning this on is recommended.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.volt,
                      ),
                    ),
                  ],
                  if (connected) ...[
                    const SizedBox(height: 12),
                    Text(
                      switching
                          ? 'Switching mic…'
                          : 'Changes apply immediately (brief audio gap while switching).',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.amber,
                      ),
                    ),
                  ],
                  if (prefs != null) ...[
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            'Start with camera off',
                            style: NileTextStyles.bodyLg(),
                          ),
                        ),
                        Switch(
                          value: prefs.videoStartsOff,
                          activeThumbColor: NileColors.volt,
                          onChanged: (v) =>
                              setSheetState(() => prefs.videoStartsOff = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sound Check opens with your video off until you turn it '
                      'on. Saved on this device.',
                      style: NileTextStyles.bodyMd().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
