import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../router.dart';
import '../services/ad_service.dart';
import '../services/mfa_service.dart';
import '../services/payout_service.dart';
import '../services/tip_service.dart';
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
  TipEarnings? _tips;
  TicketEarnings? _tickets;
  SponsorshipEarnings? _sponsorships;
  int _pendingOffers = 0;
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
      final tips = await TipService.hostEarnings().catchError(
        (_) => const TipEarnings(grossCents: 0, feeCents: 0, count: 0),
      );
      final tickets = await PayoutService.ticketEarnings()
          .catchError((_) => TicketEarnings.empty);
      final sponsorships = await PayoutService.sponsorshipEarnings()
          .catchError((_) => SponsorshipEarnings.empty);
      // Already best-effort (returns 0 on failure), so no catchError here.
      final offers = await AdService.hostOfferCount();
      if (mounted) {
        setState(() {
          _status = s;
          _tips = tips;
          _tickets = tickets;
          _sponsorships = sponsorships;
          _pendingOffers = offers;
        });
      }
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
    // 2FA is mandatory before a host can set up payouts. Gate here (the server
    // enforces it too); if they aren't enrolled, route through setup first.
    if (!await MfaService.hasVerifiedFactor()) {
      if (!mounted) return;
      final enrolled = await context.push<bool>(NileRoutes.mfaConnectGate);
      if (enrolled != true) return;
    }
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
      return Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }

    final s = _status!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
      children: [
        _StatusCard(status: s),
        const SizedBox(height: 12),
        // Above the earnings cards on purpose: those are money already made,
        // this is money on a 48-hour fuse.
        _OffersCard(
          count: _pendingOffers,
          onTap: () async {
            await context.push(NileRoutes.sponsorshipOffers());
            if (context.mounted) await _load();
          },
        ),
        if (_tickets?.hasSales ?? false) ...[
          const SizedBox(height: 12),
          _TicketsCard(tickets: _tickets!),
        ],
        if (_tips?.hasTips ?? false) ...[
          const SizedBox(height: 12),
          _TipsCard(tips: _tips!),
        ],
        if (_sponsorships?.hasEarnings ?? false) ...[
          const SizedBox(height: 12),
          _SponsorshipsCard(sponsorships: _sponsorships!),
        ],
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
          'Nile uses Stripe to pay out ticket and tip revenue. Setup opens in your '
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

String _money(int cents) {
  final d = cents / 100;
  return d == d.roundToDouble()
      ? '\$${d.toStringAsFixed(0)}'
      : '\$${d.toStringAsFixed(2)}';
}

/// Entry point to the offers screen, with the pending count as a badge.
///
/// Shown even at zero: this is the only way into the screen from Settings, and
/// a host who has just switched an event to "open to sponsorship" needs
/// somewhere to look that says the feature is working rather than broken.
class _OffersCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _OffersCard({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final waiting = count > 0;
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s16),
          child: Row(
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                color: waiting ? NileColors.volt : NileColors.txtTertiary,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sponsorship offers',
                      style: NileTextStyles.headingSm(),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      waiting
                          ? '$count ${count == 1 ? 'offer' : 'offers'} waiting '
                                'for your decision'
                          : 'Nothing waiting right now',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (waiting)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s8,
                    vertical: NileSpacing.s2,
                  ),
                  decoration: BoxDecoration(
                    color: NileColors.volt,
                    borderRadius: BorderRadius.circular(NileRadius.pill),
                  ),
                  child: Text(
                    '$count',
                    style: NileTextStyles.labelSm().copyWith(
                      color: NileColors.onVolt,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              const SizedBox(width: NileSpacing.s8),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: NileColors.txtTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TicketsCard extends StatelessWidget {
  final TicketEarnings tickets;
  const _TicketsCard({required this.tickets});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.confirmation_number_outlined,
                  color: NileColors.volt, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tickets earned', style: NileTextStyles.headingSm()),
                    const SizedBox(height: 4),
                    Text(
                      '${tickets.count} ${tickets.count == 1 ? 'sale' : 'sales'} · '
                      '${_money(tickets.lifetimeGrossCents)} in sales · '
                      '${_money(tickets.monthNetCents)} this month',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _money(tickets.lifetimeNetCents),
                style: NileTextStyles.headingSm()
                    .copyWith(color: NileColors.volt),
              ),
            ],
          ),
          // Sales made before the host finished Stripe onboarding land on the
          // platform account, so the money is earned but hasn't moved. It used
          // to be invisible here — and, until migration 0092, counted as $0.
          if (tickets.hasPendingTransfer) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(NileSpacing.s12),
              decoration: BoxDecoration(
                color: NileColors.bgRaised,
                borderRadius: BorderRadius.circular(NileRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: NileColors.txtSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_money(tickets.fallbackOwedCents)} of this was sold '
                      'before your payout account was ready, so we transfer it '
                      'to you manually. Nothing is lost.',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  final TipEarnings tips;
  const _TipsCard({required this.tips});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Row(
        children: [
          Icon(Icons.volunteer_activism, color: NileColors.volt, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tips earned', style: NileTextStyles.headingSm()),
                const SizedBox(height: 4),
                Text(
                  '${tips.count} ${tips.count == 1 ? 'tip' : 'tips'} · '
                  '${_money(tips.feeCents)} platform fee',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _money(tips.netCents),
            style: NileTextStyles.headingSm().copyWith(color: NileColors.volt),
          ),
        ],
      ),
    );
  }
}

class _SponsorshipsCard extends StatelessWidget {
  final SponsorshipEarnings sponsorships;
  const _SponsorshipsCard({required this.sponsorships});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Row(
        children: [
          Icon(Icons.workspace_premium, color: NileColors.volt, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sponsorships earned', style: NileTextStyles.headingSm()),
                const SizedBox(height: 4),
                Text(
                  '${sponsorships.count} '
                  '${sponsorships.count == 1 ? 'event' : 'events'} · '
                  '${_money(sponsorships.monthNetCents)} this month',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _money(sponsorships.lifetimeNetCents),
            style: NileTextStyles.headingSm().copyWith(color: NileColors.volt),
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
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: NileColors.onVolt,
                ),
              )
            : Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}
