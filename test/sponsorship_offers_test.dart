// A host has 48 hours to answer an offer and real money riding on it, so the
// three things this screen computes without asking the server — how long is
// left, which event a card belongs under, and where the ad actually links —
// are the ones worth pinning down.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/router.dart';
import 'package:nile_app/services/ad_service.dart';
import 'package:nile_app/services/destinations.dart';
import 'package:nile_app/services/notification_service.dart';

SponsorshipOffer _offer({
  String campaignId = 'c1',
  String eventId = 'e1',
  String eventTitle = 'Test show',
  int budgetCents = 5000,
  String status = 'pending_host',
  String clickUrl = 'https://www.example.com/promo?utm=x',
  Duration expiresIn = const Duration(hours: 30),
}) {
  final now = DateTime.now().toUtc();
  return SponsorshipOffer.fromJson({
    'campaign_id': campaignId,
    'event_id': eventId,
    'event_title': eventTitle,
    'scheduled_at': now.add(const Duration(days: 4)).toIso8601String(),
    'advertiser_name': 'Acme',
    'budget_cents': budgetCents,
    'host_net_cents': (budgetCents * 0.7).round(),
    'status': status,
    'kind': 'image',
    'image_url': 'https://cdn.example.com/a.jpg',
    'duration_ms': 0,
    'headline': 'Hello',
    'click_url': clickUrl,
    'offer_expires_at': now.add(expiresIn).toIso8601String(),
  });
}

void main() {
  group('expiry', () {
    final at = DateTime.utc(2026, 8, 20, 12);

    test('coarse units, singular and plural', () {
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.subtract(const Duration(hours: 47)),
        ),
        '1 day left',
      );
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.subtract(const Duration(hours: 49)),
        ),
        '2 days left',
      );
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.subtract(const Duration(hours: 1)),
        ),
        '1 hour left',
      );
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.subtract(const Duration(minutes: 90)),
        ),
        '1 hour left',
      );
    });

    // Never "0 minutes left" — that reads as expired while the offer is still
    // live and acceptable.
    test('rounds the last minute up rather than to zero', () {
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.subtract(const Duration(seconds: 20)),
        ),
        '1 minute left',
      );
    });

    test('past the deadline says so', () {
      expect(SponsorshipOffer.expiresLabelFor(at, now: at), 'Expired');
      expect(
        SponsorshipOffer.expiresLabelFor(
          at,
          now: at.add(const Duration(hours: 1)),
        ),
        'Expired',
      );
    });

    test('isUrgent only inside the last day, and never once expired', () {
      expect(_offer(expiresIn: const Duration(hours: 23)).isUrgent, isTrue);
      expect(_offer(expiresIn: const Duration(hours: 25)).isUrgent, isFalse);
      expect(_offer(expiresIn: const Duration(hours: -1)).isUrgent, isFalse);
    });
  });

  group('grouping', () {
    test('keeps the RPC order and collects competing offers together', () {
      final offers = [
        _offer(campaignId: 'a', eventId: 'e1', budgetCents: 9000),
        _offer(campaignId: 'b', eventId: 'e1', budgetCents: 5000),
        _offer(campaignId: 'c', eventId: 'e2', eventTitle: 'Later show'),
      ];
      final groups = SponsorshipOffer.groupByEvent(offers);
      expect(groups.map((g) => g.eventId), ['e1', 'e2']);
      expect(groups.first.offers.map((o) => o.campaignId), ['a', 'b']);
      expect(groups.first.eventTitle, 'Test show');
      expect(groups.last.offers.single.campaignId, 'c');
    });

    // Two events far apart in the list would otherwise produce two sections for
    // one event — the RPC orders by event date, but nothing enforces adjacency.
    test('one section per event even when rows are interleaved', () {
      final groups = SponsorshipOffer.groupByEvent([
        _offer(campaignId: 'a', eventId: 'e1'),
        _offer(campaignId: 'b', eventId: 'e2'),
        _offer(campaignId: 'c', eventId: 'e1'),
      ]);
      expect(groups.length, 2);
      expect(groups.first.offers.map((o) => o.campaignId), ['a', 'c']);
    });

    test('empty in, empty out', () {
      expect(SponsorshipOffer.groupByEvent([]), isEmpty);
    });
  });

  group('card fields', () {
    test('click domain drops www and the tracking tail', () {
      expect(_offer().clickDomain, 'example.com');
      expect(
        _offer(clickUrl: 'https://shop.acme.co.uk/x').clickDomain,
        'shop.acme.co.uk',
      );
    });

    test('an unusable click URL yields no domain line at all', () {
      expect(_offer(clickUrl: '').clickDomain, isNull);
      expect(_offer(clickUrl: 'not a url').clickDomain, isNull);
    });

    // payment_pending renders read-only: the charge is with the advertiser's
    // bank and no host action can move it.
    test('only pending_host is actionable', () {
      expect(_offer().isActionable, isTrue);
      expect(_offer(status: 'payment_pending').isActionable, isFalse);
      expect(_offer(status: 'payment_pending').isPaymentPending, isTrue);
    });
  });

  // The label on a live sponsorship is driven by this flag alone (0098). The
  // bug it exists to prevent is inferring it from `events.sponsorship_auto_
  // accept`, which is true for a host who happened to accept by hand first.
  group('auto-accepted label', () {
    LobbySponsorship parse(Map<String, dynamic> extra) =>
        LobbySponsorship.fromRow({
          'campaign_id': 'c1',
          'kind': 'image',
          'image_url': 'https://cdn.example.com/a.jpg',
          'duration_ms': 0,
          'headline': 'Hi',
          'click_url': 'https://example.com',
          'advertiser_name': 'Acme',
          ...extra,
        });

    test('reads the flag off the row', () {
      expect(parse({'auto_accepted': true}).autoAccepted, isTrue);
      expect(parse({'auto_accepted': false}).autoAccepted, isFalse);
    });

    // A client on the old RPC shape must not claim a hand-picked sponsor was
    // automatic.
    test('a missing column is not an automatic acceptance', () {
      expect(parse({}).autoAccepted, isFalse);
    });
  });

  _deepLink();
}

// ── Deep link ─────────────────────────────────────────────────────────────────
// `notifications.entity_id` holds the CAMPAIGN id for these two types, not the
// event id — every other event-ish notification in the app carries an event.
// Routing one of these through Destinations.event would open the wrong screen
// (or a "this isn't here anymore" page) and is exactly the mistake to lock out.

void _deepLink() {
  group('notification deep link', () {
    test('both sponsorship types parse from an FCM payload', () {
      expect(
        Destinations.typeFromPush('sponsorship_offer'),
        NotificationType.sponsorshipOffer,
      );
      expect(
        Destinations.typeFromPush('sponsorship_offer_expiring'),
        NotificationType.sponsorshipOfferExpiring,
      );
    });

    test('entity_id lands on the offers screen as the campaign', () async {
      for (final type in [
        NotificationType.sponsorshipOffer,
        NotificationType.sponsorshipOfferExpiring,
      ]) {
        final d = await Destinations.forNotification(
          type,
          entityId: 'camp-1',
          actorId: 'host-1',
        );
        expect(d, isNotNull);
        expect(d!.location, '/sponsorship-offers?campaign=camp-1');
        expect(d.extra, isNull);
      }
    });

    test('no entity means nowhere to go', () async {
      expect(
        await Destinations.forNotification(NotificationType.sponsorshipOffer),
        isNull,
      );
    });

    test('the event page links to its own event, not a campaign', () {
      expect(
        NileRoutes.sponsorshipOffers(eventId: 'e1'),
        '/sponsorship-offers?event=e1',
      );
      expect(NileRoutes.sponsorshipOffers(), '/sponsorship-offers');
    });
  });
}
