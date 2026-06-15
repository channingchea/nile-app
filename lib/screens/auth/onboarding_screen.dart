import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../services/follow_service.dart';
import '../../services/profile_service.dart';
import '../../services/push_service.dart';
import '../../services/search_service.dart';
import '../../services/supabase_client.dart';
import '../../theme.dart';
import 'interest_picker_screen.dart';

/// Post-signup onboarding: avatar → bio → interests → follows → push.
/// Every step is skippable; each persists on advance so a force-quit loses
/// nothing. The final action stamps `profiles.onboarded_at`, after which
/// [onDone] tells _AuthGate to swap to HomeScreen.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { avatar, bio, interests, follows, push }

class _OnboardingScreenState extends State<OnboardingScreen> {
  // Push permission prompts only exist on iOS/Android.
  static bool get _pushSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  late final List<_Step> _steps = [
    _Step.avatar,
    _Step.bio,
    _Step.interests,
    _Step.follows,
    if (_pushSupported) _Step.push,
  ];

  final _pageController = PageController();
  final _bioController = TextEditingController();
  int _index = 0;
  bool _busy = false;

  // Avatar state
  Uint8List? _avatarBytes;

  // Follows state
  List<UserProfile>? _suggested;
  final Set<String> _followed = {};
  String? _followError;

  // Push state
  bool? _pushGranted;

  String get _uid => supabase.auth.currentUser!.id;
  _Step get _step => _steps[_index];
  bool get _isLast => _index == _steps.length - 1;

  @override
  void initState() {
    super.initState();
    _loadSuggested();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _loadSuggested() async {
    try {
      final page = await SearchService.suggestedUsers();
      if (mounted) setState(() => _suggested = page.items);
    } catch (e) {
      if (mounted) setState(() => _followError = 'Couldn\'t load people: $e');
    }
  }

  // ── Step actions ────────────────────────────────────────────────────────────

  Future<void> _pickAvatar() async {
    setState(() => _busy = true);
    try {
      final res = await ProfileService.pickAndUploadAvatar(_uid, context);
      if (res != null && mounted) setState(() => _avatarBytes = res.bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Persist the bio if entered. Avatar/interests/follows already saved on
  /// interaction, so advancing those steps is pure navigation.
  Future<void> _persistCurrentStep() async {
    if (_step != _Step.bio) return;
    final bio = _bioController.text.trim();
    if (bio.isEmpty) return;
    await ProfileService.updateProfile(userId: _uid, bio: bio);
  }

  Future<void> _toggleFollow(UserProfile user) async {
    final wasFollowed = _followed.contains(user.id);
    setState(
      () => wasFollowed ? _followed.remove(user.id) : _followed.add(user.id),
    );
    try {
      wasFollowed
          ? await FollowService.unfollow(user.id)
          : await FollowService.follow(user.id);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              wasFollowed ? _followed.add(user.id) : _followed.remove(user.id),
        );
      }
    }
  }

  Future<void> _enablePush() async {
    setState(() => _busy = true);
    try {
      final granted = await PushService.requestPermission();
      if (mounted) setState(() => _pushGranted = granted);
    } catch (_) {
      if (mounted) setState(() => _pushGranted = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Navigation ──────────────────────────────────────────────────────────────

  Future<void> _next({bool skip = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!skip) await _persistCurrentStep();
      if (_isLast) {
        await ProfileService.markOnboarded();
        widget.onDone();
        return;
      }
      setState(() => _index++);
      _pageController.animateToPage(
        _index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  static const _titles = {
    _Step.avatar: 'Add a profile photo',
    _Step.bio: 'Tell people about you',
    _Step.interests: 'Pick your interests',
    _Step.follows: 'Find your people',
    _Step.push: 'Don\'t miss a show',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: Text('Welcome to Nile', style: NileTextStyles.headingMd()),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _next(skip: true),
            child: Text(
              _isLast ? 'Skip & finish' : 'Skip',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
        ],
      ),
      body: NileMaxWidth(
        child: Column(
          children: [
            _progressDots(),
            const SizedBox(height: 12),
            Text(_titles[_step]!, style: NileTextStyles.headingLg()),
            const SizedBox(height: 8),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final s in _steps)
                    switch (s) {
                      _Step.avatar => _avatarStep(),
                      _Step.bio => _bioStep(),
                      _Step.interests => const InterestPicker(),
                      _Step.follows => _followsStep(),
                      _Step.push => _pushStep(),
                    },
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _next,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                    textStyle: NileTextStyles.labelLg().copyWith(color: null),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.bgPage,
                          ),
                        )
                      : Text(_isLast ? 'Done' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressDots() {
    return Padding(
      padding: const EdgeInsets.only(top: NileSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < _steps.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: NileSpacing.s4),
              width: i == _index ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= _index ? NileColors.volt : NileColors.bgRaised,
                borderRadius: BorderRadius.circular(NileRadius.pill),
              ),
            ),
        ],
      ),
    );
  }

  // ── Step bodies ─────────────────────────────────────────────────────────────

  Widget _avatarStep() {
    return _StepBody(
      caption: 'Help people recognize you. You can change this anytime.',
      child: Center(
        child: GestureDetector(
          onTap: _busy ? null : _pickAvatar,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              CircleAvatar(
                radius: 72,
                backgroundColor: NileColors.bgRaised,
                backgroundImage: _avatarBytes != null
                    ? MemoryImage(_avatarBytes!)
                    : null,
                child: _avatarBytes == null
                    ? const Icon(
                        Icons.person_outline,
                        size: 56,
                        color: NileColors.txtTertiary,
                      )
                    : null,
              ),
              Container(
                padding: const EdgeInsets.all(NileSpacing.s8),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: NileColors.volt,
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 20,
                  color: NileColors.bgPage,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bioStep() {
    return _StepBody(
      caption: 'A line or two about what you stream, host, or love watching.',
      child: TextField(
        controller: _bioController,
        maxLength: 200,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: 'e.g. DJ + producer. Friday night house sets.',
        ),
      ),
    );
  }

  Widget _followsStep() {
    if (_followError != null) {
      return Center(
        child: Text(
          _followError!,
          style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
        ),
      );
    }
    final users = _suggested;
    if (users == null) {
      return const Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }
    if (users.isEmpty) {
      return Center(
        child: Text(
          'No suggestions yet — you\'re early!',
          style: NileTextStyles.bodySm(),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s24),
      itemCount: users.length,
      itemBuilder: (_, i) {
        final u = users[i];
        final following = _followed.contains(u.id);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: NileColors.bgRaised,
                backgroundImage: u.avatarUrl != null
                    ? nileAvatarImage(u.avatarUrl!, 22)
                    : null,
                child: u.avatarUrl == null
                    ? const Icon(
                        Icons.person_outline,
                        size: 22,
                        color: NileColors.txtTertiary,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.displayName, style: NileTextStyles.labelMd()),
                    Text(
                      '@${u.username}'
                      '${u.followerCount > 0 ? ' · ${u.followerCount} followers' : ''}',
                      style: NileTextStyles.bodySm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              following
                  ? OutlinedButton(
                      onPressed: () => _toggleFollow(u),
                      child: const Text('Following'),
                    )
                  : FilledButton(
                      onPressed: () => _toggleFollow(u),
                      child: const Text('Follow'),
                    ),
            ],
          ),
        );
      },
    );
  }

  Widget _pushStep() {
    return _StepBody(
      caption:
          'Get a heads-up when someone you follow goes live or an event you '
          'have tickets to is starting.',
      child: Column(
        children: [
          const Icon(
            Icons.notifications_active_outlined,
            size: 64,
            color: NileColors.volt,
          ),
          const SizedBox(height: 24),
          if (_pushGranted == true)
            Text(
              'Notifications on 🎉',
              style: NileTextStyles.labelLg().copyWith(
                color: NileColors.success,
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: _busy ? null : _enablePush,
              icon: const Icon(Icons.notifications_none),
              label: const Text('Enable notifications'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s24,
                  vertical: NileSpacing.s16,
                ),
              ),
            ),
          if (_pushGranted == false) ...[
            const SizedBox(height: 12),
            Text(
              'No worries — you can turn these on later in Settings.',
              style: NileTextStyles.bodySm(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared step layout: caption text above the step's content.
class _StepBody extends StatelessWidget {
  const _StepBody({required this.caption, required this.child});
  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            caption,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm(),
          ),
          const SizedBox(height: 32),
          child,
        ],
      ),
    );
  }
}
