import 'package:flutter/material.dart';

import '../config.dart';
import '../services/moderation_notice_service.dart';
import '../theme.dart';
import '../widgets/legal_links.dart';
import '../widgets/nile_glass_app_bar.dart';

/// Every moderation decision taken against you, with the reason given (P3 #35).
///
/// Empty for almost everyone, which is the point: before this, a removal was
/// silent — content simply stopped being visible and nobody was told why.
class ModerationNoticesScreen extends StatefulWidget {
  const ModerationNoticesScreen({super.key});

  @override
  State<ModerationNoticesScreen> createState() => _ModerationNoticesScreenState();
}

class _ModerationNoticesScreenState extends State<ModerationNoticesScreen> {
  late Future<List<ModerationNotice>> _future;

  @override
  void initState() {
    super.initState();
    _future = ModerationNoticeService.mine();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      extendBodyBehindAppBar: true,
      appBar: NileGlassBar.appBar(title: const Text('Content decisions')),
      body: NileMaxWidth(
        child: FutureBuilder<List<ModerationNotice>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final notices = snap.data ?? const <ModerationNotice>[];
            return ListView(
              padding: EdgeInsets.fromLTRB(
                NileSpacing.s16,
                topInset + NileSpacing.s16,
                NileSpacing.s16,
                NileSpacing.s32,
              ),
              children: [
                if (notices.isEmpty)
                  _Empty()
                else
                  ...notices.map((n) => _NoticeCard(notice: n)),
                const SizedBox(height: NileSpacing.s24),
                Text(
                  'Think a decision was wrong? Appeal it and someone who '
                  "wasn't part of the original decision will look again.",
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtTertiary,
                  ),
                ),
                const SizedBox(height: NileSpacing.s12),
                OutlinedButton(
                  onPressed: () => openLegalUrl(appealUrl),
                  child: const Text('Appeal a decision'),
                ),
                const SizedBox(height: NileSpacing.s8),
                TextButton(
                  onPressed: () => openLegalUrl(guidelinesUrl),
                  child: Text(
                    'Read the Community Guidelines',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s32),
      child: Column(
        children: [
          Icon(Icons.verified_outlined, size: 48, color: NileColors.txtTertiary),
          const SizedBox(height: NileSpacing.s16),
          Text('Nothing here', style: NileTextStyles.headingSm()),
          const SizedBox(height: NileSpacing.s8),
          Text(
            "We haven't removed anything you've posted or actioned your "
            'account. If we ever do, the reason will show up here.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final ModerationNotice notice;
  const _NoticeCard({required this.notice});

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.month}/${l.day}/${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    final accent = notice.isReversal ? NileColors.volt : NileColors.error;
    return Container(
      margin: const EdgeInsets.only(bottom: NileSpacing.s12),
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
              Icon(
                notice.isReversal ? Icons.undo : Icons.gavel_outlined,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: NileSpacing.s8),
              Expanded(
                child: Text(notice.headline, style: NileTextStyles.labelLg()),
              ),
              Text(
                _date(notice.createdAt),
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            // A missing note is stated plainly rather than papered over: it is
            // the moderator who skipped the reason, not the app.
            notice.reason?.isNotEmpty == true
                ? notice.reason!
                : 'No reason was recorded. Appeal below and we will explain.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
