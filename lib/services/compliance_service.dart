import '../config.dart';
import 'supabase_client.dart';

/// Age verification + Terms acceptance — the two records P3 #29/#30 added.
///
/// Nothing here writes a column directly: `record_compliance_consent` is the
/// only write path, and it re-checks the age server-side, so a patched client
/// cannot record a birthdate the database would refuse.
class ComplianceService {
  /// True once [birthdate] is at least [minimumAge] years ago. Mirrors the
  /// server's check so the form can say so before a round trip.
  static bool isOldEnough(DateTime birthdate) {
    final now = DateTime.now();
    final cutoff = DateTime(now.year - minimumAge, now.month, now.day);
    return !birthdate.isAfter(cutoff);
  }

  /// `YYYY-MM-DD`, the shape Postgres takes for a `date`.
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Record the birthdate (once — the first one is kept) and acceptance of the
  /// current [termsVersion]. Throws if the user is under [minimumAge].
  static Future<void> recordConsent(DateTime birthdate) async {
    await supabase.rpc(
      'record_compliance_consent',
      params: {
        'p_birthdate': isoDate(birthdate),
        'p_terms_version': termsVersion,
      },
    );
  }
}
