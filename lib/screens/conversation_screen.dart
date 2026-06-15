import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/event_service.dart';
import '../services/message_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'event_detail_screen.dart';
import 'messages_screen.dart' show NileAvatar;
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'viewer_screen.dart';

class ConversationScreen extends StatefulWidget {
  final Conversation conversation;
  const ConversationScreen({super.key, required this.conversation});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focusNode = FocusNode();

  List<Message> _messages = [];
  bool _loadingHistory = true;
  bool _sending = false;
  bool _hasMore = false;
  String? _cursor;
  RealtimeChannel? _channel;

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
    _subscribeTyping();
    _input.addListener(_onInputChanged);
    MessageService.markRead(_conv.id);
  }

  @override
  void dispose() {
    _typingStopTimer?.cancel();
    _otherTypingTimeout?.cancel();
    _stopTyping();
    _typingChannel?.unsubscribe();
    _channel?.unsubscribe();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
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
    _channel = MessageService.subscribeToMessages(
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
    );
  }

  void _showMessageActions(Message msg) {
    final isMine = msg.senderId == _myId;
    // Shared cards / images have a label as content; only offer Copy for
    // plain text messages.
    final canCopy = !msg.isSharedPost && !msg.isSharedEvent && !msg.isImage;
    if (!canCopy && !isMine) return;
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
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_rounded,
                    color: NileColors.txtPrimary),
                title: Text('Copy', style: NileTextStyles.bodyMd()),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.content));
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: NileColors.coral),
                title: Text('Delete',
                    style: NileTextStyles.bodyMd()
                        .copyWith(color: NileColors.coral)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDelete(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

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
              leading: const Icon(Icons.image_outlined,
                  color: NileColors.txtPrimary),
              title: Text('Photo', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined,
                  color: NileColors.txtPrimary),
              title: Text('Share a post', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickSharedContent(isEvent: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.live_tv_outlined,
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
              Expanded(
                child: _loadingHistory
                    ? const Center(
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
                              return const Padding(
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
                              isFirstInGroup: isFirstInGroup,
                              isLastInGroup: isLastInGroup,
                              showDateSeparator: showDateSeparator,
                              isLastSent: isLastSent,
                              onLongPress:
                                  msg.id.startsWith('opt_')
                                  ? null
                                  : () => _showMessageActions(msg),
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
            icon: const Icon(
              Icons.arrow_back_ios_new,
              size: 18,
              color: NileColors.txtPrimary,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          NileAvatar(
            username: conv.otherUsername,
            avatarUrl: conv.otherAvatarUrl,
            radius: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: conv.otherUserId),
                ),
              ),
              child: Text(
                '@${conv.otherUsername}',
                style: NileTextStyles.headingSm(),
                overflow: TextOverflow.ellipsis,
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
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool showDateSeparator;
  final bool isLastSent;
  final VoidCallback? onLongPress;
  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showDateSeparator,
    this.isLastSent = false,
    this.onLongPress,
  });

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
              GestureDetector(
                onLongPress: onLongPress,
                child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubble),
                child: message.isImage
                    ? _ImageBubble(imageUrl: message.imageUrl!, maxWidth: maxBubble)
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
                                ? NileColors.bgPage
                                : NileColors.txtPrimary,
                          ),
                        ),
                      ),
                ),
              ),
            ],
              );
            },
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
      decoration: const BoxDecoration(
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
  final String imageUrl;
  final double maxWidth;
  const _ImageBubble({required this.imageUrl, required this.maxWidth});

  @override
  Widget build(BuildContext context) {
    // Bounded height so tall photos don't dominate the thread; width is the
    // bubble cap passed from the parent (column-relative, not window-relative).
    final maxW = maxWidth;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _ImageViewer(imageUrl: imageUrl)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.lg),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW, maxHeight: 280),
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            cacheWidth: nileDecodeWidth(maxW),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : Container(
                    width: maxW,
                    height: 180,
                    color: NileColors.bgSurface,
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ),
                  ),
            errorBuilder: (context, error, stack) => Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s12,
                vertical: NileSpacing.s8,
              ),
              color: NileColors.bgSurface,
              child: Text('Image unavailable', style: NileTextStyles.caption()),
            ),
          ),
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
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PostDetailScreen(post: p)),
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
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => e.isLive
              ? ViewerScreen(initialEventId: e.liveKitEventId)
              : EventDetailScreen(event: e),
        ),
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
                      const Icon(
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
                  Text('@${e.hostUsername}', style: NileTextStyles.caption()),
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
            icon: const Icon(Icons.add_circle_outline_rounded,
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
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.txtTertiary,
                  ),
                ),
              )
            : const Icon(
                Icons.send_rounded,
                size: 18,
                color: NileColors.bgPage,
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
            const Padding(
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
