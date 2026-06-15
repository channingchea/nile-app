import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/payout_service.dart';
import '../theme.dart';

/// Host Stripe Connect payouts hub: shows onboarding status and links out to
/// the hosted onboarding flow / Stripe Express dashboard.
class PayoutsScreen extends StatefulWidget {
  const PayoutsScreen({super.key});

  @override
  State<PayoutsScreen> createState() => _PayoutsScreenState();
}

class _PayoutsScreenState extends State<PayoutsScreen> {
  PayoutStatus? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _status = null;
      _error = null;
    });
    try {
      final s = await PayoutService.status();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't open link")));
    }
  }

  Future<void> _startOnboarding() async {
    setState(() => _busy = true);
    try {
      final url = await PayoutService.startOnboarding();
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t start setup: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Payouts')),
      body: NileMaxWidth(
        child: RefreshIndicator(
          onRefresh: _load,
          color: NileColors.volt,
          backgroundColor: NileColors.bgSurface,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _scroll(
        Text(
          'Couldn\'t load payout status.\n$_error',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
      );
    }
    if (_status == null) {
      return const Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }

    final s = _status!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
      children: [
        _StatusCard(status: s),
        const SizedBox(height: 20),
        if (s.isActive) ...[
          if (s.dashboardUrl != null)
            _ActionButton(
              label: 'Open Stripe dashboard',
              icon: Icons.open_in_new,
              onPressed: () => _openExternal(s.dashboardUrl!),
            ),
        ] else
          _ActionButton(
            label: s.isPending ? 'Continue setup' : 'Set up payouts',
            icon: Icons.account_balance_outlined,
            busy: _busy,
            onPressed: _busy ? null : _startOnboarding,
          ),
        const SizedBox(height: 16),
        Text(
          'Nile uses Stripe to pay out ticket revenue. Setup opens in your '
          'browser; pull down to refresh once you\'re done.',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      ],
    );
  }

  Widget _scroll(Widget child) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      SizedBox(height: MediaQuery.of(context).size.height * 0.3),
      Center(
        child: Padding(padding: const EdgeInsets.all(NileSpacing.s24), child: child),
      ),
    ],
  );
}

class _StatusCard extends StatelessWidget {
  final PayoutStatus status;
  const _StatusCard({required this.status});

  @override
  Widget build(BuildContext context) {
    late final Color dot;
    late final String title;
    late final String subtitle;

    if (status.isActive) {
      dot = NileColors.volt;
      title = 'Payouts active';
      subtitle = 'Your account is connected and can receive payouts.';
    } else if (status.isPending) {
      dot = NileColors.coral;
      title = status.detailsSubmitted ? 'Under review' : 'Setup incomplete';
      subtitle = status.detailsSubmitted
          ? 'Stripe is verifying your details. This can take a little while.'
          : 'Finish connecting your account to start receiving payouts.';
    } else {
      dot = NileColors.txtTertiary;
      title = 'Not connected';
      subtitle = 'Connect a Stripe account to receive ticket revenue.';
    }

    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s4),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: NileTextStyles.headingSm()),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;
  const _ActionButton({
    required this.label,
    required this.icon,
    this.busy = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: NileColors.bgPage,
                ),
              )
            : Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}
