import 'package:flutter/material.dart';
import '../services/follow_service.dart';
import 'user_list_screen.dart';

enum FollowListMode { followers, following }

/// Followers / following list for a user. Thin wrapper over [UserListScreen].
class FollowListScreen extends StatelessWidget {
  final String userId;
  final String displayName;
  final FollowListMode mode;

  const FollowListScreen({
    super.key,
    required this.userId,
    required this.displayName,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final followers = mode == FollowListMode.followers;
    return UserListScreen(
      title: followers ? 'Followers' : 'Following',
      subtitle: '@$displayName',
      emptyText: followers ? 'No followers yet.' : 'Not following anyone yet.',
      fetch: (cursor) => followers
          ? FollowService.getFollowers(userId, cursor: cursor)
          : FollowService.getFollowing(userId, cursor: cursor),
    );
  }
}
