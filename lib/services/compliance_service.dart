import '../config.dart';
import 'age_signals_service.dart';
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

  /// Record an age bracket vouched for by the App Store (or Play) plus the
  /// same Terms acceptance (P4). Replaces an earlier typed birthday, because
  /// it is strictly better evidence; the reverse never happens.
  ///
  /// Throws if the store says this person is under [minimumAge].
  static Future<void> recordAssuredAge(AgeSignal signal, {required String source}) async {
    await supabase.rpc(
      'record_assured_age',
      params: {
        'p_lower_bound': signal.lowerBound,
        'p_upper_bound': signal.upperBound,
        'p_declaration': signal.declaration,
        'p_source': source,
        'p_communication_limits': signal.communicationLimits,
        'p_terms_version': termsVersion,
      },
    );
  }
}
