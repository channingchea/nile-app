import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../services/message_service.dart';
import '../theme.dart';
import '../screens/messages_screen.dart' show NileAvatar;

/// Bottom sheet to share a post or event: pick a conversation to DM it to (rich
/// card), or fall back to the OS share sheet (canonical https link from
/// [ShareUrls], passed in as [shareText]).
/// Exactly one of [postId] / [eventId] is set.
class ShareToSheet extends StatefulWidget {
  final String? postId;
  final String? eventId;
  final String shareText;
  const ShareToSheet({
    super.key,
    this.postId,
    this.eventId,
    required this.shareText,
  }) : assert(postId != null || eventId != null,
            'ShareToSheet needs a postId or eventId');

  /// Open for a post.
  static Future<void> show(
    BuildContext context, {
    required String postId,
    required String shareText,
  }) =>
      _open(context, ShareToSheet(postId: postId, shareText: shareText));

  /// Open for an event.
  static Future<void> showEvent(
    BuildContext context, {
    required String eventId,
    required String shareText,
  }) =>
      _open(context, ShareToSheet(eventId: eventId, shareText: shareText));

  static Future<void> _open(BuildContext context, ShareToSheet sheet) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => sheet,
    );
  }

  @override
  State<ShareToSheet> createState() => _ShareToSheetState();
}

class _ShareToSheetState extends State<ShareToSheet> {
  List<Conversation>? _conversations;
  String? _sendingTo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final convs = await MessageService.getConversations();
      if (mounted) setState(() => _conversations = convs);
    } catch (_) {
      if (mounted) setState(() => _conversations = []);
    }
  }

  Future<void> _shareToConversation(Conversation conv) async {
    if (_sendingTo != null) return;
    setState(() => _sendingTo = conv.id);
    try {
      if (widget.eventId != null) {
        await MessageService.sendSharedEvent(conv.id, widget.eventId!);
      } else {
        await MessageService.sendSharedPost(conv.id, widget.postId!);
      }
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent to @${conv.otherUsername}')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _sendingTo = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to share')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final convs = _conversations;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Share to', style: NileTextStyles.headingSm()),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share, color: NileColors.txtPrimary),
              title: Text('Share via…', style: NileTextStyles.bodyMd()),
              onTap: () {
                Navigator.pop(context);
                Share.share(widget.shareText);
              },
            ),
            const Divider(height: 1, color: NileColors.bgRaised),
            if (convs == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child:
                        CircularProgressIndicator(color: NileColors.volt)),
              )
            else if (convs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No conversations yet',
                    style: NileTextStyles.caption()),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: convs.length,
                  itemBuilder: (_, i) {
                    final c = convs[i];
                    return ListTile(
                      leading: NileAvatar(
                        username: c.otherUsername,
                        avatarUrl: c.otherAvatarUrl,
                        radius: 18,
                      ),
                      title: Text('@${c.otherUsername}',
                          style: NileTextStyles.bodyMd()),
                      trailing: _sendingTo == c.id
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: NileColors.volt))
                          : null,
                      onTap: () => _shareToConversation(c),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
