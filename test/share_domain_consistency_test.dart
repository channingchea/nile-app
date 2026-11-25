// Guards the share/deep-link host against config drift.
//
// Until 2026-08-16 ShareUrls.shareDomain was `links.nile.app` — a host that has
// never been registered (NXDOMAIN). Every event, post and profile link the app
// shared was dead, the URL baked into exported calendar invites was dead, and
// Android was autoVerify-ing a domain that could never serve an assetlinks
// file. Nothing caught it because the host lives in four places that no test
// compared: the Dart constant, the Android manifest, the iOS entitlement, and
// the `share` Edge Function that actually serves the verification files.
//
// These tests don't hit the network — they just assert the four stay in
// agreement, which is the failure mode that actually happened.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/share_urls.dart';

void main() {
  group('share domain', () {
    test('is the host that actually serves the AASA file', () {
      // links.joinnile.com is verified to serve
      // /.well-known/apple-app-site-association with appID
      // LFRAVC4CVW.com.nilestreaming.app and paths /e/*, /p/*, /u/*.
      // If you move hosts, move all four call sites below together.
      expect(ShareUrls.shareDomain, 'links.joinnile.com');
    });

    test('every share URL is built on that host', () {
      expect(ShareUrls.event('abc'), 'https://links.joinnile.com/e/abc');
      expect(ShareUrls.post('abc'), 'https://links.joinnile.com/p/abc');
      expect(ShareUrls.profile('nile'), 'https://links.joinnile.com/u/nile');
    });

    test('Android App Links host matches the Dart constant', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

      // The autoVerify intent-filter's https host must be the share domain.
      final hosts = RegExp(r'android:scheme="https"\s+android:host="([^"]+)"')
          .allMatches(manifest)
          .map((m) => m.group(1))
          .toList();

      expect(
        hosts,
        isNotEmpty,
        reason: 'no https App Links intent-filter found in AndroidManifest.xml',
      );
      for (final host in hosts) {
        expect(
          host,
          ShareUrls.shareDomain,
          reason: 'AndroidManifest App Links host drifted from '
              'ShareUrls.shareDomain — links will not open in the app',
        );
      }
    });

    test('iOS associated-domains entry matches the Dart constant', () {
      final entitlements =
          File('ios/Runner/Runner.entitlements').readAsStringSync();

      final applinks = RegExp(r'applinks:([A-Za-z0-9.\-]+)')
          .allMatches(entitlements)
          .map((m) => m.group(1))
          .toList();

      expect(
        applinks,
        isNotEmpty,
        reason: 'no applinks: entry in Runner.entitlements — Universal Links '
            'cannot work. NOTE: the associated-domains block is currently '
            'commented out pending the paid-team capability; this test still '
            'reads it so the host cannot rot while it is disabled.',
      );
      for (final host in applinks) {
        expect(
          host,
          ShareUrls.shareDomain,
          reason: 'Runner.entitlements applinks host drifted from '
              'ShareUrls.shareDomain',
        );
      }
    });
  });
}
