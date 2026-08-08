import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/app_lifecycle.dart';
import '../services/event_service.dart';
import '../services/message_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/realtime.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/offline_banner.dart';
import '../widgets/official_badge.dart';
import 'messages_screen.dart' show NileAvatar;

class ConversationScreen extends StatefulWidget {
  final Conversation conversation;
  const ConversationScreen({super.key, required this.conversation});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

/// Quick-reaction emojis shown in the long-press bar (a `+` opens the picker).
const _kQuickReactions = ['❤️', '😂', '👍', '😮', '😢', '🔥'];

class _ConversationScreenState extends State<ConversationScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focusNode = FocusNode();

  List<Message> _messages = [];
  bool _loadingHistory = true;
  bool _sending = false;
  bool _hasMore = false;
  String? _cursor;
  ResilientChannel? _conn;
  RealtimeConnState _connState = RealtimeConnState.connecting;
  RealtimeChannel? _reactionChannel;

  // Typing indicator state.
  RealtimeChannel? _typingChannel;
  bool _otherTyping = false; // is the other participant typing?
  bool _amTyping = false; // last broadcast state for self (avoids spam)
  Timer? _typingStopTimer; // auto-clears my own typing after idle
  Timer? _otherTypingTimeout; // clears stale "other typing" if no stop arrives

  String get _myId => Supabase.instance.client.auth.currentUser?.id ?? '';
  Conversation get _conv => widget.conversation;

  /// Index of my most-recent sent message, or -1. Used to anchor the read
  /// receipt under only the last bubble I sent.
  int get _lastSentIndex => _messages.lastIndexWhere((m) => m.senderId == _myId);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _subscribeRealtime();
    _subscribeReactions();
    _subscribeTyping();
    _input.addListener(_onInputChanged);
    AppLifecycle.instance.state.addListener(_onLifecycle);
    MessageService.markRead(_conv.id);
  }

  @override
  void dispose() {
    AppLifecycle.instance.state.removeListener(_onLifecycle);
    _typingStopTimer?.cancel();
    _otherTypingTimeout?.cancel();
    _stopTyping();
    _typingChannel?.unsubscribe();
    _reactionChannel?.unsubscribe();
    _conn?.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // On resume from background, backfill any messages missed while suspended.
  void _onLifecycle() {
    if (AppLifecycle.instance.state.value == AppLifecycleState.resumed &&
        mounted) {
      _resyncMessages();
    }
  }

  void _subscribeTyping() {
    _typingChannel = MessageService.subscribeToTyping(_conv.id, (isTyping) {
      if (!mounted) return;
      _otherTypingTimeout?.cancel();
      if (isTyping) {
        // Guard against a missed "stop": clear after a few idle seconds.
        _otherTypingTimeout = Timer(
          const Duration(seconds: 5),
          () => mounted ? setState(() => _otherTyping = false) : null,
        );
      }
      if (_otherTyping != isTyping) setState(() => _otherTyping = isTyping);
      if (isTyping) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToBottom(animate: true),
        );
      }
    });
  }

  // Broadcast "typing" on edits; reset an idle timer that broadcasts "stop".
  void _onInputChanged() {
    final hasText = _input.text.trim().isNotEmpty;
    if (hasText && !_amTyping) {
      _amTyping = true;
      if (_typingChannel != null) {
        MessageService.broadcastTyping(_typingChannel!, true);
      }
    }
    _typingStopTimer?.cancel();
    if (hasText) {
      _typingStopTimer = Timer(const Duration(seconds: 2), _stopTyping);
    } else {
      _stopTyping();
    }
  }

  void _stopTyping() {
    if (!_amTyping) return;
    _amTyping = false;
    if (_typingChannel != null) {
      MessageService.broadcastTyping(_typingChannel!, false);
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final page = await MessageService.getMessages(_conv.id);
      if (!mounted) return;
      setState(() {
        // Reverse so newest is at the bottom.
        _messages = page.items.reversed.toList();
        _hasMore = page.hasMore;
        _cursor = page.nextCursor;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _cursor == null) return;
    try {
      final page = await MessageService.getMessages(_conv.id, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        // Prepend older messages.
        _messages = [...page.items.reversed, ..._messages];
        _hasMore = page.hasMore;
        _cursor = page.nextCursor;
      });
    } catch (_) {}
  }

  void _subscribeRealtime() {
    _conn = ResilientChannel(
      onResync: _resyncMessages,
      onState: (s) {
        if (mounted) setState(() => _connState = s);
      },
      build: (onStatus) => MessageService.subscribeToMessages(
        _conv.id,
        (msg) {
          if (!mounted) return;
          // Avoid duplicates from optimistic insert.
          if (_messages.any((m) => m.id == msg.id)) return;
          setState(() => _messages.add(msg));
          // Mark read if the message is from the other person.
          if (msg.senderId != _myId) {
            MessageService.markRead(_conv.id);
          }
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(animate: true),
          );
        },
        // Patch read receipts in place (preserves hydrated shared post/event).
        onUpdate: (updated) {
          if (!mounted) return;
          final i = _messages.indexWhere((m) => m.id == updated.id);
          if (i < 0 || _messages[i].readAt == updated.readAt) return;
          setState(
            () => _messages[i] = _messages[i].copyWith(readAt: updated.readAt),
          );
        },
        // Remove deleted messages (fires for either participant).
        onDelete: (id) {
          if (!mounted) return;
          final i = _messages.indexWhere((m) => m.id == id);
          if (i < 0) return;
          setState(() => _messages.removeAt(i));
        },
        onStatus: onStatus,
      ),
    );
  }

  /// Reconciles the thread after a dropped connection (channel rejoin or app
  /// resume): pulls the newest page, appends any messages we missed, patches
  /// read receipts, and re-marks the thread read. Cheap and best-effort.
  Future<void> _resyncMessages() async {
    try {
      final page = await MessageService.getMessages(_conv.id);
      if (!mounted) return;
      final known = {for (final m in _messages) m.id};
      var changed = false;
      for (final m in page.items) {
        final i = _messages.indexWhere((x) => x.id == m.id);
        if (i < 0) {
          _messages.add(m);
          changed = true;
        } else if (_messages[i].readAt != m.readAt) {
          _messages[i] = _messages[i].copyWith(readAt: m.readAt);
          changed = true;
        }
      }
      if (changed) {
        // Merge may have appended out of order — restore chronological order.
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToBottom(animate: true),
        );
      }
      if (known.length != _messages.length) MessageService.markRead(_conv.id);
    } catch (_) {}
  }

  void _subscribeReactions() {
    _reactionChannel = MessageService.subscribeToReactions(_conv.id, (
      messageId,
    ) async {
      if (!mounted) return;
      // Only reconcile messages we're showing.
      if (!_messages.any((m) => m.id == messageId)) return;
      try {
        final reactions = await MessageService.fetchReactions(messageId);
        if (!mounted) return;
        final i = _messages.indexWhere((m) => m.id == messageId);
        if (i < 0) return;
        setState(() => _messages[i] = _messages[i].copyWith(reactions: reactions));
      } catch (_) {}
    });
  }

  /// Applies [emoji] to [msg]: toggles off if it's already the user's reaction,
  /// otherwise sets/replaces it. Optimistic — the realtime echo reconciles.
  Future<void> _toggleReaction(Message msg, String emoji) async {
    final i = _messages.indexWhere((m) => m.id == msg.id);
    if (i < 0) return;
    final current = _messages[i].reactionOf(_myId);
    final isToggleOff = current == emoji;

    // Optimistic local update: drop my old reaction, add the new one (unless off).
    final next = [
      ..._messages[i].reactions.where((r) => r.userId != _myId),
      if (!isToggleOff) MessageReaction(userId: _myId, emoji: emoji),
    ];
    setState(() => _messages[i] = _messages[i].copyWith(reactions: next));
    HapticFeedback.lightImpact();

    try {
      if (isToggleOff) {
        await MessageService.removeReaction(msg.id);
      } else {
        await MessageService.setReaction(msg.id, _conv.id, emoji);
      }
    } catch (_) {
      // Reconcile from the server on failure.
      if (!mounted) return;
      try {
        final reactions = await MessageService.fetchReactions(msg.id);
        if (!mounted) return;
        final j = _messages.indexWhere((m) => m.id == msg.id);
        if (j >= 0) {
          setState(
            () => _messages[j] = _messages[j].copyWith(reactions: reactions),
          );
        }
      } catch (_) {}
    }
  }

  /// Long-press menu anchored to the pressed bubble (iMessage-style): the thread
  /// dims/blurs behind a floating copy of the message, an emoji reaction pill
  /// sits just above it, and Copy/Delete sit just below. [bubbleRect] is the
  /// bubble's global rect captured at press time.
  Future<void> _showReactionMenu(Message msg, Rect bubbleRect) async {
    final isMine = msg.senderId == _myId;
    // Shared cards / images have a label as content; only offer Copy for
    // plain text messages.
    final canCopy = !msg.isSharedPost && !msg.isSharedEvent && !msg.isImage;

    final result = await Navigator.of(context).push<_ReactionMenuResult>(
      _ReactionMenuRoute(
        bubbleRect: bubbleRect,
        isMine: isMine,
        myReaction: msg.reactionOf(_myId),
        canCopy: canCopy,
        // The floating bubble is a non-interactive snapshot of the real one.
        bubble: _MessageBubbleVisual(message: msg, isMe: isMine),
      ),
    );
    if (result == null || !mounted) return;

    switch (result.kind) {
      case _ReactionMenuKind.react:
        _toggleReaction(msg, result.emoji!);
      case _ReactionMenuKind.more:
        final emoji = await _pickEmoji();
        if (emoji != null) _toggleReaction(msg, emoji);
      case _ReactionMenuKind.copy:
        Clipboard.setData(ClipboardData(text: msg.content));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Copied to clipboard')),
          );
        }
      case _ReactionMenuKind.delete:
        _confirmDelete(msg);
    }
  }

  /// Opens a lightweight emoji grid and returns the chosen emoji (or null).
  /// A custom grid keeps the bundle lean and on-brand vs. a picker dependency.
  Future<String?> _pickEmoji() => showModalBottomSheet<String>(
    context: context,
    backgroundColor: NileColors.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
    ),
    builder: (_) => const _EmojiPickerSheet(),
  );

  Future<void> _confirmDelete(Message msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Delete message?', style: NileTextStyles.headingSm()),
        content: Text(
          'This removes the message for everyone in the conversation.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text('Cancel',
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.txtTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text('Delete',
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.coral)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // Optimistic removal; restore on failure.
    final i = _messages.indexWhere((m) => m.id == msg.id);
    if (i < 0) return;
    final removed = _messages[i];
    setState(() => _messages.removeAt(i));
    try {
      await MessageService.deleteMessage(msg.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _messages.insert(i.clamp(0, _messages.length), removed));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete message')),
      );
    }
  }

  void _scrollToBottom({bool animate = false}) {
    if (!_scroll.hasClients) return;
    if (animate) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    // Optimistic insert.
    final optimistic = Message(
      id: 'opt_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: _conv.id,
      senderId: _myId,
      content: text,
      createdAt: DateTime.now(),
    );
    setState(() {
      _messages.add(optimistic);
      _sending = true;
    });
    _typingStopTimer?.cancel();
    _stopTyping();
    _input.clear();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToBottom(animate: true),
    );

    try {
      final sent = await MessageService.sendMessage(_conv.id, text);
      if (!mounted) return;
      setState(() {
        // Replace optimistic with confirmed message.
        final i = _messages.indexWhere((m) => m.id == optimistic.id);
        if (i >= 0) _messages[i] = sent;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _messages.remove(optimistic));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to send message')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── Attachments ───────────────────────────────────────────────────────────

  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_outlined,
                  color: NileColors.txtPrimary),
              title: Text('Photo', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendImage();
              },
            ),
            ListTile(
              leading: Icon(Icons.article_outlined,
                  color: NileColors.txtPrimary),
              title: Text('Share a post', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickSharedContent(isEvent: false);
              },
            ),
            ListTile(
              leading: Icon(Icons.live_tv_outlined,
                  color: NileColors.txtPrimary),
              title: Text('Share an event', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickSharedContent(isEvent: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendImage() async {
    if (_sending) return;
    Uint8List? bytes;
    try {
      bytes = await ProfileService.pickImageBytes(
        context,
        maxWidth: 1280,
        maxHeight: 1280,
      );
    } on ImageTooLargeException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image is too large (max 5MB)')),
      );
      return;
    } catch (_) {
      return;
    }
    if (bytes == null || !mounted) return;

    setState(() => _sending = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToBottom(animate: true),
    );
    try {
      final sent = await MessageService.sendImageMessage(_conv.id, bytes);
      if (!mounted) return;
      if (!_messages.any((m) => m.id == sent.id)) {
        setState(() => _messages.add(sent));
      }
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(animate: true),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send image')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickSharedContent({required bool isEvent}) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _MyContentPicker(myId: _myId, isEvent: isEvent),
    );
    if (id == null || !mounted) return;

    setState(() => _sending = true);
    try {
      final sent = isEvent
          ? await MessageService.sendSharedEvent(_conv.id, id)
          : await MessageService.sendSharedPost(_conv.id, id);
      if (!mounted) return;
      if (!_messages.any((m) => m.id == sent.id)) {
        setState(() => _messages.add(sent));
      }
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(animate: true),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to share')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: SafeArea(
          child: Column(
            children: [
              _AppBar(conv: _conv),
              const OfflineBanner(),
              if (_connState == RealtimeConnState.reconnecting)
                const ReconnectingPill(),
              Expanded(
                child: _loadingHistory
                    ? Center(
                        child: CircularProgressIndicator(
                          color: NileColors.volt,
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n is ScrollStartNotification &&
                              _scroll.position.pixels <= 100) {
                            _loadMore();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                            horizontal: NileSpacing.s16,
                            vertical: NileSpacing.s8,
                          ),
                          itemCount: _messages.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i == 0 && _hasMore) {
                              return Padding(
                                padding: EdgeInsets.only(bottom: NileSpacing.s8),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: NileColors.txtTertiary,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final msgIndex = _hasMore ? i - 1 : i;
                            final msg = _messages[msgIndex];
                            final isMe = msg.senderId == _myId;
                            final prev = msgIndex > 0
                                ? _messages[msgIndex - 1]
                                : null;
                            final next = msgIndex < _messages.length - 1
                                ? _messages[msgIndex + 1]
                                : null;
                            // Date separator when the calendar day changes.
                            final showDateSeparator =
                                prev == null ||
                                !_sameDay(prev.createdAt, msg.createdAt);
                            // Group consecutive bubbles from the same sender
                            // within 5 minutes (a new day always breaks groups).
                            final isFirstInGroup =
                                showDateSeparator ||
                                prev.senderId != msg.senderId ||
                                msg.createdAt
                                        .difference(prev.createdAt)
                                        .inMinutes
                                        .abs() >
                                    5;
                            final isLastInGroup =
                                next == null ||
                                next.senderId != msg.senderId ||
                                !_sameDay(msg.createdAt, next.createdAt) ||
                                next.createdAt
                                        .difference(msg.createdAt)
                                        .inMinutes
                                        .abs() >
                                    5;
                            // Receipt shows only under my most-recent sent
                            // message (last in the list authored by me).
                            final isLastSent =
                                isMe && msgIndex == _lastSentIndex;
                            return _MessageBubble(
                              message: msg,
                              isMe: isMe,
                              myId: _myId,
                              isFirstInGroup: isFirstInGroup,
                              isLastInGroup: isLastInGroup,
                              showDateSeparator: showDateSeparator,
                              isLastSent: isLastSent,
                              onLongPress:
                                  msg.id.startsWith('opt_')
                                  ? null
                                  : (rect) => _showReactionMenu(msg, rect),
                              // Tapping a chip toggles that emoji (off if it's
                              // your own active reaction).
                              onReactionTap: msg.id.startsWith('opt_')
                                  ? null
                                  : (emoji) => _toggleReaction(msg, emoji),
                            );
                          },
                        ),
                      ),
              ),
              AnimatedSwitcher(
                duration: NileMotion.fast,
                child: _otherTyping
                    ? Padding(
                        key: const ValueKey('typing'),
                        padding: const EdgeInsets.fromLTRB(
                          NileSpacing.s16,
                          0,
                          NileSpacing.s16,
                          NileSpacing.s4,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _TypingBubble(),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              _InputBar(
                controller: _input,
                focusNode: _focusNode,
                onSend: _send,
                onAttach: _showAttachMenu,
                sending: _sending,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── App bar ───────────────────────────────────────────────────────────────────

class _AppBar extends StatelessWidget {
  final Conversation conv;
  const _AppBar({required this.conv});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NileColors.bgPage,
      padding: const EdgeInsets.fromLTRB(NileSpacing.s4, NileSpacing.s4, NileSpacing.s16, NileSpacing.s4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new,
              size: 18,
              color: NileColors.txtPrimary,
            ),
            onPressed: () => context.pop(),
          ),
          // Avatar and name are one tap target — both open the profile.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.push(NileRoutes.profile(conv.otherUserId)),
              child: Row(
                children: [
                  NileAvatar(
                    username: conv.otherUsername,
                    avatarUrl: conv.otherAvatarUrl,
                    radius: 18,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '@${conv.otherUsername}',
                      style: NileTextStyles.headingSm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (conv.otherIsOfficial) ...[
                    const SizedBox(width: 4),
                    const OfficialBadge(size: 15),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final String myId;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool showDateSeparator;
  final bool isLastSent;
  // Receives the pressed bubble's global rect so the menu can anchor to it.
  final void Function(Rect bubbleRect)? onLongPress;
  final void Function(String emoji)? onReactionTap;
  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.myId,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showDateSeparator,
    this.isLastSent = false,
    this.onLongPress,
    this.onReactionTap,
  });

  // Reads the pressed bubble's on-screen rect from [ctx] (the GestureDetector's
  // own context) so the long-press menu can anchor to it.
  void _handleLongPress(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    onLongPress?.call(box.localToGlobal(Offset.zero) & box.size);
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const days = [
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
    ];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final base = '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}';
    return dt.year == now.year ? base : '$base, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    // Tight spacing within a group; a normal gap between groups.
    final bottomGap = isLastInGroup ? NileSpacing.s8 : NileSpacing.s2;
    // Tail corner only on the last bubble of a group (mirrors send side).
    final tail = isLastInGroup ? NileRadius.xs : NileRadius.lg;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomGap),
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showDateSeparator)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s12),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s12,
                    vertical: NileSpacing.s4,
                  ),
                  decoration: BoxDecoration(
                    color: NileColors.bgSurface,
                    borderRadius: BorderRadius.circular(NileRadius.pill),
                  ),
                  child: Text(
                    _formatDate(message.createdAt),
                    style: NileTextStyles.caption(),
                  ),
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              // 65% of the *available column* width (not the full window — the
              // thread is wrapped in NileMaxWidth on web/desktop).
              final maxBubble = constraints.maxWidth * 0.65;
              return Row(
            mainAxisAlignment: isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Builder(
                builder: (bubbleCtx) => GestureDetector(
                onLongPress: onLongPress == null
                    ? null
                    : () => _handleLongPress(bubbleCtx),
                child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubble),
                child: message.isImage
                    ? _ImageBubble(messageId: message.id, maxWidth: maxBubble)
                    : message.isSharedPost
                    ? _SharedPostBubble(post: message.sharedPost)
                    : message.isSharedEvent
                    ? _SharedEventBubble(event: message.sharedEvent)
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NileSpacing.s12,
                          vertical: NileSpacing.s8,
                        ),
                        decoration: BoxDecoration(
                          color: isMe ? NileColors.volt : NileColors.bgSurface,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(NileRadius.lg),
                            topRight: const Radius.circular(NileRadius.lg),
                            bottomLeft: Radius.circular(
                              isMe ? NileRadius.lg : tail,
                            ),
                            bottomRight: Radius.circular(
                              isMe ? tail : NileRadius.lg,
                            ),
                          ),
                        ),
                        child: Text(
                          message.content,
                          style: NileTextStyles.bodyMd().copyWith(
                            color: isMe
                                ? NileColors.onVolt
                                : NileColors.txtPrimary,
                          ),
                        ),
                      ),
                ),
              ),
              ),
            ],
              );
            },
          ),
          // Reaction chips: distinct emojis (no counts — DMs are 1:1). The
          // user's own reaction is highlighted; tapping it toggles it off.
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: NileSpacing.s4),
              child: _ReactionChips(
                reactions: message.reactions,
                myId: myId,
                onTap: onReactionTap,
              ),
            ),
          // Time + receipt only under the last bubble of a group.
          if (isLastInGroup)
            Padding(
              padding: const EdgeInsets.only(top: NileSpacing.s2),
              child: Text(
                isLastSent
                    ? (message.id.startsWith('opt_')
                          ? 'Sending…'
                          : message.isRead
                          ? 'Read'
                          : 'Delivered')
                    : _formatTime(message.createdAt),
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Reaction chips (on the bubble) ──────────────────────────────────────────────

/// Distinct reaction emojis under a bubble (no counts — DMs are 1:1). The chip
/// matching the current user's reaction is highlighted; tapping it toggles off.
class _ReactionChips extends StatelessWidget {
  final List<MessageReaction> reactions;
  final String myId;
  final void Function(String emoji)? onTap;
  const _ReactionChips({
    required this.reactions,
    required this.myId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final mine = reactions
        .firstWhere(
          (r) => r.userId == myId,
          orElse: () => const MessageReaction(userId: '', emoji: ''),
        )
        .emoji;
    // Distinct emojis, preserving insertion order.
    final seen = <String>{};
    final distinct = <String>[];
    for (final r in reactions) {
      if (seen.add(r.emoji)) distinct.add(r.emoji);
    }
    return Wrap(
      spacing: NileSpacing.s4,
      runSpacing: NileSpacing.s4,
      children: [
        for (final emoji in distinct)
          GestureDetector(
            onTap: onTap == null ? null : () => onTap!(emoji),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s8,
                vertical: NileSpacing.s2,
              ),
              decoration: BoxDecoration(
                color: emoji == mine
                    ? NileColors.volt.withValues(alpha: 0.18)
                    : NileColors.bgSurface,
                borderRadius: BorderRadius.circular(NileRadius.pill),
                border: Border.all(
                  color: emoji == mine ? NileColors.volt : NileColors.border,
                ),
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 14)),
            ),
          ),
      ],
    );
  }
}

// ── Emoji picker sheet (the `+` full picker) ────────────────────────────────────

/// A compact, dependency-free emoji grid. Pops the chosen emoji. Covers the
/// common reaction emojis across a few rows; the quick bar handles the top six.
class _EmojiPickerSheet extends StatelessWidget {
  const _EmojiPickerSheet();

  static const _emojis = [
    '❤️', '😂', '👍', '😮', '😢', '🔥', '👎', '😍',
    '🥰', '😭', '😡', '🎉', '👏', '🙏', '💯', '😎',
    '🤔', '😅', '😬', '🤯', '🥳', '😤', '😴', '🤩',
    '😇', '🙄', '😏', '😶', '💀', '👀', '✨', '⚡',
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NileSpacing.s16,
          NileSpacing.s16,
          NileSpacing.s16,
          NileSpacing.s24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: NileSpacing.s12),
              child: Text('React', style: NileTextStyles.headingSm()),
            ),
            GridView.count(
              crossAxisCount: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: NileSpacing.s4,
              crossAxisSpacing: NileSpacing.s4,
              children: [
                for (final emoji in _emojis)
                  GestureDetector(
                    onTap: () => Navigator.pop(context, emoji),
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(emoji, style: const TextStyle(fontSize: 24)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Non-interactive bubble snapshot (floats in the long-press menu) ──────────────

/// A static copy of a message bubble's content, used as the floating element in
/// the anchored long-press menu. Fully-rounded corners (no group tail).
class _MessageBubbleVisual extends StatelessWidget {
  final Message message;
  final bool isMe;
  const _MessageBubbleVisual({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    // Wrap in a Material so unparented Text doesn't get the debug "missing
    // Material" underline (this snapshot floats in an overlay, outside the
    // thread's Material ancestor).
    return Material(
      type: MaterialType.transparency,
      child: _content(),
    );
  }

  Widget _content() {
    if (message.isImage) {
      return _ImageBubble(messageId: message.id, maxWidth: 280);
    }
    if (message.isSharedPost) return _SharedPostBubble(post: message.sharedPost);
    if (message.isSharedEvent) {
      return _SharedEventBubble(event: message.sharedEvent);
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s12,
        vertical: NileSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: isMe ? NileColors.volt : NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
      child: Text(
        message.content,
        style: NileTextStyles.bodyMd().copyWith(
          color: isMe ? NileColors.onVolt : NileColors.txtPrimary,
        ),
      ),
    );
  }
}

// ── Anchored long-press reaction menu (iMessage-style) ───────────────────────────

enum _ReactionMenuKind { react, more, copy, delete }

class _ReactionMenuResult {
  final _ReactionMenuKind kind;
  final String? emoji; // set when kind == react
  const _ReactionMenuResult(this.kind, [this.emoji]);
}

/// Transparent route that dims+blurs the thread, floats a snapshot of the
/// pressed bubble at its original position, and anchors the emoji pill above it
/// and the Copy/Delete card below. Pops a [_ReactionMenuResult] (or null on
/// dismiss). Positions are clamped so nothing runs off-screen.
class _ReactionMenuRoute extends PopupRoute<_ReactionMenuResult> {
  final Rect bubbleRect;
  final bool isMine;
  final String? myReaction;
  final bool canCopy;
  final Widget bubble;

  _ReactionMenuRoute({
    required this.bubbleRect,
    required this.isMine,
    required this.myReaction,
    required this.canCopy,
    required this.bubble,
  });

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.45);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => NileMotion.fast;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top + NileSpacing.s8;
    final safeBottom = size.height - media.padding.bottom - NileSpacing.s8;

    const pillHeight = 56.0;
    const gap = NileSpacing.s8;
    // Menu width estimate: 6 emojis + '+' at ~44px each, padded.
    const menuWidth = 320.0;
    final actionCount = (canCopy ? 1 : 0) + (isMine ? 1 : 0);
    final menuHeight = actionCount * 52.0;

    // Clamp the floating bubble vertically so the pill (above) and the actions
    // card (below) both stay on-screen.
    final minTop = safeTop + pillHeight + gap;
    final maxTop = safeBottom - menuHeight - gap - bubbleRect.height;
    final bubbleTop = bubbleRect.top.clamp(
      minTop,
      maxTop < minTop ? minTop : maxTop,
    );

    // Horizontal anchor: pill/menu align to the bubble's side, clamped to edges.
    double clampX(double left, double width) =>
        left.clamp(NileSpacing.s8, size.width - width - NileSpacing.s8);
    final pillLeft = clampX(
      isMine ? bubbleRect.right - menuWidth : bubbleRect.left,
      menuWidth,
    );

    return FadeTransition(
      opacity: animation,
      child: Stack(
        children: [
          // Blur layer behind everything (tap to dismiss).
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
          // Emoji reaction pill, just above the (possibly shifted) bubble.
          Positioned(
            left: pillLeft,
            top: bubbleTop - pillHeight - gap,
            width: menuWidth,
            child: Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: _ReactionPill(
                selected: myReaction,
                onSelect: (e) => Navigator.pop(
                  context,
                  _ReactionMenuResult(_ReactionMenuKind.react, e),
                ),
                onMore: () => Navigator.pop(
                  context,
                  const _ReactionMenuResult(_ReactionMenuKind.more),
                ),
              ),
            ),
          ),
          // Floating snapshot of the pressed bubble.
          Positioned(
            left: bubbleRect.left,
            top: bubbleTop,
            width: bubbleRect.width,
            child: IgnorePointer(child: bubble),
          ),
          // Actions card, just below the bubble.
          if (actionCount > 0)
            Positioned(
              left: clampX(
                isMine ? bubbleRect.right - 200 : bubbleRect.left,
                200,
              ),
              top: bubbleTop + bubbleRect.height + gap,
              width: 200,
              child: _ReactionActionsCard(
                canCopy: canCopy,
                isMine: isMine,
                onCopy: () => Navigator.pop(
                  context,
                  const _ReactionMenuResult(_ReactionMenuKind.copy),
                ),
                onDelete: () => Navigator.pop(
                  context,
                  const _ReactionMenuResult(_ReactionMenuKind.delete),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The rounded emoji pill: 6 quick reactions + a `+`. Highlights [selected].
class _ReactionPill extends StatelessWidget {
  final String? selected;
  final void Function(String emoji) onSelect;
  final VoidCallback onMore;
  const _ReactionPill({
    required this.selected,
    required this.onSelect,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s8,
          vertical: NileSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.pill),
          border: Border.all(color: NileColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in _kQuickReactions)
              _PillButton(
                highlighted: selected == emoji,
                onTap: () => onSelect(emoji),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            _PillButton(
              highlighted: false,
              onTap: onMore,
              child: Icon(
                Icons.add_rounded,
                color: NileColors.txtSecondary,
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final Widget child;
  final bool highlighted;
  final VoidCallback onTap;
  const _PillButton({
    required this.child,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: highlighted ? NileColors.bgRaised : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: child,
      ),
    );
  }
}

/// The small Copy/Delete card shown below the bubble in the long-press menu.
class _ReactionActionsCard extends StatelessWidget {
  final bool canCopy;
  final bool isMine;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  const _ReactionActionsCard({
    required this.canCopy,
    required this.isMine,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canCopy)
            _ActionRow(
              icon: Icons.copy_rounded,
              label: 'Copy',
              color: NileColors.txtPrimary,
              onTap: onCopy,
            ),
          if (canCopy && isMine)
            Divider(height: 1, color: NileColors.border),
          if (isMine)
            _ActionRow(
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              color: NileColors.coral,
              onTap: onDelete,
            ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s16,
          vertical: NileSpacing.s12,
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: NileSpacing.s12),
            Text(label, style: NileTextStyles.bodyMd().copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

// ── Typing indicator bubble ────────────────────────────────────────────────────

class _TypingBubble extends StatefulWidget {
  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s12,
        vertical: NileSpacing.s8 + 2,
      ),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(NileRadius.lg),
          topRight: Radius.circular(NileRadius.lg),
          bottomLeft: Radius.circular(NileRadius.xs),
          bottomRight: Radius.circular(NileRadius.lg),
        ),
      ),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Stagger each dot's bounce by a third of the cycle.
            final t = (_ctrl.value - i * 0.2) % 1.0;
            final lift = (t < 0.5) ? (0.5 - (0.5 - t).abs()) * 2 : 0.0;
            return Padding(
              padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
              child: Transform.translate(
                offset: Offset(0, -3 * lift),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: NileColors.txtTertiary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Image attachment bubble ─────────────────────────────────────────────────

class _ImageBubble extends StatelessWidget {
  final String messageId;
  final double maxWidth;
  const _ImageBubble({required this.messageId, required this.maxWidth});

  @override
  Widget build(BuildContext context) {
    // Bounded height so tall photos don't dominate the thread; width is the
    // bubble cap passed from the parent (column-relative, not window-relative).
    // The messages bucket is private: the image renders from a short-lived
    // signed URL resolved (and cached) by MessageService.
    final maxW = maxWidth;
    Widget placeholder({bool error = false}) => Container(
      width: maxW,
      height: 180,
      color: NileColors.bgSurface,
      child: error
          ? Center(
              child: Text('Image unavailable', style: NileTextStyles.caption()),
            )
          : Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: NileColors.txtTertiary,
                ),
              ),
            ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: 280),
        child: FutureBuilder<String>(
          future: MessageService.getSignedImageUrl(messageId),
          builder: (context, snap) {
            if (snap.hasError) return placeholder(error: true);
            final url = snap.data;
            if (url == null) return placeholder();
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => _ImageViewer(imageUrl: url)),
              ),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                cacheWidth: nileDecodeWidth(maxW),
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : placeholder(),
                errorBuilder: (context, error, stack) =>
                    placeholder(error: true),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Full-screen, pinch-to-zoom image viewer for an attachment.
class _ImageViewer extends StatelessWidget {
  final String imageUrl;
  const _ImageViewer({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image.network(imageUrl, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

// ── Shared post card (rich DM attachment) ──────────────────────────────────────

class _SharedPostBubble extends StatelessWidget {
  final Post? post;
  const _SharedPostBubble({required this.post});

  @override
  Widget build(BuildContext context) {
    final p = post;
    if (p == null) {
      // Original post deleted or not yet hydrated.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
        ),
        child: Text('Post unavailable', style: NileTextStyles.caption()),
      );
    }
    return GestureDetector(
      onTap: () => context.push(NileRoutes.post(p.id), extra: p),
      child: Container(
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
          border: Border.all(color: NileColors.bgRaised),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p.hasImage)
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.network(p.imageUrl!, fit: BoxFit.cover, cacheWidth: nileDecodeWidth(600)),
              ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      NileAvatar(
                        username: p.authorUsername,
                        avatarUrl: p.authorAvatarUrl,
                        radius: 10,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '@${p.authorUsername}',
                          style: NileTextStyles.caption(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (p.authorIsOfficial) ...[
                        const SizedBox(width: 4),
                        const OfficialBadge(size: 11),
                      ],
                    ],
                  ),
                  if (p.hasCaption) ...[
                    const SizedBox(height: 6),
                    Text(
                      p.content!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.bodyMd(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared event card (rich DM attachment) ─────────────────────────────────────

class _SharedEventBubble extends StatelessWidget {
  final Event? event;
  const _SharedEventBubble({required this.event});

  @override
  Widget build(BuildContext context) {
    final e = event;
    if (e == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s8),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
        ),
        child: Text('Event unavailable', style: NileTextStyles.caption()),
      );
    }
    return GestureDetector(
      onTap: () => context.push(
        NileRoutes.eventOrWatch(
          isLive: e.isLive,
          eventId: e.id,
          liveKitEventId: e.liveKitEventId,
        ),
        extra: e,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
          border: Border.all(color: NileColors.bgRaised),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e.coverImageUrl != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(e.coverImageUrl!, fit: BoxFit.cover, cacheWidth: nileDecodeWidth(600)),
              ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.live_tv,
                        size: 13,
                        color: NileColors.volt,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          e.isLive ? 'LIVE now' : 'Event',
                          style: NileTextStyles.caption(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.bodyMd(),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '@${e.hostUsername}',
                          style: NileTextStyles.caption(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (e.hostIsOfficial) ...[
                        const SizedBox(width: 4),
                        const OfficialBadge(size: 11),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final bool sending;
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.sending,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NileColors.bgSurface,
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.add_circle_outline_rounded,
                color: NileColors.txtSecondary),
            onPressed: sending ? null : onAttach,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: 4,
              minLines: 1,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              style: NileTextStyles.bodyMd(),
              decoration: InputDecoration(
                hintText: 'Message…',
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s12,
                  vertical: NileSpacing.s8,
                ),
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                fillColor: NileColors.bgRaised,
                filled: true,
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(onSend: onSend, sending: sending),
        ],
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  final VoidCallback onSend;
  final bool sending;
  const _SendButton({required this.onSend, required this.sending});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.sending ? null : widget.onSend,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: widget.sending ? NileColors.bgRaised : NileColors.volt,
          shape: BoxShape.circle,
        ),
        child: widget.sending
            ? Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.txtTertiary,
                  ),
                ),
              )
            : Icon(
                Icons.send_rounded,
                size: 18,
                color: NileColors.onVolt,
              ),
      ),
    );
  }
}

// ── My-content picker (share a post / event into the DM) ────────────────────────

/// Bottom sheet listing the current user's own posts or events; pops the
/// selected item's id (or null on dismiss).
class _MyContentPicker extends StatefulWidget {
  final String myId;
  final bool isEvent;
  const _MyContentPicker({required this.myId, required this.isEvent});

  @override
  State<_MyContentPicker> createState() => _MyContentPickerState();
}

class _MyContentPickerState extends State<_MyContentPicker> {
  List<Post>? _posts;
  List<Event>? _events;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.isEvent) {
        final page = await EventService.getEventsByHost(widget.myId);
        if (mounted) setState(() => _events = page.items);
      } else {
        final page = await PostService.getByAuthor(widget.myId);
        if (mounted) setState(() => _posts = page.items);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _events = widget.isEvent ? [] : null;
          _posts = widget.isEvent ? null : [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = widget.isEvent ? _events != null : _posts != null;
    final isEmpty = widget.isEvent
        ? (_events?.isEmpty ?? false)
        : (_posts?.isEmpty ?? false);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s8,
            ),
            child: Text(
              widget.isEvent ? 'Share an event' : 'Share a post',
              style: NileTextStyles.headingSm(),
            ),
          ),
          if (!loaded)
            Padding(
              padding: EdgeInsets.all(NileSpacing.s24),
              child: Center(
                child: CircularProgressIndicator(color: NileColors.volt),
              ),
            )
          else if (isEmpty)
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s24),
              child: Text(
                widget.isEvent ? 'You have no events yet' : 'You have no posts yet',
                style: NileTextStyles.caption(),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: widget.isEvent
                    ? _events!
                        .map((e) => ListTile(
                              leading: _thumb(e.coverImageUrl, Icons.live_tv),
                              title: Text(
                                e.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NileTextStyles.bodyMd(),
                              ),
                              onTap: () => Navigator.pop(context, e.id),
                            ))
                        .toList()
                    : _posts!
                        .map((p) => ListTile(
                              leading: _thumb(p.imageUrl, Icons.article_outlined),
                              title: Text(
                                (p.content == null || p.content!.isEmpty)
                                    ? 'Photo post'
                                    : p.content!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NileTextStyles.bodyMd(),
                              ),
                              onTap: () => Navigator.pop(context, p.id),
                            ))
                        .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _thumb(String? url, IconData fallback) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.xs),
      child: SizedBox(
        width: 44,
        height: 44,
        child: url != null && url.isNotEmpty
            ? Image.network(url, fit: BoxFit.cover, cacheWidth: nileDecodeWidth(88))
            : Container(
                color: NileColors.bgRaised,
                child: Icon(fallback, size: 18, color: NileColors.txtTertiary),
              ),
      ),
    );
  }
}
