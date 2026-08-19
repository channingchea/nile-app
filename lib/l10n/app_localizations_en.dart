// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Nile';

  @override
  String get cancelTicketTitle => 'Cancel this ticket?';

  @override
  String cancelTicketBody(String amount, String eventTitle) {
    return '$amount goes back to the card you paid with, usually within 5–10 business days. You will lose access to “$eventTitle”.';
  }

  @override
  String get cancelTicketKeep => 'Keep it';

  @override
  String get cancelTicketConfirm => 'Cancel ticket';

  @override
  String get cancelTicketDone => 'Ticket cancelled — refund on its way.';

  @override
  String ticketRefundPolicyShort(int hours) {
    return 'Charged in US dollars. Free cancellation up to $hours hours before the event starts.';
  }

  @override
  String get likeAction => 'Like';

  @override
  String get unlikeAction => 'Unlike';

  @override
  String likeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count likes',
      one: '1 like',
    );
    return '$_temp0';
  }

  @override
  String seeWhoLiked(String likes) {
    return 'See who liked this, $likes';
  }

  @override
  String notificationsWithUnread(int count) {
    return 'Notifications, $count unread';
  }

  @override
  String get notificationsLabel => 'Notifications';

  @override
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get back => 'Back';

  @override
  String get close => 'Close';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get mute => 'Mute';

  @override
  String get unmute => 'Unmute';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get showChat => 'Show chat';

  @override
  String get hideChat => 'Hide chat';

  @override
  String get sendMessage => 'Send message';

  @override
  String get switchCamera => 'Switch camera';

  @override
  String get quietHoursTitle => 'Hold notifications overnight';

  @override
  String get quietHoursOff => 'Off';

  @override
  String quietHoursRange(String start, String end) {
    return 'Silent from $start to $end';
  }

  @override
  String get quietHoursExplainer =>
      'Notifications still arrive in the app — your phone just stays quiet. Alerts about a show starting, going live, or a soundcheck you’re crewing always come through.';

  @override
  String get shareUsageData => 'Share usage data';
}
