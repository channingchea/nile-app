import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import '../theme.dart';

/// Desktop-only dialog listing shareable screens and windows with live
/// thumbnails. Pops with the chosen [rtc.DesktopCapturerSource], or null on
/// cancel. Returning an empty source list usually means macOS Screen
/// Recording permission is missing — the caller handles that case.
class ScreenSharePicker extends StatefulWidget {
  const ScreenSharePicker({super.key});

  /// Shows the picker; null when the user cancels.
  static Future<rtc.DesktopCapturerSource?> show(BuildContext context) {
    return showDialog<rtc.DesktopCapturerSource>(
      context: context,
      builder: (_) => const ScreenSharePicker(),
    );
  }

  @override
  State<ScreenSharePicker> createState() => _ScreenSharePickerState();
}

class _ScreenSharePickerState extends State<ScreenSharePicker> {
  List<rtc.DesktopCapturerSource> _sources = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen, rtc.SourceType.Window],
        thumbnailSize: rtc.ThumbnailSize(320, 180),
      );
      if (mounted) {
        setState(() {
          // Screens first, then windows, each alphabetical.
          _sources = [...sources]..sort((a, b) {
            if (a.type != b.type) {
              return a.type == rtc.SourceType.Screen ? -1 : 1;
            }
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: NileColors.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Share your screen', style: NileTextStyles.headingSm()),
              const SizedBox(height: NileSpacing.s12),
              Flexible(child: _buildBody()),
              const SizedBox(height: NileSpacing.s12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: NileTextStyles.labelMd().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(NileSpacing.s24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(NileSpacing.s16),
        child: Text(
          'No screens found. If this is your first share, macOS may need '
          'Screen Recording permission: System Settings → Privacy & '
          'Security → Screen Recording, then relaunch Nile.',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 16 / 11,
        crossAxisSpacing: NileSpacing.s12,
        mainAxisSpacing: NileSpacing.s12,
      ),
      itemCount: _sources.length,
      itemBuilder: (context, i) => _buildSourceTile(_sources[i]),
    );
  }

  Widget _buildSourceTile(rtc.DesktopCapturerSource source) {
    final thumb = source.thumbnail;
    return InkWell(
      borderRadius: BorderRadius.circular(NileRadius.md),
      onTap: () => Navigator.of(context).pop(source),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: NileColors.bgPage,
                borderRadius: BorderRadius.circular(NileRadius.md),
                border: Border.all(color: NileColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: thumb != null
                  ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                  : Icon(
                      source.type == rtc.SourceType.Screen
                          ? Icons.desktop_mac_outlined
                          : Icons.web_asset,
                      color: NileColors.txtTertiary,
                    ),
            ),
          ),
          const SizedBox(height: NileSpacing.s4),
          Row(
            children: [
              Icon(
                source.type == rtc.SourceType.Screen
                    ? Icons.desktop_mac_outlined
                    : Icons.web_asset,
                size: 14,
                color: NileColors.txtTertiary,
              ),
              const SizedBox(width: NileSpacing.s4),
              Expanded(
                child: Text(
                  source.name,
                  style: NileTextStyles.caption(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
