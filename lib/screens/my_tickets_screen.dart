import 'package:flutter/material.dart';
import '../services/event_service.dart';
import '../services/ticket_service.dart';
import '../theme.dart';
import 'event_detail_screen.dart';

/// The current user's purchased tickets.
class MyTicketsScreen extends StatefulWidget {
  const MyTicketsScreen({super.key});

  @override
  State<MyTicketsScreen> createState() => _MyTicketsScreenState();
}

class _MyTicketsScreenState extends State<MyTicketsScreen> {
  List<MyTicket>? _tickets;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _tickets = null;
      _error = null;
    });
    try {
      final list = await TicketService.myTickets();
      if (mounted) setState(() => _tickets = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openEvent(Event event) async {
    final deleted = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)),
    );
    if (deleted == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('My Tickets')),
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
        child: Text('Couldn\'t load tickets.\n$_error',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm()
                .copyWith(color: NileColors.txtSecondary)),
      );
    }
    if (_tickets == null) {
      return const Center(
          child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_tickets!.isEmpty) {
      return _Centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.confirmation_number_outlined,
                color: NileColors.txtTertiary, size: 40),
            const SizedBox(height: 12),
            Text('No tickets yet',
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.txtSecondary)),
            const SizedBox(height: 4),
            Text('Tickets you buy will show up here',
                style: NileTextStyles.caption()
                    .copyWith(color: NileColors.txtTertiary)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: _tickets!.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final t = _tickets![i];
        return _TicketCard(
          myTicket: t,
          onTap: t.event == null ? null : () => _openEvent(t.event!),
        );
      },
    );
  }
}

class _TicketCard extends StatelessWidget {
  final MyTicket myTicket;
  final VoidCallback? onTap;
  const _TicketCard({required this.myTicket, this.onTap});

  @override
  Widget build(BuildContext context) {
    final event = myTicket.event;
    final cover = event?.coverImageUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Container(
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: (cover != null && cover.isNotEmpty)
                  ? Image.network(cover, fit: BoxFit.cover)
                  : Container(
                      color: NileColors.bgRaised,
                      child: const Icon(Icons.event,
                          color: NileColors.txtTertiary)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event?.title ?? 'Event',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.labelLg()),
                    const SizedBox(height: 4),
                    if (event != null)
                      Text(_subtitle(event),
                          style: NileTextStyles.caption()
                              .copyWith(color: NileColors.txtSecondary)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatusBadge(status: myTicket.ticket.status),
                        const Spacer(),
                        Text(
                          '\$${(myTicket.ticket.amountCents / 100).toStringAsFixed(2)}',
                          style: NileTextStyles.labelMd()
                              .copyWith(color: NileColors.volt),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(Event e) {
    final when = e.scheduledAt ?? e.startedAt;
    if (when == null) return 'by @${e.hostUsername}';
    return '${_fmtDate(when)} · by @${e.hostUsername}';
  }

  static String _fmtDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final l = d.toLocal();
    return '${m[l.month - 1]} ${l.day}, ${l.year}';
  }
}

class _StatusBadge extends StatelessWidget {
  final String status; // pending | paid | refunded
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final String label;
    switch (status) {
      case 'paid':
        color = NileColors.success;
        label = 'Paid';
        break;
      case 'refunded':
        color = NileColors.txtTertiary;
        label = 'Refunded';
        break;
      default:
        color = NileColors.warning;
        label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(label,
          style: NileTextStyles.caption()
              .copyWith(color: color, fontWeight: FontWeight.w600)),
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
