import 'package:flutter/material.dart';

import '../services/graphics_service.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'nile_graphics_layer.dart';

IconData graphicIcon(GraphicKind k) => switch (k) {
  GraphicKind.lowerThird => Icons.subtitles_outlined,
  GraphicKind.logo => Icons.branding_watermark_outlined,
  GraphicKind.banner => Icons.view_day_outlined,
  GraphicKind.slate => Icons.fullscreen,
};

// ── Push panel ───────────────────────────────────────────────────────────────

/// The Studio toolbar's Graphics panel: every preset and library item with an
/// on/off switch for the current target (one camera, or all of them), plus
/// Clear all and a way into the library editor.
///
/// [push] sends a whole new [GraphicsState] (the `set-graphics` action in the
/// real Studio, a local setState in Studio Preview) and returns whether it
/// stuck; the switches follow what was actually accepted.
Future<void> showGraphicsPushPanel(
  BuildContext context, {
  required GraphicsState current,
  required String? targetSlotId,
  required String targetLabel,
  required Future<bool> Function(GraphicsState next) push,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
      child: _PushPanel(
        initial: current,
        slotId: targetSlotId,
        targetLabel: targetLabel,
        push: push,
      ),
    ),
  ),
);

class _PushPanel extends StatefulWidget {
  const _PushPanel({
    required this.initial,
    required this.slotId,
    required this.targetLabel,
    required this.push,
  });

  final GraphicsState initial;
  final String? slotId;
  final String targetLabel;
  final Future<bool> Function(GraphicsState next) push;

  @override
  State<_PushPanel> createState() => _PushPanelState();
}

class _PushPanelState extends State<_PushPanel> {
  late GraphicsState _state = widget.initial;
  List<StudioGraphic>? _library;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    try {
      final items = await GraphicsService.list();
      if (mounted) setState(() => _library = items);
    } catch (_) {
      if (mounted) {
        setState(() {
          _library = const [];
          _error = 'Couldn’t load your library — presets still work.';
        });
      }
    }
  }

  Future<void> _apply(GraphicsState next) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.push(next);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _state = next;
        _error = null;
      } else {
        _error = 'Couldn’t update the show’s graphics. Try again.';
      }
    });
  }

  void _toggle(StudioGraphic g, bool on) {
    _apply(
      on
          ? _state.withOn(
              widget.slotId,
              LiveGraphic.snapshot(
                g,
                publicUrl: GraphicsService.publicUrl,
                now: DateTime.now(),
              ),
            )
          : _state.withOff(widget.slotId, g.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = _library;
    final onAir = _state.targetList(widget.slotId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s24,
            NileSpacing.s12,
            NileSpacing.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('Graphics', style: NileTextStyles.headingMd()),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                color: NileColors.txtSecondary,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
          child: Text(
            'On ${widget.targetLabel}. Viewers see graphics on the angle '
            'they’re watching.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s24,
              NileSpacing.s8,
              NileSpacing.s24,
              0,
            ),
            child: Text(
              _error!,
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        const SizedBox(height: NileSpacing.s8),
        Expanded(
          child: ListView(
            children: [
              _header('NILE PRESETS'),
              for (final g in StudioGraphicPresets.all) _row(g),
              _header('YOUR LIBRARY'),
              if (lib == null)
                const Padding(
                  padding: EdgeInsets.all(NileSpacing.s16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (lib.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s24,
                    vertical: NileSpacing.s8,
                  ),
                  child: Text(
                    'Nothing saved yet. Add lower thirds, logos, banners and '
                    'slates in the library.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                )
              else
                for (final g in lib) _row(g),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  await showGraphicsLibrary(context);
                  _loadLibrary();
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit library'),
              ),
              const Spacer(),
              TextButton(
                onPressed: onAir.isEmpty || _busy
                    ? null
                    : () => _apply(_state.cleared(widget.slotId)),
                child: Text(
                  'Clear all',
                  style: NileTextStyles.labelMd().copyWith(
                    color: onAir.isEmpty
                        ? NileColors.txtTertiary
                        : NileColors.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s24,
      NileSpacing.s16,
      NileSpacing.s24,
      NileSpacing.s4,
    ),
    child: Text(
      text,
      style: NileTextStyles.labelSm().copyWith(
        color: NileColors.txtTertiary,
        letterSpacing: 1.5,
      ),
    ),
  );

  Widget _row(StudioGraphic g) {
    final on = _state.isOn(widget.slotId, g.id);
    return SwitchListTile(
      value: on,
      onChanged: _busy ? null : (v) => _toggle(g, v),
      secondary: Icon(graphicIcon(g.kind), color: NileColors.txtSecondary),
      title: Text(g.name, style: NileTextStyles.bodyMd()),
      subtitle: Text(
        g.kind.label,
        style: NileTextStyles.bodySm().copyWith(color: NileColors.txtTertiary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
      activeThumbColor: NileColors.volt,
    );
  }
}

// ── Library editor ───────────────────────────────────────────────────────────

/// Create, edit, reorder and delete the account's saved graphics. Reachable
/// from the Studio's Graphics panel and from Studio Preview.
Future<void> showGraphicsLibrary(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
      child: const _LibraryEditor(),
    ),
  ),
);

class _LibraryEditor extends StatefulWidget {
  const _LibraryEditor();

  @override
  State<_LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<_LibraryEditor> {
  List<StudioGraphic>? _items;
  StudioGraphic? _editing; // the item, or a draft with id '' for a new one
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await GraphicsService.list();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) {
        setState(() {
          _items = const [];
          _error = 'Couldn’t load your library.';
        });
      }
    }
  }

  void _newDraft(StudioGraphic template) => setState(
    () => _editing = StudioGraphic(
      id: '',
      kind: template.kind,
      name: template.name,
      payload: {...template.payload},
    ),
  );

  Future<void> _reorder(int from, int to) async {
    final items = [...?_items];
    items.insert(to, items.removeAt(from));
    setState(() => _items = items);
    try {
      await GraphicsService.reorder(items);
      _items = [
        for (var i = 0; i < items.length; i++) items[i].copyWith(sort: i),
      ];
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save the new order.');
    }
  }

  Future<void> _saved() async {
    setState(() => _editing = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 640;
        final list = _buildList();
        final editor = _editing == null
            ? Center(
                child: Text(
                  'Pick a graphic to edit, or add a new one.',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtTertiary,
                  ),
                ),
              )
            : _GraphicEditor(
                key: ValueKey(_editing!.id.isEmpty ? _editing : _editing!.id),
                graphic: _editing!,
                nextSort: _items?.length ?? 0,
                onSaved: _saved,
                onCancel: () => setState(() => _editing = null),
              );
        if (!wide) return _editing == null ? list : editor;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: list),
            Container(width: 1, color: NileColors.border),
            Expanded(child: editor),
          ],
        );
      },
    );
  }

  Widget _buildList() {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s24,
            NileSpacing.s8,
            NileSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('Graphics library', style: NileTextStyles.headingMd()),
              ),
              PopupMenuButton<StudioGraphic>(
                tooltip: 'New graphic',
                icon: const Icon(Icons.add),
                iconColor: NileColors.volt,
                color: NileColors.bgSurface,
                onSelected: _newDraft,
                itemBuilder: (_) => [
                  for (final t in _templates)
                    PopupMenuItem(
                      value: t,
                      child: Row(
                        children: [
                          Icon(graphicIcon(t.kind), size: 18),
                          const SizedBox(width: NileSpacing.s8),
                          Text(t.name, style: NileTextStyles.bodyMd()),
                        ],
                      ),
                    ),
                ],
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                color: NileColors.txtSecondary,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
            child: Text(
              _error!,
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        Expanded(
          child: items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(NileSpacing.s24),
                  child: Text(
                    'Nothing here yet. Use + to add a lower third, logo, '
                    'banner or slate.',
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
                    final g = items[i];
                    return ListTile(
                      key: ValueKey(g.id),
                      selected: _editing?.id == g.id,
                      selectedTileColor: NileColors.volt.withValues(alpha: 0.08),
                      leading: Icon(graphicIcon(g.kind)),
                      title: Text(
                        g.name,
                        style: NileTextStyles.bodyMd(),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        g.kind.label,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: Icon(
                          Icons.drag_handle,
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      onTap: () => setState(() => _editing = g),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static const _templates = [
    StudioGraphic(
      id: '',
      kind: GraphicKind.lowerThird,
      name: 'Lower third',
      payload: {'title': 'Name', 'subtitle': 'Title or handle'},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.logo,
      name: 'Logo / image',
      payload: {'corner': 'tr', 'size': 'm'},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.banner,
      name: 'Banner',
      payload: {'text': 'Your message here', 'scrolling': false},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.banner,
      name: 'Ticker (scrolling)',
      payload: {'text': 'Your message here', 'scrolling': true},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.slate,
      name: 'Slate',
      payload: {'title': 'Starting soon'},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.slate,
      name: 'Countdown slate',
      payload: {'title': 'Starting in', 'countdownSeconds': 300},
    ),
  ];
}

class _GraphicEditor extends StatefulWidget {
  const _GraphicEditor({
    super.key,
    required this.graphic,
    required this.nextSort,
    required this.onSaved,
    required this.onCancel,
  });

  final StudioGraphic graphic;
  final int nextSort;
  final VoidCallback onSaved;
  final VoidCallback onCancel;

  @override
  State<_GraphicEditor> createState() => _GraphicEditorState();
}

class _GraphicEditorState extends State<_GraphicEditor> {
  late final _name = TextEditingController(text: widget.graphic.name);
  late final Map<String, dynamic> _p = {...widget.graphic.payload};
  late final _title = TextEditingController(text: _p['title'] as String? ?? '');
  late final _subtitle = TextEditingController(
    text: _p['subtitle'] as String? ?? '',
  );
  late final _text = TextEditingController(text: _p['text'] as String? ?? '');
  late final _minutes = TextEditingController(
    text: _p['countdownSeconds'] == null
        ? ''
        : ((_p['countdownSeconds'] as num) / 60).toStringAsFixed(0),
  );
  bool _busy = false;
  String? _error;

  GraphicKind get _kind => widget.graphic.kind;
  bool get _isNew => widget.graphic.id.isEmpty;

  @override
  void dispose() {
    for (final c in [_name, _title, _subtitle, _text, _minutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _payload {
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    return switch (_kind) {
      GraphicKind.lowerThird => {
        'title': _title.text.trim(),
        'subtitle': ?opt(_subtitle),
      },
      GraphicKind.logo => {
        'imagePath': ?_p['imagePath'],
        'corner': _p['corner'] ?? 'tr',
        'size': _p['size'] ?? 'm',
      },
      GraphicKind.banner => {
        'text': _text.text.trim(),
        'scrolling': _p['scrolling'] == true,
      },
      GraphicKind.slate => {
        'title': _title.text.trim(),
        'subtitle': ?opt(_subtitle),
        'imagePath': ?_p['imagePath'],
        if (int.tryParse(_minutes.text.trim()) case final m? when m > 0)
          'countdownSeconds': m * 60,
      },
    };
  }

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await GraphicsService.pickAndUploadImage();
      if (path != null) setState(() => _p['imagePath'] = path);
    } catch (e) {
      setState(() => _error = e is ArgumentError ? '${e.message}' : 'Upload failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final payload = _payload;
    final name = _name.text.trim();
    final error = name.isEmpty
        ? 'Give it a name.'
        : StudioGraphic.validate(_kind, payload);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_isNew) {
        await GraphicsService.create(
          kind: _kind,
          name: name,
          payload: payload,
          sort: widget.nextSort,
        );
      } else {
        await GraphicsService.update(
          widget.graphic.copyWith(name: name, payload: payload),
        );
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t save. ${e is ArgumentError ? e.message : ''}';
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Delete “${widget.graphic.name}”?', style: NileTextStyles.headingMd()),
        content: Text(
          'If it’s on screen in a show right now, it stays up until you turn '
          'it off.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await GraphicsService.delete(widget.graphic);
      widget.onSaved();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t delete it.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = LiveGraphic.snapshot(
      StudioGraphic(id: 'preview', kind: _kind, name: '', payload: _payload),
      publicUrl: GraphicsService.publicUrl,
      now: DateTime.now(),
    );
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s24),
      children: [
        Row(
          children: [
            Icon(graphicIcon(_kind), color: NileColors.txtSecondary),
            const SizedBox(width: NileSpacing.s8),
            Text(_kind.label, style: NileTextStyles.headingSm()),
          ],
        ),
        const SizedBox(height: NileSpacing.s12),
        // Live preview on a stand-in 16:9 frame.
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: Container(
              color: NileColors.bgRaised,
              child: NileGraphicsLayer(graphics: [preview]),
            ),
          ),
        ),
        const SizedBox(height: NileSpacing.s16),
        _field(_name, 'Name in your library', max: 60),
        ...switch (_kind) {
          GraphicKind.lowerThird => [
            _field(_title, 'Title', max: 60),
            _field(_subtitle, 'Subtitle (optional)', max: 80),
          ],
          GraphicKind.banner => [
            _field(_text, 'Banner text', max: 140),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Scroll like a ticker', style: NileTextStyles.bodyMd()),
              value: _p['scrolling'] == true,
              activeThumbColor: NileColors.volt,
              onChanged: (v) => setState(() => _p['scrolling'] = v),
            ),
          ],
          GraphicKind.logo => [
            _imageRow(required: true),
            const SizedBox(height: NileSpacing.s12),
            DropdownButtonFormField<String>(
              initialValue: _p['corner'] as String? ?? 'tr',
              decoration: const InputDecoration(labelText: 'Corner'),
              items: [
                for (final c in logoCorners)
                  DropdownMenuItem(value: c, child: Text(logoCornerLabels[c]!)),
              ],
              onChanged: (v) => setState(() => _p['corner'] = v),
            ),
            const SizedBox(height: NileSpacing.s12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 's', label: Text('Small')),
                ButtonSegment(value: 'm', label: Text('Medium')),
                ButtonSegment(value: 'l', label: Text('Large')),
              ],
              selected: {_p['size'] as String? ?? 'm'},
              onSelectionChanged: (s) => setState(() => _p['size'] = s.first),
            ),
          ],
          GraphicKind.slate => [
            _field(_title, 'Title', max: 60),
            _field(_subtitle, 'Subtitle (optional)', max: 120),
            _field(
              _minutes,
              'Countdown minutes (optional)',
              keyboard: TextInputType.number,
            ),
            _imageRow(required: false),
          ],
        },
        if (_error != null) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            _error!,
            style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
          ),
        ],
        const SizedBox(height: NileSpacing.s24),
        Row(
          children: [
            if (!_isNew)
              TextButton(
                onPressed: _busy ? null : _delete,
                child: Text('Delete', style: TextStyle(color: NileColors.error)),
              ),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : widget.onCancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: NileSpacing.s8),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              child: Text(_isNew ? 'Add to library' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    int? max,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s12),
    child: TextField(
      controller: c,
      maxLength: max,
      keyboardType: keyboard,
      style: NileTextStyles.bodyLg(),
      decoration: InputDecoration(labelText: label, counterText: ''),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _imageRow({required bool required}) {
    final has = (_p['imagePath'] as String?)?.isNotEmpty ?? false;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.upload_outlined),
          label: Text(has ? 'Replace image' : 'Upload image'),
        ),
        const SizedBox(width: NileSpacing.s12),
        Expanded(
          child: Text(
            has
                ? 'Image uploaded'
                : required
                ? 'PNG, JPG or WebP, up to 2 MB'
                : 'Optional background image',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
        if (has && !required)
          IconButton(
            tooltip: 'Remove image',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _p.remove('imagePath')),
          ),
      ],
    );
  }
}
