import 'package:flutter/material.dart';
import '../../services/block_service.dart';
import '../../services/report_service.dart';
import '../../theme.dart';

/// Shared block/report UI used on profiles, posts, events, and comments.
///
/// All entry points are static helpers so screens stay thin:
///   • [showReportSheet]  — reason picker + optional note, submits a report.
///   • [confirmBlock]     — confirm dialog, then blocks the user.
///   • [confirmUnblock]   — confirm dialog, then unblocks the user.
class Moderation {
  Moderation._();

  // ── Report ────────────────────────────────────────────────────────────────

  /// Opens the report sheet. Returns true if a report was submitted.
  static Future<bool> showReportSheet(
    BuildContext context, {
    required ReportTargetType targetType,
    required String targetId,
  }) async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NileRadius.lg),
        ),
      ),
      builder: (_) => _ReportSheet(targetType: targetType, targetId: targetId),
    );
    if (submitted == true && context.mounted) {
      _toast(context, 'Report submitted. Thanks for letting us know.');
    }
    return submitted == true;
  }

  // ── Block / unblock ─────────────────────────────────────────────────────────

  /// Confirms and blocks [userId]. Returns true if the block was applied.
  static Future<bool> confirmBlock(
    BuildContext context, {
    required String userId,
    required String username,
  }) async {
    final ok = await _confirm(
      context,
      title: 'Block @$username?',
      message:
          'They won\'t be able to see your profile, posts, or events, and you '
          'won\'t see theirs. Any follows between you will be removed.',
      confirmLabel: 'Block',
      destructive: true,
    );
    if (!ok) return false;
    try {
      await BlockService.block(userId);
      if (context.mounted) _toast(context, 'Blocked @$username.');
      return true;
    } catch (e) {
      if (context.mounted) _toast(context, 'Couldn\'t block: $e');
      return false;
    }
  }

  /// Confirms and unblocks [userId]. Returns true if the unblock was applied.
  static Future<bool> confirmUnblock(
    BuildContext context, {
    required String userId,
    required String username,
  }) async {
    final ok = await _confirm(
      context,
      title: 'Unblock @$username?',
      message:
          'You\'ll be able to see each other again. Follows are not '
          'restored automatically.',
      confirmLabel: 'Unblock',
      destructive: false,
    );
    if (!ok) return false;
    try {
      await BlockService.unblock(userId);
      if (context.mounted) _toast(context, 'Unblocked @$username.');
      return true;
    } catch (e) {
      if (context.mounted) _toast(context, 'Couldn\'t unblock: $e');
      return false;
    }
  }

  // ── Shared bits ──────────────────────────────────────────────────────────

  static void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required bool destructive,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: NileColors.bgSurface,
            title: Text(title, style: NileTextStyles.headingSm()),
            content: Text(
              message,
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: destructive
                      ? NileColors.error
                      : NileColors.volt,
                ),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ==
        true;
  }
}

// ── Report sheet ──────────────────────────────────────────────────────────────

class _ReportSheet extends StatefulWidget {
  final ReportTargetType targetType;
  final String targetId;
  const _ReportSheet({required this.targetType, required this.targetId});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  final _note = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String get _targetNoun => switch (widget.targetType) {
    ReportTargetType.user => 'account',
    ReportTargetType.post => 'post',
    ReportTargetType.event => 'event',
    ReportTargetType.comment => 'comment',
    ReportTargetType.ad => 'ad',
    ReportTargetType.current => 'Current',
    ReportTargetType.currentComment => 'comment',
    ReportTargetType.liveChatMessage => 'message',
  };

  Future<void> _submit() async {
    if (_reason == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      await ReportService.submit(
        targetType: widget.targetType,
        targetId: widget.targetId,
        reason: _reason!,
        note: _note.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t submit: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s16, NileSpacing.s24, NileSpacing.s24 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: NileColors.border,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Report $_targetNoun', style: NileTextStyles.headingMd()),
            const SizedBox(height: 4),
            Text(
              'Why are you reporting this $_targetNoun?',
              style: NileTextStyles.bodySm(),
            ),
            const SizedBox(height: 16),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) {
                if (_submitting) return;
                setState(() => _reason = v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: ReportReason.values
                    .map(
                      (r) => RadioListTile<ReportReason>(
                        value: r,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        activeColor: NileColors.volt,
                        title: Text(r.label, style: NileTextStyles.bodyMd()),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              enabled: !_submitting,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              style: NileTextStyles.bodyMd(),
              decoration: const InputDecoration(
                hintText: 'Add details (optional)',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _reason == null || _submitting ? null : _submit,
              child: _submitting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NileColors.onVolt,
                      ),
                    )
                  : const Text('Submit report'),
            ),
          ],
        ),
      ),
    );
  }
}
