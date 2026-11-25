import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// The product name. Not translated — it's a proper noun.
  ///
  /// In en, this message translates to:
  /// **'Nile'**
  String get appTitle;

  /// Title of the confirmation dialog when a buyer cancels a ticket inside the free-cancellation window.
  ///
  /// In en, this message translates to:
  /// **'Cancel this ticket?'**
  String get cancelTicketTitle;

  /// Body of the ticket cancellation confirmation. The amount is pre-formatted with the currency, because which side of the number the symbol sits on is itself a locale decision.
  ///
  /// In en, this message translates to:
  /// **'{amount} goes back to the card you paid with, usually within 5–10 business days. You will lose access to “{eventTitle}”.'**
  String cancelTicketBody(String amount, String eventTitle);

  /// No description provided for @cancelTicketKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get cancelTicketKeep;

  /// No description provided for @cancelTicketConfirm.
  ///
  /// In en, this message translates to:
  /// **'Cancel ticket'**
  String get cancelTicketConfirm;

  /// No description provided for @cancelTicketDone.
  ///
  /// In en, this message translates to:
  /// **'Ticket cancelled — refund on its way.'**
  String get cancelTicketDone;

  /// Shown under the buy button, before payment. MUST quote the same window that refund-ticket enforces — see supabase/functions/_shared/money.ts.
  ///
  /// In en, this message translates to:
  /// **'Charged in US dollars. Free cancellation up to {hours} hours before the event starts.'**
  String ticketRefundPolicyShort(int hours);

  /// No description provided for @likeAction.
  ///
  /// In en, this message translates to:
  /// **'Like'**
  String get likeAction;

  /// No description provided for @unlikeAction.
  ///
  /// In en, this message translates to:
  /// **'Unlike'**
  String get unlikeAction;

  /// Screen-reader label for the like count. Plural, because a language with more than two forms cannot be served by an 's'.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 like} other{{count} likes}}'**
  String likeCount(int count);

  /// No description provided for @seeWhoLiked.
  ///
  /// In en, this message translates to:
  /// **'See who liked this, {likes}'**
  String seeWhoLiked(String likes);

  /// Screen-reader label for the notifications button when the badge is showing. The count matters — the badge is a purely visual signal.
  ///
  /// In en, this message translates to:
  /// **'Notifications, {count} unread'**
  String notificationsWithUnread(int count);

  /// No description provided for @notificationsLabel.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsLabel;

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// No description provided for @mute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get mute;

  /// No description provided for @unmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get unmute;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @showChat.
  ///
  /// In en, this message translates to:
  /// **'Show chat'**
  String get showChat;

  /// No description provided for @hideChat.
  ///
  /// In en, this message translates to:
  /// **'Hide chat'**
  String get hideChat;

  /// No description provided for @sendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get sendMessage;

  /// No description provided for @switchCamera.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get switchCamera;

  /// No description provided for @quietHoursTitle.
  ///
  /// In en, this message translates to:
  /// **'Hold notifications overnight'**
  String get quietHoursTitle;

  /// No description provided for @quietHoursOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get quietHoursOff;

  /// No description provided for @quietHoursRange.
  ///
  /// In en, this message translates to:
  /// **'Silent from {start} to {end}'**
  String quietHoursRange(String start, String end);

  /// No description provided for @quietHoursExplainer.
  ///
  /// In en, this message translates to:
  /// **'Notifications still arrive in the app — your phone just stays quiet. Alerts about a show starting, going live, or a soundcheck you’re crewing always come through.'**
  String get quietHoursExplainer;

  /// No description provided for @shareUsageData.
  ///
  /// In en, this message translates to:
  /// **'Share usage data'**
  String get shareUsageData;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
