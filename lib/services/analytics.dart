import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Product analytics. (P4 #39 of the 2026-08-16 platform review: Nile had
/// none, so "how many people who viewed an event bought a ticket" — the single
/// number the whole business turns on — was unanswerable.)
///
/// Everything goes through this class rather than PostHog directly, for three
/// reasons that have all bitten other codebases:
///
///   * **Inert by default.** No key, no network, no crash. Debug builds and
///     anyone who hasn't configured a key behave exactly as before.
///   * **One event vocabulary.** [NileEvent] is the whole list. Free-form
///     strings sprinkled across fifty screens become forty spellings of the
///     same funnel step and a dashboard nobody trusts.
///   * **One place to switch vendor.** If PostHog is ever replaced, this file
///     changes and no screen does.
///
/// Privacy: autocapture and session replay are OFF. We send the events named
/// below and nothing else — no screen scraping, no keystrokes, no PII beyond
/// the Supabase user id, which is already the identifier everything else uses.
/// [optOut] is wired to a settings switch and is honoured locally by the SDK.
class NileAnalytics {
  NileAnalytics._();

  static const _optOutKey = 'analytics_opt_out';

  static bool _ready = false;
  static bool _optedOut = false;

  /// True when a key is configured AND init succeeded. Every method below is a
  /// no-op otherwise, so callers never have to check.
  static bool get isEnabled => _ready;

  /// Cached so Settings can paint the switch on the first frame without an
  /// await. Authoritative copy is in SharedPreferences.
  static bool get isOptedOut => _optedOut;

  static Future<void> init() async {
    // Read the preference even when analytics is unconfigured, so the Settings
    // switch shows what the user last chose rather than silently resetting.
    try {
      _optedOut = (await SharedPreferences.getInstance()).getBool(_optOutKey) ?? false;
    } catch (_) {/* a missing store just means "not opted out" */}

    if (posthogApiKey.isEmpty) return;
    try {
      final config = PostHogConfig(posthogApiKey)
        ..host = posthogHost
        // Autocapture would hoover up every tap and text field, which is both
        // more than we need and a PII problem we don't want to own.
        ..captureApplicationLifecycleEvents = true
        ..sessionReplay = false
        ..debug = kDebugMode;
      await Posthog().setup(config);
      _ready = true;
      // Re-apply on every launch. setup() starts enabled, so without this a
      // user who opted out last week starts sending again today.
      if (_optedOut) await Posthog().disable();
    } catch (e) {
      // Analytics must never be able to stop the app from starting.
      debugPrint('NileAnalytics: init failed, continuing without it — $e');
    }
  }

  /// Tie subsequent events to a signed-in user. Call after sign-in and after a
  /// session is restored on launch.
  static Future<void> identify(String userId) async {
    if (!_ready) return;
    try {
      await Posthog().identify(userId: userId);
    } catch (_) {/* never surface analytics failures */}
  }

  /// Forget the current user. MUST be called on sign-out, or the next person
  /// to use the device inherits the previous person's identity.
  static Future<void> reset() async {
    if (!_ready) return;
    try {
      await Posthog().reset();
    } catch (_) {/* never surface analytics failures */}
  }

  static Future<void> capture(NileEvent event, [Map<String, Object>? props]) async {
    // Belt and braces: disable() should already have stopped this, but the
    // opt-out is a promise to the user and shouldn't rest on one SDK call
    // having succeeded.
    if (!_ready || _optedOut) return;
    try {
      await Posthog().capture(eventName: event.name, properties: props ?? const {});
    } catch (_) {/* never surface analytics failures */}
  }

  /// Honoured locally by the SDK: queued events are dropped and nothing further
  /// is sent. Backs the "Share usage data" switch in Settings.
  ///
  /// The preference is persisted FIRST, so a crash between the two leaves the
  /// user opted out rather than silently opted back in.
  static Future<void> setOptOut(bool optedOut) async {
    _optedOut = optedOut;
    try {
      await (await SharedPreferences.getInstance()).setBool(_optOutKey, optedOut);
    } catch (_) {/* best effort — the in-memory flag still holds for this run */}
    if (!_ready) return;
    try {
      optedOut ? await Posthog().disable() : await Posthog().enable();
    } catch (_) {/* never surface analytics failures */}
  }
}

/// The complete event vocabulary. Adding one here is a deliberate act; the
/// point is that the list stays short enough to read.
///
/// The ticket funnel is the reason this exists, and it is deliberately three
/// separate steps rather than one "purchase" event — the drop-off between
/// *viewed* and *checkout started* is a pricing problem, and between *checkout
/// started* and *confirmed* is a payments problem. One number can't tell you
/// which one you have.
enum NileEvent {
  eventViewed('event_viewed'),
  ticketCheckoutStarted('ticket_checkout_started'),
  ticketConfirmed('ticket_confirmed'),
  ticketCancelled('ticket_cancelled'),
  replayCheckoutStarted('replay_checkout_started'),
  streamJoined('stream_joined'),
  tipSent('tip_sent'),
  eventPublished('event_published'),
  signUpCompleted('sign_up_completed');

  const NileEvent(this.name);

  /// The wire name. Kept explicit so renaming the Dart symbol can never
  /// silently split a funnel in the dashboard.
  final String name;
}
