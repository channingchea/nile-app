import 'package:flutter/material.dart';
import '../services/ticket_service.dart';
import '../theme.dart';
import 'profile_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _attendees = null;
      _error = null;
    });
    try {
      final list = await TicketService.attendees(widget.eventId);
      if (mounted) setState(() => _attendees = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _openProfile(String userId) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
    );
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

    final total = _attendees!.fold<int>(0, (s, a) => s + a.amountCents);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _attendees!.length + 1,
      separatorBuilder: (_, i) =>
          i == 0 ? const SizedBox(height: 12) : const SizedBox(height: 8),
      itemBuilder: (_, i) {
        if (i == 0) {
          return _SummaryRow(count: _attendees!.length, totalCents: total);
        }
        return _AttendeeTile(
          attendee: _attendees![i - 1],
          onTap: () => _openProfile(_attendees![i - 1].buyerId),
        );
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
                  Text('@${attendee.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.labelLg()),
                  const SizedBox(height: 2),
                  Text(_formatDate(attendee.purchasedAt),
                      style: NileTextStyles.caption()
                          .copyWith(color: NileColors.txtTertiary)),
                ],
              ),
            ),
            Text('\$${(attendee.amountCents / 100).toStringAsFixed(2)}',
                style: NileTextStyles.labelMd()
                    .copyWith(color: NileColors.volt)),
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
