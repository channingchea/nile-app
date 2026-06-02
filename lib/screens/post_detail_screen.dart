import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/comment_service.dart';
import '../services/like_service.dart';
import '../services/post_service.dart';
import '../services/report_service.dart';
import '../theme.dart';
import 'profile_screen.dart';
import 'widgets/load_more_footer.dart';
import 'widgets/moderation_menu.dart';

class PostDetailScreen extends StatefulWidget {
  final Post post;
  const PostDetailScreen({super.key, required this.post});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  late Post _post;
  List<Comment>? _comments;
  String? _commentsError;

  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();
  final _scroll = ScrollController();
  bool _submitting = false;
  bool _liking = false;

  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
    _scroll.addListener(_onScroll);
    _hydrate();
    _loadComments();
  }

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore && _comments != null) _loadMoreComments();
  }

  Future<void> _hydrate() async {
    // Re-fetch the post for fresh counts, plus liked-by-me state.
    try {
      final fresh = await PostService.fetchById(_post.id);
      if (fresh == null || !mounted) return;
      final liked =
          await LikeService.getLikedPostIds([_post.id]);
      if (!mounted) return;
      setState(() => _post = fresh.copyWith(likedByMe: liked.contains(_post.id)));
    } catch (_) {
      // Non-fatal — keep the post we were given.
    }
  }

  Future<void> _loadComments() async {
    setState(() {
      _comments = null;
      _commentsError = null;
    });
    try {
      final page = await CommentService.listForPost(_post.id);
      if (!mounted) return;
      setState(() {
        _comments = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _commentsError = e.toString());
    }
  }

  Future<void> _loadMoreComments() async {
    if (_cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await CommentService.listForPost(_post.id, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _comments = [...?_comments, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_liking) return;
    setState(() => _liking = true);

    final wasLiked = _post.likedByMe;
    final delta = wasLiked ? -1 : 1;
    setState(() => _post = _post.copyWith(
          likedByMe: !wasLiked,
          likeCount: (_post.likeCount + delta).clamp(0, 1 << 30),
        ));

    try {
      if (wasLiked) {
        await LikeService.unlikePost(_post.id);
      } else {
        await LikeService.likePost(_post.id);
      }
    } catch (_) {
      // Revert.
      if (!mounted) return;
      setState(() => _post = _post.copyWith(
            likedByMe: wasLiked,
            likeCount: (_post.likeCount - delta).clamp(0, 1 << 30),
          ));
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _submitting) return;
    setState(() => _submitting = true);

    try {
      final c = await CommentService.create(postId: _post.id, body: text);
      if (!mounted) return;
      setState(() {
        _comments = [c, ...(_comments ?? [])];
        _post = _post.copyWith(commentCount: _post.commentCount + 1);
        _commentController.clear();
      });
      _commentFocus.unfocus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t post: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _deleteComment(Comment c) async {
    setState(() {
      _comments = _comments?.where((x) => x.id != c.id).toList();
      _post = _post.copyWith(
          commentCount: (_post.commentCount - 1).clamp(0, 1 << 30));
    });
    try {
      await CommentService.delete(c.id);
    } catch (e) {
      // Restore on failure.
      if (!mounted) return;
      setState(() {
        _comments = [c, ...(_comments ?? [])];
        _post = _post.copyWith(commentCount: _post.commentCount + 1);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t delete: $e')),
      );
    }
  }

  bool get _isMyPost {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    return myId != null && myId == _post.authorId;
  }

  String? _myId() => Supabase.instance.client.auth.currentUser?.id;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: SafeArea(
        child: NileMaxWidth(
          child: Column(
            children: [
              AppBar(
                backgroundColor: Colors.transparent,
                title: Text('Post', style: NileTextStyles.headingMd()),
                actions: [
                  if (!_isMyPost)
                    IconButton(
                      icon: const Icon(Icons.flag_outlined),
                      tooltip: 'Report post',
                      onPressed: () => Moderation.showReportSheet(
                        context,
                        targetType: ReportTargetType.post,
                        targetId: _post.id,
                      ),
                    ),
                ],
              ),
              Expanded(
                child: RefreshIndicator(
                  color: NileColors.volt,
                  onRefresh: () async {
                    await _hydrate();
                    await _loadComments();
                  },
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _PostBody(post: _post),
                      const SizedBox(height: 12),
                      _ActionsRow(
                        post: _post,
                        busy: _liking,
                        onLike: _toggleLike,
                        onComment: () => _commentFocus.requestFocus(),
                      ),
                      const Divider(color: NileColors.border, height: 32),
                      Text('Comments', style: NileTextStyles.labelSm()),
                      const SizedBox(height: 8),
                      if (_commentsError != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Couldn\'t load comments: $_commentsError',
                            style: NileTextStyles.bodySm()
                                .copyWith(color: NileColors.error),
                          ),
                        )
                      else if (_comments == null)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: CircularProgressIndicator(
                                color: NileColors.volt),
                          ),
                        )
                      else if (_comments!.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Text('Be the first to comment.',
                                style: NileTextStyles.bodySm()),
                          ),
                        )
                      else ...[
                        ..._comments!.map((c) => _CommentTile(
                              comment: c,
                              canDelete: c.authorId == _myId() || _isMyPost,
                              isMine: c.authorId == _myId(),
                              onDelete: () => _deleteComment(c),
                            )),
                        if (_hasMore) const LoadMoreFooter(),
                      ],
                    ],
                  ),
                ),
              ),
              _CommentInput(
                controller: _commentController,
                focusNode: _commentFocus,
                submitting: _submitting,
                onSubmit: _submitComment,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Post body ────────────────────────────────────────────────────────────────

class _PostBody extends StatelessWidget {
  final Post post;
  const _PostBody({required this.post});

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    if (d.inMinutes > 0) return '${d.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: post.authorId),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: NileColors.bgRaised,
                    backgroundImage: post.authorAvatarUrl != null
                        ? NetworkImage(post.authorAvatarUrl!)
                        : null,
                    child: post.authorAvatarUrl == null
                        ? Text(post.authorUsername[0].toUpperCase(),
                            style: NileTextStyles.labelSm().copyWith(
                                color: NileColors.txtPrimary,
                                letterSpacing: 0))
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('@${post.authorUsername}',
                        style: NileTextStyles.bodySm(),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text(_timeAgo(post.createdAt),
                      style: NileTextStyles.caption()),
                ],
              ),
            ),
            if (post.hasCaption) ...[
              const SizedBox(height: 10),
              Text(post.caption!.trim(), style: NileTextStyles.bodyMd()),
            ],
            if (post.hasImage) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(NileRadius.sm),
                child: Image.network(
                  post.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    color: NileColors.bgRaised,
                    child: const Center(
                      child: Icon(Icons.broken_image,
                          color: NileColors.border),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Actions row ──────────────────────────────────────────────────────────────

class _ActionsRow extends StatelessWidget {
  final Post post;
  final bool busy;
  final VoidCallback onLike;
  final VoidCallback onComment;
  const _ActionsRow({
    required this.post,
    required this.busy,
    required this.onLike,
    required this.onComment,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _IconCount(
          icon: post.likedByMe ? Icons.favorite : Icons.favorite_border,
          color: post.likedByMe ? NileColors.coral : NileColors.txtSecondary,
          count: post.likeCount,
          onTap: busy ? null : onLike,
        ),
        const SizedBox(width: 20),
        _IconCount(
          icon: Icons.mode_comment_outlined,
          color: NileColors.txtSecondary,
          count: post.commentCount,
          onTap: onComment,
        ),
      ],
    );
  }
}

class _IconCount extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int count;
  final VoidCallback? onTap;
  const _IconCount({
    required this.icon,
    required this.color,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 6),
            Text('$count',
                style: NileTextStyles.bodySm().copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

// ── Comment tile ─────────────────────────────────────────────────────────────

class _CommentTile extends StatelessWidget {
  final Comment comment;
  final bool canDelete;
  final bool isMine;
  final VoidCallback onDelete;
  const _CommentTile({
    required this.comment,
    required this.canDelete,
    required this.isMine,
    required this.onDelete,
  });

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return 'now';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProfileScreen(userId: comment.authorId),
              ),
            ),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: comment.authorAvatarUrl != null
                  ? NetworkImage(comment.authorAvatarUrl!)
                  : null,
              child: comment.authorAvatarUrl == null
                  ? Text(comment.authorUsername[0].toUpperCase(),
                      style: NileTextStyles.labelSm()
                          .copyWith(letterSpacing: 0))
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('@${comment.authorUsername}',
                        style: NileTextStyles.labelSm()
                            .copyWith(letterSpacing: 0)),
                    const SizedBox(width: 6),
                    Text(_timeAgo(comment.createdAt),
                        style: NileTextStyles.caption()),
                    const Spacer(),
                    if (canDelete || !isMine)
                      _CommentMenu(
                        canDelete: canDelete,
                        canReport: !isMine,
                        onDelete: onDelete,
                        onReport: () => Moderation.showReportSheet(
                          context,
                          targetType: ReportTargetType.comment,
                          targetId: comment.id,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.body, style: NileTextStyles.bodyMd()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentMenu extends StatelessWidget {
  final bool canDelete;
  final bool canReport;
  final VoidCallback onDelete;
  final VoidCallback onReport;
  const _CommentMenu({
    required this.canDelete,
    required this.canReport,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz,
          size: 16, color: NileColors.txtTertiary),
      color: NileColors.bgRaised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm)),
      onSelected: (v) {
        if (v == 'delete') onDelete();
        if (v == 'report') onReport();
      },
      itemBuilder: (_) => [
        if (canReport)
          const PopupMenuItem(value: 'report', child: Text('Report')),
        if (canDelete)
          PopupMenuItem(
            value: 'delete',
            child:
                Text('Delete', style: TextStyle(color: NileColors.error)),
          ),
      ],
    );
  }
}

// ── Comment input ────────────────────────────────────────────────────────────

class _CommentInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool submitting;
  final VoidCallback onSubmit;
  const _CommentInput({
    required this.controller,
    required this.focusNode,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: const BoxDecoration(
          color: NileColors.bgSurface,
          border: Border(top: BorderSide(color: NileColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                style: NileTextStyles.bodyMd(),
                decoration: const InputDecoration(
                  hintText: 'Add a comment…',
                  isDense: true,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  counterText: '',
                ),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            IconButton(
              onPressed: submitting ? null : onSubmit,
              icon: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: NileColors.volt),
                    )
                  : const Icon(Icons.send, color: NileColors.volt),
              tooltip: 'Post comment',
            ),
          ],
        ),
      ),
    );
  }
}
