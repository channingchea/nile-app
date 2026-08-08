import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/calendar_ics.dart';
import '../services/event_service.dart';
import '../services/ticket_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import 'widgets/load_more_footer.dart';

/// The current user's purchased tickets.
class MyTicketsScreen extends StatefulWidget {
  const MyTicketsScreen({super.key});

  @override
  State<MyTicketsScreen> createState() => _MyTicketsScreenState();
}

class _MyTicketsScreenState extends State<MyTicketsScreen> {
  List<MyTicket>? _tickets;
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
    if (_hasMore && !_loadingMore && _tickets != null) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _tickets = null;
      _error = null;
    });
    try {
      final page = await TicketService.myTickets();
      if (mounted) {
        setState(() {
          _tickets = page.items;
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
      final page = await TicketService.myTickets(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _tickets = [...?_tickets, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _openEvent(Event event) async {
    final deleted = await context.push(NileRoutes.event(event.id), extra: event);
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
        child: Text(
          'Couldn\'t load tickets.\n$_error',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
      );
    }
    if (_tickets == null) {
      return Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }
    if (_tickets!.isEmpty) {
      return NileEmptyState(
        icon: Icons.confirmation_number_outlined,
        title: 'No tickets yet',
        body: 'Tickets you buy will show up here.',
      );
    }

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
      itemCount: _tickets!.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (i >= _tickets!.length) return const LoadMoreFooter();
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
      borderRadius: BorderRadius.circular(NileRadius.lg),
      child: Container(
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 128,
              height: 72,
              child: (cover != null && cover.isNotEmpty)
                  ? Image.network(cover, fit: BoxFit.cover, cacheWidth: nileDecodeWidth(128))
                  : Container(
                      color: NileColors.bgRaised,
                      child: Icon(
                        Icons.event,
                        color: NileColors.txtTertiary,
                      ),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(NileSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event?.title ?? 'Event',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.labelLg(),
                    ),
                    const SizedBox(height: 4),
                    if (event != null)
                      Text(
                        _subtitle(event),
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatusBadge(status: myTicket.ticket.status),
                        const Spacer(),
                        if (event != null && CalendarIcs.canAdd(event))
                          IconButton(
                            icon: Icon(
                              Icons.calendar_today_outlined,
                              size: 18,
                              color: NileColors.txtSecondary,
                            ),
                            tooltip: 'Add to calendar',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => CalendarIcs.share(event),
                          ),
                        const SizedBox(width: 8),
                        Text(
                          '\$${(myTicket.ticket.amountCents / 100).toStringAsFixed(2)}',
                          style: NileTextStyles.labelMd().copyWith(
                            color: NileColors.volt,
                          ),
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(
        label,
        style: NileTextStyles.caption().copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
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
        Center(
          child: Padding(padding: const EdgeInsets.all(NileSpacing.s24), child: child),
        ),
      ],
    );
  }
}
