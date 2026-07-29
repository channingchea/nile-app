import 'package:flutter/material.dart';

import '../services/feedback_service.dart';
import '../theme.dart';

/// Read-only view of one of your own reports, opened from the "resolved"
/// notification. The admin note IS the reply — there's no thread to continue,
/// so this is a receipt, not a conversation.
class MyReportScreen extends StatefulWidget {
  const MyReportScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<MyReportScreen> createState() => _MyReportScreenState();
}

class _MyReportScreenState extends State<MyReportScreen> {
  FeedbackReport? _report;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await FeedbackService.byId(widget.reportId);
      if (!mounted) return;
      setState(() => _report = r);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load that report.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Your report')),
      body: NileMaxWidth(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    final r = _report;
    if (_error != null || r == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error ?? 'That report is no longer available.',
              style: NileTextStyles.bodyMd()
                  .copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: NileSpacing.s12),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16,
          NileSpacing.s16, NileSpacing.s32),
      children: [
        Row(
          children: [
            Icon(
              r.kind == FeedbackKind.bug
                  ? Icons.bug_report_outlined
                  : Icons.lightbulb_outline,
              size: 18,
              color: NileColors.txtTertiary,
            ),
            const SizedBox(width: NileSpacing.s8),
            Text(
              r.kind.label.toUpperCase(),
              style: NileTextStyles.labelSm()
                  .copyWith(color: NileColors.txtTertiary),
            ),
            const Spacer(),
            _statusChip(r.status),
          ],
        ),
        const SizedBox(height: NileSpacing.s12),
        Text(r.title, style: NileTextStyles.headingSm()),
        const SizedBox(height: NileSpacing.s8),
        Text(
          r.body,
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        if (r.adminNote != null && r.adminNote!.trim().isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s24),
          Container(
            padding: const EdgeInsets.all(NileSpacing.s16),
            decoration: BoxDecoration(
              color: NileColors.bgSurface,
              borderRadius: BorderRadius.circular(NileRadius.lg),
              border: Border.all(color: NileColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FROM THE NILE TEAM',
                  style: NileTextStyles.labelSm()
                      .copyWith(color: NileColors.txtTertiary),
                ),
                const SizedBox(height: NileSpacing.s8),
                Text(r.adminNote!, style: NileTextStyles.bodyMd()),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _statusChip(FeedbackStatus s) {
    final color = switch (s) {
      FeedbackStatus.resolved => NileColors.volt,
      FeedbackStatus.wontFix => NileColors.txtTertiary,
      _ => NileColors.azure,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s8, vertical: NileSpacing.s2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Text(
        s.label,
        style: NileTextStyles.caption().copyWith(color: color),
      ),
    );
  }
}
