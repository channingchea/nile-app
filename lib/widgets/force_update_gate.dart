import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_config_service.dart';
import '../theme.dart';

/// Wraps the app so a too-old build is caught at startup.
///
/// - Build below `min_build` → replaces the app with a blocking update screen.
/// - Build below `latest_build` → shows a one-time "update available" snackbar
///   over the normal app.
///
/// The check fails open (see [AppConfigService.check]), so a config/network
/// error just renders [child] unchanged.
class ForceUpdateGate extends StatefulWidget {
  final Widget child;
  const ForceUpdateGate({super.key, required this.child});

  @override
  State<ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<ForceUpdateGate> {
  AppUpdateStatus _status = const AppUpdateStatus.ok();

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final status = await AppConfigService.check();
    if (!mounted) return;
    setState(() => _status = status);
    if (status.updateAvailable && !status.blocked) {
      // Non-blocking nudge, once per launch.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('A new version of Nile is available.'),
            action: status.updateUrl == null
                ? null
                : SnackBarAction(
                    label: 'Update',
                    onPressed: () => _openUpdate(status.updateUrl!),
                  ),
          ),
        );
      });
    }
  }

  Future<void> _openUpdate(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_status.blocked) return _BlockedScreen(status: _status);
    return widget.child;
  }
}

class _BlockedScreen extends StatelessWidget {
  final AppUpdateStatus status;
  const _BlockedScreen({required this.status});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(NileSpacing.s40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.system_update_rounded,
                  size: 56,
                  color: NileColors.volt,
                ),
                const SizedBox(height: NileSpacing.s16),
                Text('Update required', style: NileTextStyles.headingMd()),
                const SizedBox(height: NileSpacing.s8),
                Text(
                  status.message ??
                      'This version of Nile is no longer supported. '
                          'Please update to keep going.',
                  textAlign: TextAlign.center,
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                if (status.updateUrl != null) ...[
                  const SizedBox(height: NileSpacing.s24),
                  FilledButton(
                    onPressed: () async {
                      final uri = Uri.tryParse(status.updateUrl!);
                      if (uri != null) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    child: const Text('Update now'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
