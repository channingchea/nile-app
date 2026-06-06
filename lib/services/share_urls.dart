/// Canonical share-URL builder for Nile.
///
/// Every shareable link in the app flows through here, so the public-facing
/// domain is defined exactly once ([shareDomain]) and can be re-pointed later
/// with a one-line change. These produce real `https://` URLs that:
///   • open the app directly when installed (Universal Links / App Links), and
///   • fall back to a web landing page (with rich link-unfurl previews) when not.
///
/// Path scheme — matched by the `share` Edge Function and [DeepLinkService]:
///   event   → `https://<domain>/e/<id>`
///   post    → `https://<domain>/p/<id>`
///   profile → `https://<domain>/u/<username>`
library;

class ShareUrls {
  /// The public host that backs Universal Links / App Links and serves the web
  /// landing pages. Change this one line to move domains (also update the
  /// native config: iOS associated-domains + AASA, Android assetlinks.json).
  static const String shareDomain = 'links.nile.app';

  static const String _base = 'https://$shareDomain';

  static String event(String id) => '$_base/e/$id';
  static String post(String id) => '$_base/p/$id';
  static String profile(String username) => '$_base/u/$username';

  // ── Pre-formatted share captions (link on its own line so unfurlers grab it) ──

  static String eventCaption({
    required String id,
    required String title,
    String? hostUsername,
  }) {
    final by = hostUsername != null ? ' — @$hostUsername' : '';
    return '$title on Nile$by\n${event(id)}';
  }

  static String postCaption({required String id, required String authorUsername}) =>
      '@$authorUsername on Nile\n${post(id)}';

  static String profileCaption({
    required String username,
    String? displayName,
  }) {
    final name = (displayName != null && displayName.isNotEmpty)
        ? '$displayName (@$username)'
        : '@$username';
    return '$name on Nile\n${profile(username)}';
  }
}
