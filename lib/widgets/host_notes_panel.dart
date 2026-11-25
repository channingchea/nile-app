import 'dart:async';

import 'package:flutter/material.dart';

import '../services/interview_service.dart';
import '../theme.dart';

/// Interview mode: the host's private notes for one show (event_host_notes,
/// 0147) — questions, names, running order. Saved as you type and on close.
class HostNotesPanel extends StatefulWidget {
  const HostNotesPanel({
    super.key,
    required this.eventPk,
    this.onClose,
    this.load = InterviewService.notes,
    this.save = InterviewService.saveNotes,
  });

  /// `events.id`, not the LiveKit slug.
  final String eventPk;
  final VoidCallback? onClose;
  final Future<String> Function(String eventPk) load;
  final Future<void> Function(String eventPk, String body) save;

  static const debounce = Duration(milliseconds: 800);

  @override
  State<HostNotesPanel> createState() => _HostNotesPanelState();
}

class _HostNotesPanelState extends State<HostNotesPanel> {
  final _text = TextEditingController();
  Timer? _debounce;
  bool _loaded = false;
  String _saved = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    widget
        .load(widget.eventPk)
        .then((body) {
          if (!mounted) return;
          _saved = body;
          _text.text = body;
          setState(() => _loaded = true);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() {
              _loaded = true;
              _error = 'Couldn’t load your notes.';
            });
          }
        });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _flush();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(HostNotesPanel.debounce, _flush);
  }

  // Never before the load lands: an empty field would wipe saved notes.
  void _flush() {
    final body = _text.text;
    if (!_loaded || body == _saved) return;
    _saved = body;
    widget
        .save(widget.eventPk, body)
        .then((_) {
          if (mounted && _error != null) setState(() => _error = null);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(() => _error = 'Not saved. Check your connection.');
          }
        });
  }

  @override
  Widget build(BuildContext context) => Container(
    color: NileColors.bgSurface,
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s16,
      NileSpacing.s12,
      NileSpacing.s8,
      NileSpacing.s12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'NOTES',
                style: NileTextStyles.labelSm().copyWith(
                  color: NileColors.txtTertiary,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, size: 18),
                color: NileColors.txtSecondary,
                tooltip: 'Close notes',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        Text(
          'Only you can see these.',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
        const SizedBox(height: NileSpacing.s8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: NileSpacing.s8),
            child: TextField(
              controller: _text,
              readOnly: !_loaded,
              onChanged: _onChanged,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: NileTextStyles.bodySm(),
              decoration: InputDecoration(
                hintText: _loaded ? 'Questions, names, running order…' : '',
                filled: true,
                fillColor: NileColors.bgRaised,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s6),
            child: Text(
              _error!,
              style: NileTextStyles.caption().copyWith(color: NileColors.error),
            ),
          ),
      ],
    ),
  );
}
