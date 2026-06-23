import 'package:flutter/material.dart';
import '../services/ad_service.dart';
import '../theme.dart';

/// Host-only "boost performance" view (Phase A-3): one card per boost campaign
/// the host has run, with impressions, clicks, CTR, and spend vs budget.
/// Reuses the attendee-list screen's summary-card + tile patterns.
class BoostPerformanceScreen extends StatefulWidget {
  const BoostPerformanceScreen({super.key});

  @override
  State<BoostPerformanceScreen> createState() => _BoostPerformanceScreenState();
}

class _BoostPerformanceScreenState extends State<BoostPerformanceScreen> {
  List<BoostStats>? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _stats = null;
      _error = null;
    });
    try {
      final stats = await AdService.boostPerformance();
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Boost performance')),
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
      return _Centered(
        child: Text(
          'Couldn\'t load your boosts.\n$_error',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodySm().copyWith(color: NileColors.txtSecondary),
        ),
      );
    }
    if (_stats == null) {
      return const Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_stats!.isEmpty) {
      return _Centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.campaign_outlined, color: NileColors.txtTertiary, size: 40),
            const SizedBox(height: 12),
            Text(
              'No boosts yet',
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              'Boost an event to promote it in feeds.',
              style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
            ),
          ],
        ),
      );
    }

    final totalImpr = _stats!.fold<int>(0, (s, b) => s + b.impressions);
    final totalSpent = _stats!.fold<int>(0, (s, b) => s + b.spentCents);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileSpacing.s32),
      itemCount: _stats!.length + 1,
      separatorBuilder: (_, i) =>
          i == 0 ? const SizedBox(height: 12) : const SizedBox(height: 8),
      itemBuilder: (_, i) {
        if (i == 0) {
          return _SummaryRow(impressions: totalImpr, spentCents: totalSpent);
        }
        return _BoostTile(stats: _stats![i - 1]);
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final int impressions;
  final int spentCents;
  const _SummaryRow({required this.impressions, required this.spentCents});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Stat(label: 'impressions', value: _compact(impressions)),
        const SizedBox(width: 12),
        _Stat(label: 'total spend', value: '\$${(spentCents / 100).toStringAsFixed(2)}'),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s12, horizontal: NileSpacing.s16),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: NileTextStyles.headingSm()),
            const SizedBox(height: 2),
            Text(label, style: NileTextStyles.caption().copyWith(color: NileColors.txtSecondary)),
          ],
        ),
      ),
    );
  }
}

class _BoostTile extends StatelessWidget {
  final BoostStats stats;
  const _BoostTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    final spend = '\$${(stats.spentCents / 100).toStringAsFixed(2)}';
    final budget = '\$${(stats.budgetCents / 100).toStringAsFixed(2)}';
    final ctr = '${(stats.ctr * 100).toStringAsFixed(1)}%';
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
              Expanded(
                child: Text(
                  stats.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.labelLg(),
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(status: stats.status),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Metric(label: 'impressions', value: _compact(stats.impressions)),
              _Metric(label: 'clicks', value: _compact(stats.clicks)),
              _Metric(label: 'CTR', value: ctr),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '$spend spent of $budget',
            style: NileTextStyles.caption().copyWith(color: NileColors.txtSecondary),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: NileTextStyles.labelLg().copyWith(color: NileColors.volt)),
          const SizedBox(height: 2),
          Text(label, style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' => NileColors.volt,
      'completed' => NileColors.txtTertiary,
      'rejected' => NileColors.coral,
      _ => NileColors.txtSecondary, // pending_payment / pending_review / paused
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: NileTextStyles.caption().copyWith(color: color),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  final Widget child;
  const _Centered({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.3),
        Center(child: Padding(padding: const EdgeInsets.all(NileSpacing.s24), child: child)),
      ],
    );
  }
}

/// 1234 → "1.2k". Keeps stat cards from overflowing on big numbers.
String _compact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}
