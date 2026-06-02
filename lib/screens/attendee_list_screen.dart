import 'package:flutter/material.dart';
import '../services/ticket_service.dart';
import '../theme.dart';
import 'profile_screen.dart';
import 'widgets/load_more_footer.dart';

/// Host-only list of paid attendees for an event.
class AttendeeListScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;

  const AttendeeListScreen({
    super.key,
    required this.eventId,
    required this.eventTitle,
  });

  @override
  State<AttendeeListScreen> createState() => _AttendeeListScreenState();
}

class _AttendeeListScreenState extends State<AttendeeListScreen> {
  List<Attendee>? _attendees;
  String? _error;

  final _scroll = ScrollController();
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore && _attendees != null) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _attendees = null;
      _error = null;
    });
    try {
      final page = await TicketService.attendees(widget.eventId);
      if (mounted) {
        setState(() {
          _attendees = page.items;
          _cursor = page.nextCursor;
          _hasMore = page.hasMore;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page =
          await TicketService.attendees(widget.eventId, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _attendees = [...?_attendees, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openProfile(String userId) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
    );
  }

  Future<void> _onTapAttendee(Attendee a) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline,
                  color: NileColors.txtSecondary),
              title: Text('View profile', style: NileTextStyles.labelLg()),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            if (!a.isRefunded)
              ListTile(
                leading:
                    const Icon(Icons.undo, color: NileColors.coral),
                title: Text('Refund ticket',
                    style: NileTextStyles.labelLg()
                        .copyWith(color: NileColors.coral)),
                subtitle: Text(
                    'Returns \$${(a.amountCents / 100).toStringAsFixed(2)} to @${a.username}',
                    style: NileTextStyles.caption()
                        .copyWith(color: NileColors.txtTertiary)),
                onTap: () => Navigator.pop(context, 'refund'),
              ),
          ],
        ),
      ),
    );

    if (action == 'profile') {
      _openProfile(a.buyerId);
    } else if (action == 'refund') {
      await _refund(a);
    }
  }

  Future<void> _refund(Attendee a) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Refund ticket?', style: NileTextStyles.headingSm()),
        content: Text(
          'This refunds \$${(a.amountCents / 100).toStringAsFixed(2)} to '
          '@${a.username} and revokes their access. This can\'t be undone.',
          style:
              NileTextStyles.bodySm().copyWith(color: NileColors.txtSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: NileColors.coral),
            child: const Text('Refund'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TicketService.refund(a.ticketId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ticket refunded')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refund failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: const Text('Attendees'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.eventTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.bodySm()
                    .copyWith(color: NileColors.txtSecondary),
              ),
            ),
          ),
        ),
      ),
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
        child: Text('Couldn\'t load attendees.\n$_error',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm()
                .copyWith(color: NileColors.txtSecondary)),
      );
    }
    if (_attendees == null) {
      return const Center(
          child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_attendees!.isEmpty) {
      return _Centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.confirmation_number_outlined,
                color: NileColors.txtTertiary, size: 40),
            const SizedBox(height: 12),
            Text('No tickets sold yet',
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.txtSecondary)),
          ],
        ),
      );
    }

    // Revenue and head-count reflect active (paid) tickets only; refunded
    // rows stay visible for history but don't count.
    final paid = _attendees!.where((a) => !a.isRefunded);
    final total = paid.fold<int>(0, (s, a) => s + a.amountCents);

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _attendees!.length + 1 + (_hasMore ? 1 : 0),
      separatorBuilder: (_, i) =>
          i == 0 ? const SizedBox(height: 12) : const SizedBox(height: 8),
      itemBuilder: (_, i) {
        if (i == 0) {
          return _SummaryRow(count: paid.length, totalCents: total);
        }
        if (i > _attendees!.length) return const LoadMoreFooter();
        final a = _attendees![i - 1];
        return _AttendeeTile(attendee: a, onTap: () => _onTapAttendee(a));
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final int count;
  final int totalCents;
  const _SummaryRow({required this.count, required this.totalCents});

  @override
  Widget build(BuildContext context) {
    final revenue = '\$${(totalCents / 100).toStringAsFixed(2)}';
    return Row(
      children: [
        _Stat(label: count == 1 ? 'attendee' : 'attendees', value: '$count'),
        const SizedBox(width: 12),
        _Stat(label: 'revenue', value: revenue),
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
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: NileTextStyles.headingSm()),
            const SizedBox(height: 2),
            Text(label,
                style: NileTextStyles.caption()
                    .copyWith(color: NileColors.txtSecondary)),
          ],
        ),
      ),
    );
  }
}

class _AttendeeTile extends StatelessWidget {
  final Attendee attendee;
  final VoidCallback onTap;
  const _AttendeeTile({required this.attendee, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final url = attendee.avatarUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: NileColors.bgRaised,
              backgroundImage:
                  (url != null && url.isNotEmpty) ? NetworkImage(url) : null,
              child: (url == null || url.isEmpty)
                  ? const Icon(Icons.person,
                      color: NileColors.txtTertiary, size: 22)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text('@${attendee.username}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NileTextStyles.labelLg()),
                      ),
                      if (attendee.isRefunded) ...[
                        const SizedBox(width: 8),
                        const _RefundedBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_formatDate(attendee.purchasedAt),
                      style: NileTextStyles.caption()
                          .copyWith(color: NileColors.txtTertiary)),
                ],
              ),
            ),
            Text('\$${(attendee.amountCents / 100).toStringAsFixed(2)}',
                style: NileTextStyles.labelMd().copyWith(
                  color: attendee.isRefunded
                      ? NileColors.txtTertiary
                      : NileColors.volt,
                  decoration: attendee.isRefunded
                      ? TextDecoration.lineThrough
                      : null,
                )),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final l = d.toLocal();
    return '${m[l.month - 1]} ${l.day}, ${l.year}';
  }
}

class _RefundedBadge extends StatelessWidget {
  const _RefundedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: NileColors.coral.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text('refunded',
          style: NileTextStyles.caption().copyWith(color: NileColors.coral)),
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
        Center(child: Padding(padding: const EdgeInsets.all(24), child: child)),
      ],
    );
  }
}
