import 'package:flutter/material.dart';
import '../services/like_service.dart';
import 'user_list_screen.dart';

/// Users who liked a post or an event, newest first. Public — anyone can open
/// it from the like count on a post/event.
class LikeListScreen extends StatelessWidget {
  final String? postId;
  final String? eventId;

  const LikeListScreen.post(this.postId, {super.key}) : eventId = null;
  const LikeListScreen.event(this.eventId, {super.key}) : postId = null;

  /// Push the list of users who liked [postId].
  static void openPost(BuildContext context, String postId) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => LikeListScreen.post(postId)),
  );

  /// Push the list of users who liked [eventId].
  static void openEvent(BuildContext context, String eventId) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => LikeListScreen.event(eventId)),
  );

  @override
  Widget build(BuildContext context) {
    return UserListScreen(
      title: 'Likes',
      emptyText: 'No likes yet.',
      emptyIcon: Icons.favorite_border,
      fetch: (cursor) => postId != null
          ? LikeService.getPostLikers(postId!, cursor: cursor)
          : LikeService.getEventLikers(eventId!, cursor: cursor),
    );
  }
}
