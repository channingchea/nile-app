import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/message_service.dart';
import '../theme.dart';
import 'messages_screen.dart' show NileAvatar;
import 'profile_screen.dart';

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

  String get _myId => Supabase.instance.client.auth.currentUser?.id ?? '';
  Conversation get _conv => widget.conversation;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _subscribeRealtime();
    MessageService.markRead(_conv.id);
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
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
      final page =
          await MessageService.getMessages(_conv.id, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        // Prepend older messages.
        _messages = [...page.items.reversed.toList(), ..._messages];
        _hasMore = page.hasMore;
        _cursor = page.nextCursor;
      });
    } catch (_) {}
  }

  void _subscribeRealtime() {
    _channel = MessageService.subscribeToMessages(_conv.id, (msg) {
      if (!mounted) return;
      // Avoid duplicates from optimistic insert.
      if (_messages.any((m) => m.id == msg.id)) return;
      setState(() => _messages.add(msg));
      // Mark read if the message is from the other person.
      if (msg.senderId != _myId) {
        MessageService.markRead(_conv.id);
      }
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToBottom(animate: true));
    });
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
    _input.clear();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom(animate: true));

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send message')),
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
                        child: CircularProgressIndicator(color: NileColors.volt))
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
                              horizontal: 16, vertical: 8),
                          itemCount: _messages.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i == 0 && _hasMore) {
                              return const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: NileColors.txtTertiary),
                                  ),
                                ),
                              );
                            }
                            final msgIndex = _hasMore ? i - 1 : i;
                            final msg = _messages[msgIndex];
                            final isMe = msg.senderId == _myId;
                            final showTimestamp = msgIndex == 0 ||
                                msg.createdAt
                                        .difference(
                                            _messages[msgIndex - 1].createdAt)
                                        .inMinutes
                                        .abs() >
                                    10;
                            return _MessageBubble(
                              message: msg,
                              isMe: isMe,
                              showTimestamp: showTimestamp,
                            );
                          },
                        ),
                      ),
              ),
              _InputBar(
                controller: _input,
                focusNode: _focusNode,
                onSend: _send,
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
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 18, color: NileColors.txtPrimary),
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
  final bool showTimestamp;
  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.showTimestamp,
  });

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showTimestamp)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  _formatTime(message.createdAt),
                  style: NileTextStyles.caption(),
                ),
              ),
            ),
          Row(
            mainAxisAlignment:
                isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.65,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMe ? NileColors.volt : NileColors.bgSurface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(NileRadius.lg),
                      topRight: const Radius.circular(NileRadius.lg),
                      bottomLeft: Radius.circular(
                          isMe ? NileRadius.lg : NileRadius.xs),
                      bottomRight: Radius.circular(
                          isMe ? NileRadius.xs : NileRadius.lg),
                    ),
                  ),
                  child: Text(
                    message.content,
                    style: NileTextStyles.bodyMd().copyWith(
                      color: isMe ? NileColors.bgPage : NileColors.txtPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool sending;
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
          color: widget.sending
              ? NileColors.bgRaised
              : NileColors.volt,
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
