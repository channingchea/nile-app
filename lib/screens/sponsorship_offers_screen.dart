import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/ad_service.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';

/// Where a host decides who sponsors their events.
///
/// Nile has already screened every creative here for policy; what's left is the
/// two questions only the host can answer — is this brand right for my audience,
/// and is the money enough. Both answers are on the card, which is why the card
/// carries the creative itself rather than a description of it.
///
/// [highlightCampaignId] is the campaign a `sponsorship_offer` notification was
/// about: the list scrolls to that card and marks it, because landing on a list
/// of six offers after tapping a notification about one of them is a puzzle.
/// [eventId] narrows the list to one event — where the event page's banner
/// leads.
class SponsorshipOffersScreen extends StatefulWidget {
  final String? highlightCampaignId;
  final String? eventId;

  const SponsorshipOffersScreen({
    super.key,
    this.highlightCampaignId,
    this.eventId,
  });

  @override
  State<SponsorshipOffersScreen> createState() =>
      _SponsorshipOffersScreenState();
}

class _SponsorshipOffersScreenState extends State<SponsorshipOffersScreen> {
  List<SponsorshipOffer>? _offers;
  String? _error;

  /// Campaign currently being accepted/declined — its card locks while the
  /// charge runs, since a double-tap here spends someone's money twice.
  String? _busyCampaignId;

  final _highlightKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final all = await AdService.hostOffers();
      if (!mounted) return;
      setState(() {
        _offers = widget.eventId == null
            ? all
            : all.where((o) => o.eventId == widget.eventId).toList();
      });
      _scrollToHighlight();
    } catch (e) {
      if (!mounted) return;
      // Deliberately not swallowed: an offer the host never sees expires in 48
      // hours and costs them the deal.
      setState(() {
        _offers = null;
        _error = e.toString();
      });
    }
  }

  /// Runs after the list has laid out, so the target card has a render box.
  void _scrollToHighlight() {
    if (widget.highlightCampaignId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: NileMotion.base,
        curve: NileMotion.curve,
        alignment: 0.1,
      );
    });
  }

  Future<void> _respond(SponsorshipOffer offer, {required bool accept}) async {
    final note = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _RespondSheet(offer: offer, accept: accept),
    );
    // Null means dismissed; an empty string is a deliberate "no comment".
    if (note == null || !mounted) return;

    setState(() => _busyCampaignId = offer.campaignId);
    try {
      await AdService.respondToOffer(
        campaignId: offer.campaignId,
        accept: accept,
        note: note.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? '${offer.advertiserName} is sponsoring ${offer.eventTitle}'
                : 'Offer declined',
          ),
        ),
      );
      // Accepting declines the siblings server-side, so the whole list is stale,
      // not just this card.
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_message(e))));
    } finally {
      if (mounted) setState(() => _busyCampaignId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Sponsorship offers')),
      body: NileMaxWidth(
        child: RefreshIndicator(
          onRefresh: _load,
          color: NileColors.volt,
          backgroundColor: NileColors.bgSurface,
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return _scrollable(
        NileEmptyState(
          icon: Icons.wifi_off,
          iconColor: NileColors.error,
          title: "Couldn't load your offers",
          body: _error!,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }
    if (_offers == null) {
      return Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_offers!.isEmpty) {
      return _scrollable(
        const NileEmptyState(
          icon: Icons.workspace_premium_outlined,
          title: 'No offers yet',
          body:
              'When a brand offers to sponsor one of your events, it lands here '
              'and we notify you. Offers close 48 hours before showtime.',
        ),
      );
    }

    final groups = SponsorshipOffer.groupByEvent(_offers!);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s16,
        NileSpacing.s16,
        NileSpacing.s32,
      ),
      children: [
        for (final g in groups) ...[
          _EventHeader(group: g),
          const SizedBox(height: NileSpacing.s12),
          for (final o in g.offers) ...[
            _OfferCard(
              key: o.campaignId == widget.highlightCampaignId
                  ? _highlightKey
                  : null,
              offer: o,
              highlighted: o.campaignId == widget.highlightCampaignId,
              busy: _busyCampaignId == o.campaignId,
              onAccept: () => _respond(o, accept: true),
              onDecline: () => _respond(o, accept: false),
            ),
            const SizedBox(height: NileSpacing.s12),
          ],
          const SizedBox(height: NileSpacing.s12),
        ],
      ],
    );
  }

  /// Keeps pull-to-refresh alive on the states that have nothing to scroll.
  Widget _scrollable(Widget child) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
      child,
    ],
  );
}

/// Strips Dart's `Exception: ` prefix so the server's own wording reaches the
/// host intact — "this offer has expired" reads better than the wrapper.
String _message(Object e) =>
    e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

String _money(int cents) {
  final d = cents / 100;
  return d == d.roundToDouble()
      ? '\$${d.toStringAsFixed(0)}'
      : '\$${d.toStringAsFixed(2)}';
}

const _months = [
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

String _fmtDate(DateTime dt) {
  final l = dt.toLocal();
  final time =
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  return '${_months[l.month - 1]} ${l.day} · $time';
}

// ── Section header ────────────────────────────────────────────────────────────

class _EventHeader extends StatelessWidget {
  final SponsorshipOfferGroup group;
  const _EventHeader({required this.group});

  @override
  Widget build(BuildContext context) {
    final count = group.offers.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(group.eventTitle, style: NileTextStyles.headingSm()),
        const SizedBox(height: NileSpacing.s2),
        Text(
          [
            if (group.scheduledAt != null) _fmtDate(group.scheduledAt!),
            count == 1 ? '1 offer' : '$count offers',
          ].join(' · '),
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      ],
    );
  }
}

// ── Offer card ────────────────────────────────────────────────────────────────

class _OfferCard extends StatelessWidget {
  final SponsorshipOffer offer;
  final bool highlighted;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _OfferCard({
    super.key,
    required this.offer,
    required this.highlighted,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final domain = offer.clickDomain;
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        // The marked card is the one the notification was about; a border is
        // enough to find it without shouting over the other offers.
        border: highlighted
            ? Border.all(color: NileColors.volt, width: 2)
            : Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  offer.advertiserName,
                  style: NileTextStyles.labelLg(),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _money(offer.budgetCents),
                    style: NileTextStyles.headingMd().tabular,
                  ),
                  Text(
                    'you keep ${_money(offer.hostNetCents)}',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.volt,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: NileSpacing.s12),
          _Creative(offer: offer),
          const SizedBox(height: NileSpacing.s12),
          if (offer.headline.isNotEmpty)
            Text(offer.headline, style: NileTextStyles.labelMd()),
          if (offer.body != null && offer.body!.trim().isNotEmpty) ...[
            const SizedBox(height: NileSpacing.s4),
            Text(
              offer.body!,
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ],
          if (domain != null) ...[
            const SizedBox(height: NileSpacing.s8),
            Row(
              children: [
                Icon(Icons.link, size: 14, color: NileColors.txtTertiary),
                const SizedBox(width: NileSpacing.s6),
                // Domain only. The full click URL is a tracking string the host
                // would have to decode to answer "where does this send people".
                Expanded(
                  child: Text(
                    'Links to $domain',
                    style: NileTextStyles.caption(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: NileSpacing.s12),
          if (offer.isPaymentPending)
            _PaymentPendingNote()
          else ...[
            Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 14,
                  color: offer.isUrgent
                      ? NileColors.coral
                      : NileColors.txtTertiary,
                ),
                const SizedBox(width: NileSpacing.s6),
                Text(
                  offer.expiresLabel(),
                  style: NileTextStyles.caption().copyWith(
                    color: offer.isUrgent
                        ? NileColors.coral
                        : NileColors.txtTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: NileSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onDecline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: NileSpacing.s12),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onAccept,
                    child: busy
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: NileColors.onVolt,
                            ),
                          )
                        : const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// `payment_pending`: the accept charge is sitting with the advertiser's bank.
/// No buttons — there is nothing the host can do, and offering an action that
/// does nothing is worse than saying so.
class _PaymentPendingNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(NileSpacing.s12),
    decoration: BoxDecoration(
      color: NileColors.bgRaised,
      borderRadius: BorderRadius.circular(NileRadius.sm),
    ),
    child: Row(
      children: [
        Icon(Icons.hourglass_bottom, size: 16, color: NileColors.txtSecondary),
        const SizedBox(width: NileSpacing.s8),
        Expanded(
          child: Text(
            "Payment pending — we'll confirm shortly",
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Creative preview ──────────────────────────────────────────────────────────

/// The ad exactly as the lobby will show it. A host approving a brand is
/// approving this frame, so it is shown at the aspect the lobby uses rather
/// than as a thumbnail.
class _Creative extends StatelessWidget {
  final SponsorshipOffer offer;
  const _Creative({required this.offer});

  @override
  Widget build(BuildContext context) {
    if (offer.kind == 'video' && offer.videoUrl != null) {
      return _CreativeVideo(url: offer.videoUrl!, thumbUrl: offer.thumbUrl);
    }
    final url = offer.imageUrl ?? offer.thumbUrl;
    if (url == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: nileDecodeWidth(NileMaxWidth.compact),
          errorBuilder: (_, _, _) => Container(color: NileColors.bgRaised),
        ),
      ),
    );
  }
}

/// Tap to play, muted — the same treatment the lobby gives it, minus the
/// autoplay. A list of cards that all start talking at once is unusable, and
/// the sound isn't what the host is judging.
class _CreativeVideo extends StatefulWidget {
  final String url;
  final String? thumbUrl;
  const _CreativeVideo({required this.url, this.thumbUrl});

  @override
  State<_CreativeVideo> createState() => _CreativeVideoState();
}

class _CreativeVideoState extends State<_CreativeVideo> {
  VideoPlayerController? _controller;
  bool _starting = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    setState(() => _starting = true);
    VideoPlayerController? c;
    try {
      c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
    } catch (_) {
      c?.dispose();
      c = null; // Falls back to the poster frame.
    }
    if (!mounted) {
      c?.dispose();
      return;
    }
    setState(() {
      _controller = c;
      _starting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: GestureDetector(
          onTap: c == null
              ? _start
              : () => setState(
                  () => c.value.isPlaying ? c.pause() : c.play(),
                ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (c != null && c.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: c.value.size.width,
                    height: c.value.size.height,
                    child: VideoPlayer(c),
                  ),
                )
              else if (widget.thumbUrl != null)
                Image.network(
                  widget.thumbUrl!,
                  fit: BoxFit.cover,
                  cacheWidth: nileDecodeWidth(NileMaxWidth.compact),
                  errorBuilder: (_, _, _) =>
                      Container(color: NileColors.bgRaised),
                )
              else
                Container(color: NileColors.bgRaised),
              if (c == null)
                Center(
                  child: _starting
                      ? CircularProgressIndicator(color: NileColors.volt)
                      : Container(
                          padding: const EdgeInsets.all(NileSpacing.s12),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                ),
              Positioned(
                left: NileSpacing.s8,
                bottom: NileSpacing.s8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s8,
                    vertical: NileSpacing.s2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(NileRadius.xs),
                  ),
                  child: Text(
                    'Muted',
                    style: NileTextStyles.caption().copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Accept / decline sheet ────────────────────────────────────────────────────

/// Pops the note on submit (possibly empty) and null on dismiss.
///
/// Accept has no second confirmation: the sheet already says the money moves
/// now, and a host who opened it and typed a note has decided. Decline asks for
/// a reason because the advertiser can revise and come back — a bare "no" ends
/// the conversation for no reason.
class _RespondSheet extends StatefulWidget {
  final SponsorshipOffer offer;
  final bool accept;
  const _RespondSheet({required this.offer, required this.accept});

  @override
  State<_RespondSheet> createState() => _RespondSheetState();
}

class _RespondSheetState extends State<_RespondSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final accept = widget.accept;
    return Padding(
      padding: EdgeInsets.only(
        left: NileSpacing.s16,
        right: NileSpacing.s16,
        top: NileSpacing.s24,
        bottom: MediaQuery.viewInsetsOf(context).bottom + NileSpacing.s24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            accept
                ? 'Accept ${o.advertiserName}?'
                : 'Decline ${o.advertiserName}?',
            style: NileTextStyles.headingSm(),
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            accept
                ? '${o.advertiserName} is charged ${_money(o.budgetCents)} now, '
                      'and their ad appears in your Pre-Show lobby for '
                      '${o.eventTitle}. You keep ${_money(o.hostNetCents)}. '
                      'Any other offers on this event are declined.'
                : '${o.advertiserName} can change the creative or the amount '
                      'and offer again — what you write here is the only thing '
                      'telling them what to change.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: NileSpacing.s16),
          TextField(
            controller: _controller,
            maxLines: accept ? 2 : 3,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: accept
                  ? 'Note for ${o.advertiserName} (optional)'
                  : 'Why are you declining? (optional)',
              hintText: accept
                  ? null
                  : 'e.g. the creative doesn’t fit my audience',
            ),
          ),
          const SizedBox(height: NileSpacing.s8),
          SizedBox(
            width: double.infinity,
            child: accept
                ? FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, _controller.text),
                    child: Text('Accept ${_money(o.budgetCents)}'),
                  )
                : OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, _controller.text),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NileColors.coral,
                    ),
                    child: const Text('Decline offer'),
                  ),
          ),
        ],
      ),
    );
  }
}
