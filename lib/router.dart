import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/appearance_screen.dart';
import 'screens/attendee_list_screen.dart';
import 'screens/audio_screen.dart';
import 'screens/auth/claim_username_screen.dart';
import 'screens/auth/feature_intro_screen.dart';
import 'screens/auth/forgot_password_screen.dart';
import 'screens/auth/interest_picker_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/mfa_backup_codes_screen.dart';
import 'screens/auth/mfa_challenge_screen.dart';
import 'screens/auth/mfa_connect_gate_screen.dart';
import 'screens/auth/mfa_enroll_screen.dart';
import 'screens/auth/mfa_recovery_screen.dart';
import 'screens/auth/mfa_settings_screen.dart';
import 'screens/auth/onboarding_screen.dart';
import 'screens/auth/reset_password_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/blocked_accounts_screen.dart';
import 'screens/boost_performance_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/change_password_screen.dart';
import 'screens/conversation_screen.dart';
import 'screens/create_current_screen.dart';
import 'screens/create_event_flow.dart';
import 'screens/create_post_screen.dart';
import 'screens/crew_setup_screen.dart';
import 'screens/currents_player_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/edit_event_screen.dart';
import 'screens/edit_post_screen.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/event_detail_screen.dart';
import 'screens/follow_list_screen.dart';
import 'screens/home_screen.dart';
import 'screens/like_list_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/my_currents_screen.dart';
import 'screens/my_report_screen.dart';
import 'screens/my_tickets_screen.dart';
import 'screens/notification_preferences_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/payouts_screen.dart';
import 'screens/post_detail_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/replay_pricing_screen.dart';
import 'screens/replay_screen.dart';
import 'screens/report_issue_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/user_list_screen.dart';
import 'screens/viewer_screen.dart';
import 'services/auth_gate.dart';
import 'services/event_service.dart';
import 'services/feedback_service.dart';
import 'services/message_service.dart';
import 'services/post_service.dart';
import 'services/profile_service.dart';
import 'services/tab_refresh.dart';
import 'theme.dart';
import 'widgets/nile_app_shell.dart';

/// Every location in the app, as functions rather than raw strings so a typo is
/// a compile error and the path shapes live in one place.
///
/// Screens that take a whole model (`Event`, `Post`, `UserProfile`,
/// `Conversation`) still get it — passed as go_router `extra` — while the id in
/// the path is what makes the location shareable and reload-safe. When `extra`
/// is absent (a cold deep link, a push notification, a web refresh) the route
/// fetches by id instead; see [_Resolve].
class NileRoutes {
  NileRoutes._();

  static const splash = '/splash';
  static const intro = '/intro';
  static const login = '/login';
  static const signup = '/signup';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const mfaChallenge = '/mfa-challenge';
  static const claimUsername = '/claim-username';
  static const onboarding = '/onboarding';

  /// Locations the gate owns. Reaching `ready` from any of them means going
  /// home instead of staying put.
  static const gateOnly = {
    splash,
    intro,
    login,
    signup,
    forgotPassword,
    mfaChallenge,
    claimUsername,
    onboarding,
  };

  /// Reachable while signed out.
  static const signedOutAllowed = {login, signup, forgotPassword, resetPassword};

  // Shell branches.
  static const feed = '/';
  static const messages = '/messages';

  /// Desktop's fifth destination. Declared last among the branches so adding it
  /// renumbered none of the existing ones; the phone bar has no slot for it, so
  /// on a phone this is reachable only from a link.
  static const schedule = '/schedule';
  static String discover({int tab = 0}) => tab == 0 ? '/discover' : '/discover?tab=$tab';
  static String profile([String? userId]) => userId == null ? '/profile' : '/u/$userId';

  // Detail routes, above the shell.
  static String event(String id, {String? fromProfileId}) =>
      fromProfileId == null ? '/event/$id' : '/event/$id?from=$fromProfileId';
  static String eventEdit(String id) => '/event/$id/edit';
  static String eventReplay(String id) => '/event/$id/replay';
  static String eventReplayPricing(String id) => '/event/$id/replay-pricing';
  static String eventAttendees(String id) => '/event/$id/attendees';
  static String eventCrew(String id, {bool audio = false}) =>
      '/event/$id/crew?audio=$audio';
  static String watch(String liveKitEventId) => '/watch/$liveKitEventId';
  static String stream(
    String liveKitEventId, {
    required bool audio,
    bool host = true,
    String? cameraName,
  }) {
    final q = 'audio=$audio&host=$host';
    return cameraName == null
        ? '/stream/$liveKitEventId?$q'
        : '/stream/$liveKitEventId?$q&name=${Uri.encodeComponent(cameraName)}';
  }

  static String post(String id, {String? fromProfileId}) =>
      fromProfileId == null ? '/post/$id' : '/post/$id?from=$fromProfileId';
  static String postEdit(String id) => '/post/$id/edit';
  static String postLikes(String id) => '/post/$id/likes';
  static String eventLikes(String id) => '/event/$id/likes';
  static String followers(String userId) => '/u/$userId/followers';
  static String following(String userId) => '/u/$userId/following';
  static String dm(String otherUserId) => '/dm/$otherUserId';

  static const notifications = '/notifications';
  static const currents = '/currents';
  static String currentsFrom(String userId) => '/currents?user=$userId';
  static const boost = '/boost';
  static String report(String id) => '/report/$id';
  static const userList = '/people';

  static const createPost = '/create/post';
  static const createCurrent = '/create/current';
  static const createEvent = '/create/event';

  static const settings = '/settings';
  static const settingsAppearance = '/settings/appearance';
  static const settingsEditProfile = '/settings/profile';
  static const settingsCurrents = '/settings/currents';
  static const settingsReport = '/settings/report';
  static const settingsTickets = '/settings/tickets';
  static const settingsPayouts = '/settings/payouts';
  static const settingsInterests = '/settings/interests';
  static const settingsNotifications = '/settings/notifications';
  static const settingsPassword = '/settings/password';
  static const settingsMfa = '/settings/mfa';
  static const settingsBlocked = '/settings/blocked';

  static const mfaEnroll = '/mfa/enroll';
  static const mfaBackupCodes = '/mfa/backup-codes';
  static const mfaRecovery = '/mfa/recovery';
  static const mfaConnectGate = '/mfa/connect-gate';

  /// An event card leads to the live viewer while the show is on air and to the
  /// event page otherwise. That ternary was repeated at seven call sites.
  /// `liveKitEventId` is nullable on the model: a show can be live-flagged
  /// before a room exists. No room means there is nothing to watch, so fall
  /// back to the event page rather than opening an empty viewer.
  static String eventOrWatch({
    required bool isLive,
    required String eventId,
    required String? liveKitEventId,
    String? fromProfileId,
  }) => isLive && liveKitEventId != null
      ? watch(liveKitEventId)
      : event(eventId, fromProfileId: fromProfileId);
}

/// Holds exactly two things: the auth gate's routes, and the shell below. Once
/// signed in it has a single page, so `canPop` on it is always false — anything
/// asking "is something pushed?" wants [shellNavigatorKey] instead.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Where every signed-in page lives, including the detail screens that used to
/// push onto the root navigator. The desktop chrome is drawn around this
/// navigator, which is what lets the nav rail survive a push.
final shellNavigatorKey = GlobalKey<NavigatorState>();

final _feedNavigatorKey = GlobalKey<NavigatorState>();
final _discoverNavigatorKey = GlobalKey<NavigatorState>();
final _messagesNavigatorKey = GlobalKey<NavigatorState>();
final _profileNavigatorKey = GlobalKey<NavigatorState>();
final _scheduleNavigatorKey = GlobalKey<NavigatorState>();

/// Navigate from outside a widget (push notifications, deep links, services).
GoRouter get nileRouter => _router;

final GoRouter _router = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: NileRoutes.splash,
  refreshListenable: AuthGate.instance,
  redirect: _gateRedirect,
  routes: [
    // ── The gate ────────────────────────────────────────────────────────────
    GoRoute(path: NileRoutes.splash, builder: (_, _) => const SplashScreen()),
    GoRoute(
      path: NileRoutes.intro,
      builder: (_, _) => FeatureIntroScreen(onDone: AuthGate.instance.dismissIntro),
    ),
    GoRoute(path: NileRoutes.login, builder: (_, _) => const LoginScreen()),
    GoRoute(path: NileRoutes.signup, builder: (_, _) => const SignupScreen()),
    GoRoute(
      path: NileRoutes.forgotPassword,
      builder: (_, s) => ForgotPasswordScreen(initialEmail: s.uri.queryParameters['email']),
    ),
    GoRoute(
      path: NileRoutes.resetPassword,
      builder: (_, _) => const ResetPasswordScreen(),
    ),
    GoRoute(
      path: NileRoutes.mfaChallenge,
      builder: (_, _) => MfaChallengeScreen(onVerified: AuthGate.instance.mfaVerified),
    ),
    GoRoute(
      path: NileRoutes.claimUsername,
      builder: (_, _) => ClaimUsernameScreen(onDone: AuthGate.instance.usernameClaimed),
    ),
    GoRoute(
      path: NileRoutes.onboarding,
      builder: (_, _) => OnboardingScreen(onDone: AuthGate.instance.onboarded),
    ),

    // ── The signed-in tree, under the desktop chrome ────────────────────────
    // Everything reachable once you are in lives inside this ShellRoute. On a
    // phone `NileAppShell` is a pass-through, so this renders exactly as it did
    // when these were root-level siblings. On a desktop it draws the nav rail,
    // top bar and context rail ONCE, above both the tab shell and the detail
    // screens — so pushing an event page changes the content and nothing else.
    // That is the whole reason it exists: the agreed layout for the live viewer
    // has a right-hand column that is part of the screen, which is impossible
    // if opening the screen covers the chrome.
    //
    // Detail screens stay siblings of the tab shell rather than becoming
    // children of a branch. Nesting them under one branch would make opening an
    // event from Discover jump you to Home; duplicating them under all five
    // would make `/event/:id` ambiguous for a deep link.
    ShellRoute(
      navigatorKey: shellNavigatorKey,
      builder: (_, state, child) =>
          NileAppShell(location: state.uri.path, child: child),
      routes: [
      StatefulShellRoute(
        builder: (_, _, shell) => HomeScreen(shell: shell),
        // The stock .indexedStack container has no HeroMode wrapping. Every
        // visited tab stays mounted, so the same event can hold a live Hero on
        // two tabs at once — duplicate tags abort ALL hero flights.
        navigatorContainerBuilder: (_, shell, children) => IndexedStack(
          index: shell.currentIndex,
          children: [
            for (final (i, child) in children.indexed)
              HeroMode(enabled: i == shell.currentIndex, child: child),
          ],
        ),
        branches: [
          StatefulShellBranch(
            navigatorKey: _feedNavigatorKey,
            routes: [
              GoRoute(
                path: NileRoutes.feed,
                builder: (_, _) => ValueListenableBuilder<int>(
                  valueListenable: TabRefresh.feed,
                  builder: (_, k, _) => FeedTab(key: ValueKey(k)),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _discoverNavigatorKey,
            routes: [
              GoRoute(
                path: '/discover',
                builder: (_, s) {
                  final tab = int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0;
                  return ValueListenableBuilder<int>(
                    valueListenable: TabRefresh.discover,
                    // The tab index is part of the key: arriving at /discover?tab=2
                    // from elsewhere has to remount, the way bumping _discoverKey
                    // used to.
                    builder: (_, k, _) =>
                        DiscoverScreen(key: ValueKey('$k-$tab'), initialTab: tab),
                  );
                },
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _messagesNavigatorKey,
            routes: [
              GoRoute(path: NileRoutes.messages, builder: (_, _) => const MessagesScreen()),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _profileNavigatorKey,
            routes: [
              GoRoute(
                path: '/profile',
                builder: (_, _) => ValueListenableBuilder<int>(
                  valueListenable: TabRefresh.profile,
                  builder: (_, k, _) => ProfileScreen(key: ValueKey(k)),
                ),
              ),
            ],
          ),
          // Branch 4 — Schedule. Appended rather than slotted in beside Home so
          // no existing branch index changed: `shell.goBranch(3)` still means
          // Profile everywhere it appears. The desktop rail reorders it for
          // display (see kNileRailBranches).
          StatefulShellBranch(
            navigatorKey: _scheduleNavigatorKey,
            routes: [
              GoRoute(
                path: NileRoutes.schedule,
                builder: (_, _) => const ScheduleScreen(),
              ),
            ],
          ),
        ],
      ),

      // ── Events ──────────────────────────────────────────────────────────────
      GoRoute(
        path: '/event/:id',
        builder: (_, s) {
          final id = s.pathParameters['id']!;
          final from = s.uri.queryParameters['from'];
          final event = s.extra;
          if (event is Event) {
            return EventDetailScreen(event: event, fromProfileId: from);
          }
          return EventDetailScreen(eventId: id, fromProfileId: from);
        },
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, s) => _Resolve<Event>(
              value: s.extra,
              fetch: () => EventService.fetchById(s.pathParameters['id']!),
              builder: (event) => EditEventScreen(event: event),
            ),
          ),
          GoRoute(
            path: 'replay',
            builder: (_, s) => _Resolve<Event>(
              value: s.extra,
              fetch: () => EventService.fetchById(s.pathParameters['id']!),
              builder: (event) => ReplayScreen(event: event),
            ),
          ),
          GoRoute(
            path: 'replay-pricing',
            builder: (_, s) => _Resolve<Event>(
              value: s.extra,
              fetch: () => EventService.fetchById(s.pathParameters['id']!),
              builder: (event) => ReplayPricingScreen(event: event),
            ),
          ),
          GoRoute(
            path: 'attendees',
            builder: (_, s) => _Resolve<Event>(
              value: s.extra,
              fetch: () => EventService.fetchById(s.pathParameters['id']!),
              builder: (event) =>
                  AttendeeListScreen(eventId: event.id, eventTitle: event.title),
            ),
          ),
          GoRoute(
            path: 'crew',
            builder: (context, s) {
              final id = s.pathParameters['id']!;
              final audio = s.uri.queryParameters['audio'] == 'true';
              return CrewSetupScreen(
                eventId: id,
                // Crew setup hands straight off to the stream it was set up for,
                // replacing itself so back doesn't land on the setup form.
                onContinue: () => context.pushReplacement(
                  NileRoutes.stream(id, audio: audio),
                ),
              );
            },
          ),
          GoRoute(
            path: 'likes',
            builder: (_, s) => LikeListScreen.event(s.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/watch/:id',
        builder: (_, s) => ViewerScreen(initialEventId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/stream/:id',
        builder: (_, s) {
          final id = s.pathParameters['id']!;
          final host = s.uri.queryParameters['host'] != 'false';
          return s.uri.queryParameters['audio'] == 'true'
              ? AudioScreen(initialEventId: id, isHost: host)
              : CameraScreen(
                  initialEventId: id,
                  isHost: host,
                  initialCameraName: s.uri.queryParameters['name'],
                );
        },
      ),

      // ── Posts ───────────────────────────────────────────────────────────────
      GoRoute(
        path: '/post/:id',
        builder: (_, s) => _Resolve<Post>(
          value: s.extra,
          fetch: () => PostService.fetchById(s.pathParameters['id']!),
          builder: (post) => PostDetailScreen(
            post: post,
            fromProfileId: s.uri.queryParameters['from'],
          ),
        ),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, s) => _Resolve<Post>(
              value: s.extra,
              fetch: () => PostService.fetchById(s.pathParameters['id']!),
              builder: (post) => EditPostScreen(post: post),
            ),
          ),
          GoRoute(
            path: 'likes',
            builder: (_, s) => LikeListScreen.post(s.pathParameters['id']!),
          ),
        ],
      ),

      // ── People ──────────────────────────────────────────────────────────────
      GoRoute(
        path: '/u/:id',
        builder: (_, s) => ProfileScreen(userId: s.pathParameters['id']),
        routes: [
          GoRoute(
            path: 'followers',
            builder: (_, s) => FollowListScreen(
              userId: s.pathParameters['id']!,
              displayName: s.uri.queryParameters['name'] ?? '',
              mode: FollowListMode.followers,
            ),
          ),
          GoRoute(
            path: 'following',
            builder: (_, s) => FollowListScreen(
              userId: s.pathParameters['id']!,
              displayName: s.uri.queryParameters['name'] ?? '',
              mode: FollowListMode.following,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/dm/:userId',
        builder: (_, s) => _Resolve<Conversation>(
          value: s.extra,
          fetch: () => MessageService.getOrCreate(s.pathParameters['userId']!),
          builder: (conv) => ConversationScreen(conversation: conv),
        ),
      ),
      GoRoute(
        path: NileRoutes.userList,
        // Driven by a fetcher closure, so it only exists as a pushed destination —
        // there is nothing to put in a URL. Falls back to the profile tab if a
        // cold link ever reaches it.
        builder: (_, s) => s.extra is UserListArgs
            ? (s.extra as UserListArgs).build()
            : const ProfileScreen(),
      ),

      // ── Everything else above the shell ─────────────────────────────────────
      GoRoute(path: NileRoutes.notifications, builder: (_, _) => const NotificationsScreen()),
      GoRoute(
        path: NileRoutes.currents,
        builder: (_, s) =>
            CurrentsPlayerScreen(startUserId: s.uri.queryParameters['user']),
      ),
      GoRoute(path: NileRoutes.boost, builder: (_, _) => const BoostPerformanceScreen()),
      GoRoute(
        path: '/report/:id',
        builder: (_, s) => MyReportScreen(reportId: s.pathParameters['id']!),
      ),

      GoRoute(path: NileRoutes.createPost, builder: (_, s) {
        final args = s.extra;
        return args is CreatePostArgs
            ? CreatePostScreen(initialText: args.initialText, eventId: args.eventId)
            : const CreatePostScreen();
      }),
      GoRoute(path: NileRoutes.createCurrent, builder: (_, _) => const CreateCurrentScreen()),
      GoRoute(path: NileRoutes.createEvent, builder: (_, _) => const CreateEventFlow()),

      GoRoute(
        path: NileRoutes.settings,
        builder: (_, s) => _Resolve<UserProfile>(
          value: s.extra,
          fetch: ProfileService.fetchCurrentProfile,
          builder: (profile) => SettingsScreen(profile: profile),
        ),
        routes: [
          GoRoute(path: 'appearance', builder: (_, _) => const AppearanceScreen()),
          GoRoute(
            path: 'profile',
            builder: (_, s) => _Resolve<UserProfile>(
              value: s.extra,
              fetch: ProfileService.fetchCurrentProfile,
              builder: (profile) => EditProfileScreen(profile: profile),
            ),
          ),
          GoRoute(path: 'currents', builder: (_, _) => const MyCurrentsScreen()),
          GoRoute(
            path: 'report',
            builder: (_, s) {
              final args = s.extra;
              return args is ReportIssueArgs
                  ? ReportIssueScreen(
                      initialKind: args.kind,
                      initialImage: args.image,
                      source: args.source,
                    )
                  : const ReportIssueScreen();
            },
          ),
          GoRoute(path: 'tickets', builder: (_, _) => const MyTicketsScreen()),
          GoRoute(path: 'payouts', builder: (_, _) => const PayoutsScreen()),
          GoRoute(path: 'interests', builder: (_, _) => const InterestPickerScreen()),
          GoRoute(
            path: 'notifications',
            builder: (_, _) => const NotificationPreferencesScreen(),
          ),
          GoRoute(path: 'password', builder: (_, _) => const ChangePasswordScreen()),
          GoRoute(path: 'mfa', builder: (_, _) => const MfaSettingsScreen()),
          GoRoute(path: 'blocked', builder: (_, _) => const BlockedAccountsScreen()),
        ],
      ),

      GoRoute(path: NileRoutes.mfaEnroll, builder: (_, _) => const MfaEnrollScreen()),
      GoRoute(
        path: NileRoutes.mfaBackupCodes,
        // One-shot secrets: they exist only in memory, so this route is reachable
        // only with them in hand.
        builder: (_, s) {
          final args = s.extra;
          return args is BackupCodesArgs
              ? MfaBackupCodesScreen(codes: args.codes, afterEnroll: args.afterEnroll)
              : const MfaSettingsScreen();
        },
      ),
      GoRoute(path: NileRoutes.mfaRecovery, builder: (_, _) => const MfaRecoveryScreen()),
      GoRoute(
        path: NileRoutes.mfaConnectGate,
        builder: (_, _) => const MfaConnectGateScreen(),
      ),
      ],
    ),
  ],
);

/// The auth/onboarding ladder, expressed as a redirect. Order matches the old
/// `_AuthGate.build` exactly.
String? _gateRedirect(BuildContext context, GoRouterState state) {
  final gate = AuthGate.instance;
  final loc = state.matchedLocation;

  switch (gate.stage) {
    case GateStage.splash:
      return loc == NileRoutes.splash ? null : NileRoutes.splash;
    case GateStage.intro:
      return loc == NileRoutes.intro ? null : NileRoutes.intro;
    case GateStage.signedOut:
      if (gate.introWantsSignup) {
        gate.consumeIntroSignup();
        return NileRoutes.signup;
      }
      return NileRoutes.signedOutAllowed.contains(loc) ? null : NileRoutes.login;
    case GateStage.mfaChallenge:
      return loc == NileRoutes.mfaChallenge ? null : NileRoutes.mfaChallenge;
    case GateStage.claimUsername:
      return loc == NileRoutes.claimUsername ? null : NileRoutes.claimUsername;
    case GateStage.onboarding:
      return loc == NileRoutes.onboarding ? null : NileRoutes.onboarding;
    case GateStage.ready:
      // A recovery link outranks wherever they were: they opened it to set a
      // new password.
      if (gate.passwordRecovery) {
        return loc == NileRoutes.resetPassword ? null : NileRoutes.resetPassword;
      }
      return NileRoutes.gateOnly.contains(loc) ? NileRoutes.feed : null;
  }
}

/// Arguments for routes whose screen takes something a URL can't carry.
class CreatePostArgs {
  final String? initialText;
  final String? eventId;
  const CreatePostArgs({this.initialText, this.eventId});
}

class ReportIssueArgs {
  final FeedbackKind kind;
  final Uint8List? image;
  final String source;
  const ReportIssueArgs({
    this.kind = FeedbackKind.bug,
    this.image,
    this.source = 'settings',
  });
}

class BackupCodesArgs {
  final List<String> codes;
  final bool afterEnroll;
  const BackupCodesArgs({required this.codes, this.afterEnroll = true});
}

/// `UserListScreen` is parameterised by a paging closure, so its "route" is
/// really just a pushed widget. This carries it through `extra`.
class UserListArgs {
  final String title;
  final UserPageFetcher fetch;
  final String emptyText;
  final String? subtitle;
  final IconData emptyIcon;
  const UserListArgs({
    required this.title,
    required this.fetch,
    required this.emptyText,
    this.subtitle,
    this.emptyIcon = Icons.people_outline,
  });

  UserListScreen build() => UserListScreen(
    title: title,
    fetch: fetch,
    emptyText: emptyText,
    subtitle: subtitle,
    emptyIcon: emptyIcon,
  );
}

/// Bridges "the caller already has the model" and "we arrived cold from a link".
///
/// In-app navigation passes the object through `extra` and this builds it
/// immediately — no spinner, no refetch, identical to the old
/// `Navigator.push(MaterialPageRoute(builder: (_) => Screen(model: model)))`.
/// A deep link, a push notification tap or a web reload has no `extra`, so it
/// falls back to fetching by the id in the path.
class _Resolve<T extends Object> extends StatefulWidget {
  const _Resolve({
    required this.value,
    required this.fetch,
    required this.builder,
  });

  final Object? value;
  final Future<T?> Function() fetch;
  final Widget Function(T value) builder;

  @override
  State<_Resolve<T>> createState() => _ResolveState<T>();
}

class _ResolveState<T extends Object> extends State<_Resolve<T>> {
  late Future<T?> _future;

  @override
  void initState() {
    super.initState();
    final value = widget.value;
    _future = value is T ? Future<T?>.value(value) : widget.fetch();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    if (value is T) return widget.builder(value);
    return FutureBuilder<T?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final resolved = snap.data;
        if (resolved == null) return const _Gone();
        return widget.builder(resolved);
      },
    );
  }
}

/// Deleted, or never existed. Reachable only from a stale link.
class _Gone extends StatelessWidget {
  const _Gone();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_rounded, size: 48, color: NileColors.txtTertiary),
              const SizedBox(height: NileSpacing.s16),
              Text("This isn't here anymore", style: NileTextStyles.headingSm()),
              const SizedBox(height: NileSpacing.s8),
              Text(
                'It may have been deleted, or the link is wrong.',
                textAlign: TextAlign.center,
                style: NileTextStyles.bodySm()
                    .copyWith(color: NileColors.txtSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
