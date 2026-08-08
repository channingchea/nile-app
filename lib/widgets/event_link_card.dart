import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/event_service.dart';
import '../theme.dart';

/// A compact, tappable thumbnail card for an event linked from a post — shown
/// in place of a raw `nile://event/…` URL. Fetches the event by id; renders a
/// quiet placeholder while loading and nothing if the event is gone.
class EventLinkCard extends StatefulWidget {
  final String eventId;
  const EventLinkCard({super.key, required this.eventId});

  @override
  State<EventLinkCard> createState() => _EventLinkCardState();
}

class _EventLinkCardState extends State<EventLinkCard> {
  Event? _event;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EventLinkCard old) {
    super.didUpdateWidget(old);
    if (old.eventId != widget.eventId) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final ev = await EventService.fetchById(widget.eventId);
      if (mounted) {
        setState(() {
          _event = ev;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ev = _event;
    if (_loading) {
      return Container(
        height: 64,
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
      );
    }
    if (ev == null) return const SizedBox.shrink();

    final thumb = ev.thumbnailUrl;
    return InkWell(
      onTap: () => context.push(NileRoutes.event(ev.id), extra: ev),
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          border: Border.all(color: NileColors.border),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 128,
              height: 72,
              child: (thumb != null && thumb.isNotEmpty)
                  ? Image.network(
                      thumb,
                      cacheWidth: nileDecodeWidth(128),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(),
                    )
                  : _placeholder(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          ev.isLive ? Icons.sensors : Icons.event,
                          size: 13,
                          color: ev.isLive
                              ? NileColors.coral
                              : NileColors.txtTertiary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          ev.isLive ? 'LIVE NOW' : 'EVENT',
                          style: NileTextStyles.labelSm().copyWith(
                            color: ev.isLive
                                ? NileColors.coral
                                : NileColors.txtTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ev.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.labelMd(),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(right: NileSpacing.s8),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: NileColors.txtTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => DecoratedBox(
    decoration: BoxDecoration(color: NileColors.bgSurface),
    child: Center(
      child: Icon(Icons.live_tv, size: 24, color: NileColors.border),
    ),
  );
}
