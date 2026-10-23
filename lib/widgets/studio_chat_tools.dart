import 'package:flutter/material.dart';

import '../services/chat_tools_service.dart';
import '../theme.dart';

/// Add, edit, delete and reorder the account's quick messages. Returns the
/// list as it was left, or null if it never loaded.
Future<List<QuickMessage>?> showQuickMessagesEditor(BuildContext context) =>
    showDialog<List<QuickMessage>>(
      context: context,
      builder: (_) => const _QuickMessagesEditor(),
    );

class _QuickMessagesEditor extends StatefulWidget {
  const _QuickMessagesEditor();

  @override
  State<_QuickMessagesEditor> createState() => _QuickMessagesEditorState();
}

class _QuickMessagesEditorState extends State<_QuickMessagesEditor> {
  List<QuickMessage>? _items;
  final _draft = TextEditingController();
  String? _editingId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await ChatToolsService.quickMessages();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) {
        setState(() {
          _items = const [];
          _error = 'Couldn’t load your quick messages.';
        });
      }
    }
  }

  Future<void> _save() async {
    final body = _draft.text.trim();
    if (body.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      if (_editingId == null) {
        await ChatToolsService.addQuickMessage(body, sort: _items?.length ?? 0);
      } else {
        await ChatToolsService.updateQuickMessage(_editingId!, body);
      }
      _draft.clear();
      _editingId = null;
      await _load();
      _error = null;
    } catch (_) {
      _error = 'Couldn’t save that.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(QuickMessage q) async {
    setState(() => _items = [...?_items]..remove(q));
    try {
      await ChatToolsService.deleteQuickMessage(q.id);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t delete that.');
      await _load();
    }
  }

  Future<void> _reorder(int from, int to) async {
    final items = [...?_items];
    items.insert(to, items.removeAt(from));
    setState(() => _items = items);
    try {
      await ChatToolsService.reorderQuickMessages(items);
      _items = [
        for (var i = 0; i < items.length; i++)
          QuickMessage(id: items[i].id, body: items[i].body, sort: i),
      ];
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save the new order.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text('Quick messages', style: NileTextStyles.headingMd()),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Saved to your account. Pick one from ⚡ in the Studio chat, then '
              'press Enter to send.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: NileSpacing.s12),
            Expanded(
              child: items == null
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        'None yet — add a welcome, a merch link, a “back in 5”.',
                        textAlign: TextAlign.center,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: items.length,
                      onReorderItem: _reorder,
                      itemBuilder: (context, i) {
                        final q = items[i];
                        return ListTile(
                          key: ValueKey(q.id),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          selected: q.id == _editingId,
                          selectedTileColor: NileColors.volt.withValues(
                            alpha: 0.08,
                          ),
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: Icon(
                              Icons.drag_indicator,
                              color: NileColors.txtTertiary,
                            ),
                          ),
                          title: Text(
                            q.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: NileTextStyles.bodyMd(),
                          ),
                          onTap: () => setState(() {
                            _editingId = q.id;
                            _draft.text = q.body;
                          }),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: Icon(
                              Icons.delete_outline,
                              color: NileColors.txtTertiary,
                            ),
                            onPressed: () => _delete(q),
                          ),
                        );
                      },
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: NileSpacing.s8),
                child: Text(
                  _error!,
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.error,
                  ),
                ),
              ),
            const SizedBox(height: NileSpacing.s8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _draft,
                    maxLength: QuickMessage.maxLength,
                    minLines: 1,
                    maxLines: 3,
                    style: NileTextStyles.bodyMd(),
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: _editingId == null
                          ? 'New quick message'
                          : 'Edit quick message',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: NileSpacing.s8),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                  ),
                  child: Text(_editingId == null ? 'Add' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _items),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The host's own blocked words and phrases. A message containing one is
/// hidden from everyone but its sender; the host sees it greyed with "Show
/// anyway". Saved to the account, so it applies to every show.
Future<void> showBlockedWordsEditor(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _BlockedWordsEditor(),
);

class _BlockedWordsEditor extends StatefulWidget {
  const _BlockedWordsEditor();

  @override
  State<_BlockedWordsEditor> createState() => _BlockedWordsEditorState();
}

class _BlockedWordsEditorState extends State<_BlockedWordsEditor> {
  List<String>? _terms;
  final _draft = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await ChatToolsService.blockedTerms();
      if (mounted) setState(() => _terms = t);
    } catch (_) {
      if (mounted) {
        setState(() {
          _terms = const [];
          _error = 'Couldn’t load your blocked words.';
        });
      }
    }
  }

  Future<void> _add() async {
    final t = ChatToolsService.cleanTerm(_draft.text);
    if (t == null) return;
    _draft.clear();
    setState(() => _terms = {...?_terms, t}.toList()..sort());
    try {
      await ChatToolsService.addBlockedTerm(t);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t add “$t”.');
      await _load();
    }
  }

  Future<void> _remove(String t) async {
    setState(() => _terms = [...?_terms]..remove(t));
    try {
      await ChatToolsService.removeBlockedTerm(t);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t remove “$t”.');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final terms = _terms;
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text('Blocked words', style: NileTextStyles.headingMd()),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Messages with these words or phrases are hidden from everyone '
              'but the person who sent them. You’ll see them greyed out, with '
              '“Show anyway”. Whole words only, any capitalisation.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: NileSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _draft,
                    maxLength: 60,
                    style: NileTextStyles.bodyMd(),
                    onSubmitted: (_) => _add(),
                    decoration: const InputDecoration(
                      labelText: 'Add a word or phrase',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: NileSpacing.s8),
                FilledButton(
                  onPressed: _add,
                  style: FilledButton.styleFrom(
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                  ),
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: NileSpacing.s12),
            if (terms == null)
              const Center(child: CircularProgressIndicator())
            else if (terms.isEmpty)
              Text(
                'Nothing blocked yet.',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtTertiary,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: NileSpacing.s6,
                    runSpacing: NileSpacing.s6,
                    children: [
                      for (final t in terms)
                        InputChip(
                          label: Text(t),
                          onDeleted: () => _remove(t),
                          deleteButtonTooltipMessage: 'Remove',
                          backgroundColor: NileColors.bgRaised,
                          side: BorderSide(color: NileColors.border),
                          labelStyle: NileTextStyles.labelMd(),
                        ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: NileSpacing.s8),
                child: Text(
                  _error!,
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
