import 'package:flutter/material.dart';

import '../services/topic_service.dart';
import '../theme.dart';

/// Multi-select topic chips for tagging events. Loads the taxonomy itself;
/// mutates [selected] in place and calls [onChanged] on every toggle.
/// Used by the create-event flow and the edit-event screen.
class TopicChips extends StatefulWidget {
  const TopicChips({super.key, required this.selected, this.onChanged});

  final Set<String> selected; // topic ids
  final VoidCallback? onChanged;

  @override
  State<TopicChips> createState() => _TopicChipsState();
}

class _TopicChipsState extends State<TopicChips> {
  List<Topic>? _topics;
  String? _error;

  @override
  void initState() {
    super.initState();
    TopicService.listTopics()
        .then((t) {
          if (mounted) setState(() => _topics = t);
        })
        .catchError((e) {
          if (mounted) setState(() => _error = 'Couldn\'t load topics: $e');
        });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Text(
        _error!,
        style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
      );
    }
    final topics = _topics;
    if (topics == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: NileSpacing.s12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: NileColors.volt,
            ),
          ),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in topics)
          FilterChip(
            label: Text(t.name),
            selected: widget.selected.contains(t.id),
            onSelected: (on) {
              setState(
                () => on
                    ? widget.selected.add(t.id)
                    : widget.selected.remove(t.id),
              );
              widget.onChanged?.call();
            },
            showCheckmark: false,
            labelStyle: NileTextStyles.bodySm().copyWith(
              color: widget.selected.contains(t.id)
                  ? NileColors.bgPage
                  : NileColors.txtSecondary,
            ),
            backgroundColor: NileColors.bgSurface,
            selectedColor: NileColors.volt,
            side: BorderSide(
              color: widget.selected.contains(t.id)
                  ? NileColors.volt
                  : NileColors.border,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NileRadius.pill),
            ),
          ),
      ],
    );
  }
}
