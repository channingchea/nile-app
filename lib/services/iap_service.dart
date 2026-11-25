import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pricing_service.dart';
import 'supabase_client.dart';

/// Where a purchase is after the buyer confirms Apple's sheet.
enum IapStage { idle, buying, confirming, slow, done }

/// How a buy attempt ended.
enum IapOutcome {
  /// Nile confirmed the ticket.
  ticket,

  /// The buyer already held this ticket another way; Apple still charged them.
  duplicate,

  /// The buyer closed Apple's sheet.
  cancelled,

  /// Apple took the payment but Nile hasn't confirmed yet. Retries continue in
  /// the background; the ticket appears on its own.
  stillConfirming,
}

/// Apple in-app purchase for tickets and replays on iPhone and iPad
/// (docs/plans/apple-iap-tickets.md, Phase 3). Everywhere else — Mac, web,
/// Android — [enabled] is false and nothing here runs.
///
/// Flow: create-payment-intent (provider apple) makes a pending ticket and
/// names the App Store product → StoreKit 2 purchase with the ticket id as
/// `appAccountToken` → apple-iap/verify checks Apple's signed transaction and
/// marks the ticket paid → only then is the transaction finished. Anything
/// interrupted is re-delivered by StoreKit at the next launch and finished then.
class IapService {
  IapService._();

  static bool get enabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static final ValueNotifier<IapStage> stage = ValueNotifier(IapStage.idle);

  static StreamSubscription<List<PurchaseDetails>>? _sub;
  static String? _storefront;
  static Completer<IapOutcome>? _waiting;
  static final Map<String, PurchaseDetails> _unverified = {};
  static Timer? _retry;

  /// Apple's id for the last confirmed purchase (used to offer a refund when
  /// it turned out to be a [IapOutcome.duplicate]).
  static String? lastTransactionId;

  /// The App Store country (`USA`), not the phone's region setting. Unknown
  /// counts as outside the US.
  static bool get isUsStorefront => _storefront == 'USA';

  /// Call once at launch, before sign-in finishes: StoreKit re-delivers any
  /// purchase that wasn't finished last time as soon as we listen.
  static Future<void> init() async {
    if (!enabled || _sub != null) return;
    _sub = InAppPurchase.instance.purchaseStream.listen((list) {
      for (final p in list) {
        _handle(p);
      }
    }, onError: (Object e) => debugPrint('IAP stream error: $e'));
    // A purchase that came back before sign-in finished needs the session.
    supabase.auth.onAuthStateChange.listen((s) {
      if (s.session != null) _retryUnverified();
    });
    unawaited(refreshStorefront());
    unawaited(PricingService.load());
  }

  static Future<void> refreshStorefront() async {
    if (!enabled) return;
    try {
      _storefront = await Storefront().countryCode();
    } catch (_) {
      /* unknown → non-US */
    }
  }

  /// iPhone price for a web price, or null when the show isn't sold in the
  /// app (above $99.99 on iPhone, or not on iPhone/iPad at all).
  static int? storeCentsFor(int? webCents) =>
      enabled ? PricingService.current.iapPriceCentsFor(webCents) : null;

  /// The price to show this buyer: the iPhone price where the show is sold in
  /// the app, the web price everywhere else.
  static int displayCents(int webCents) => storeCentsFor(webCents) ?? webCents;

  /// Buy a ticket ([kind] 'live') or a replay ('replay') for [eventId].
  static Future<IapOutcome> buy({
    required String eventId,
    String kind = 'live',
  }) async {
    if (_waiting != null) throw Exception('A purchase is already in progress');
    await refreshStorefront();

    final Map data;
    try {
      final res = await supabase.functions.invoke(
        'create-payment-intent',
        body: {
          'event_id': eventId,
          'kind': kind,
          'origin': 'ios',
          'provider': 'apple',
        },
      );
      data = res.data as Map;
    } on FunctionException catch (e) {
      throw Exception(
        (e.details as Map?)?['error'] ?? 'Could not start the purchase',
      );
    }
    final ticketId = data['ticket_id'] as String;
    final productId = data['product_id'] as String;

    final found = await InAppPurchase.instance.queryProductDetails({productId});
    if (found.productDetails.isEmpty) {
      throw Exception('This price isn’t available in the App Store right now.');
    }

    final waiting = _waiting = Completer<IapOutcome>();
    stage.value = IapStage.buying;
    try {
      await InAppPurchase.instance.buyConsumable(
        purchaseParam: PurchaseParam(
          productDetails: found.productDetails.first,
          applicationUserName: ticketId, // → appAccountToken
        ),
      );
      // StoreKit 2 returns once Apple's sheet closes. A cancel that sends no
      // update would otherwise leave the button spinning.
      Future.delayed(const Duration(seconds: 5), () {
        if (stage.value == IapStage.buying) _resolve(IapOutcome.cancelled);
      });
      return await waiting.future;
    } catch (e) {
      if (!waiting.isCompleted) waiting.complete(IapOutcome.cancelled);
      rethrow;
    } finally {
      _waiting = null;
      if (stage.value == IapStage.buying) stage.value = IapStage.idle;
    }
  }

  static void _resolve(IapOutcome o) {
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete(o);
  }

  static Future<void> _handle(PurchaseDetails p) async {
    switch (p.status) {
      case PurchaseStatus.pending:
        stage.value = IapStage.buying;
      case PurchaseStatus.canceled:
      case PurchaseStatus.error:
        if (p.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(p);
        }
        stage.value = IapStage.idle;
        if (p.status == PurchaseStatus.canceled) {
          _resolve(IapOutcome.cancelled);
        } else {
          final w = _waiting;
          if (w != null && !w.isCompleted) {
            w.completeError(Exception(p.error?.message ?? 'Purchase failed'));
          }
        }
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _verify(p);
    }
  }

  /// Ask Nile to confirm, a few times with backoff. The transaction is only
  /// finished once Nile has recorded the ticket.
  static Future<void> _verify(PurchaseDetails p) async {
    final key = p.purchaseID ?? p.verificationData.serverVerificationData;
    _unverified[key] = p;
    if (_waiting != null) stage.value = IapStage.confirming;
    for (var attempt = 0; attempt < 4; attempt++) {
      final status = await _verifyOnce(p);
      if (status == 'rejected') {
        // Left unfinished: StoreKit keeps it, and support can look it up.
        _unverified.remove(key);
        stage.value = IapStage.slow;
        _resolve(IapOutcome.stillConfirming);
        return;
      }
      if (status != null) {
        _unverified.remove(key);
        lastTransactionId = p.purchaseID;
        await InAppPurchase.instance.completePurchase(p);
        stage.value = IapStage.done;
        _resolve(
          status == 'duplicate' ? IapOutcome.duplicate : IapOutcome.ticket,
        );
        return;
      }
      if (attempt == 0 && _waiting != null) stage.value = IapStage.slow;
      await Future.delayed(Duration(seconds: 2 << attempt));
    }
    stage.value = IapStage.slow;
    _resolve(IapOutcome.stillConfirming);
    _retry ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _retryUnverified(),
    );
  }

  /// 'paid' | 'already' | 'duplicate' once Nile has the ticket; 'rejected'
  /// when Nile refused it for good (not one of our products, someone else's
  /// ticket); null to retry (offline, signed out, server hiccup).
  static Future<String?> _verifyOnce(PurchaseDetails p) async {
    if (supabase.auth.currentSession == null) return null;
    try {
      final res = await supabase.functions.invoke(
        'apple-iap/verify',
        body: {'signed_transaction': p.verificationData.serverVerificationData},
      );
      final status = (res.data as Map?)?['status'] as String?;
      return const {'paid', 'already', 'duplicate'}.contains(status)
          ? status
          : null;
    } on FunctionException catch (e) {
      debugPrint('apple-iap/verify: ${e.status} ${e.details}');
      // 401 = session expired mid-flight: retry once signed in again.
      return const {400, 403, 404}.contains(e.status) ? 'rejected' : null;
    } catch (e) {
      debugPrint('apple-iap/verify: $e');
      return null;
    }
  }

  static Future<void> _retryUnverified() async {
    if (_unverified.isEmpty) {
      _retry?.cancel();
      _retry = null;
      return;
    }
    for (final entry in Map.of(_unverified).entries) {
      final status = await _verifyOnce(entry.value);
      if (status == null) continue;
      _unverified.remove(entry.key);
      if (status != 'rejected') {
        await InAppPurchase.instance.completePurchase(entry.value);
      }
    }
  }

  static const _refund = MethodChannel('nile/store_refund');

  /// Opens Apple's refund form for an App Store ticket. Returns 'submitted',
  /// 'cancelled', 'failed' or 'unavailable'. Apple decides; its REFUND
  /// notification updates the ticket.
  static Future<String> requestRefund(String appleTransactionId) async {
    if (!enabled) return 'unavailable';
    try {
      return await _refund.invokeMethod<String>(
            'request',
            appleTransactionId,
          ) ??
          'failed';
    } on PlatformException {
      return 'failed';
    }
  }
}
