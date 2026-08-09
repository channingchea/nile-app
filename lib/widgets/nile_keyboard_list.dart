import 'package:flutter/material.dart';

import '../services/nile_shortcuts.dart';
import '../theme.dart';

enum NileListAction { open, like, comment }

/// Makes a scrolling list keyboard-navigable: J/K move a volt selection ring,
/// L likes, C comments, Enter opens.
///
/// Selection lives here rather than in the focus system because feed cards are
/// full of their own focusable buttons — walking the focus tree with J/K would
/// step through every like and share control on the way to the next post.
///
/// Nothing happens until the first J or K, so a bare Enter or L keeps whatever
/// meaning the focused widget already gave it.
class NileKeyboardList extends StatefulWidget {
  const NileKeyboardList({super.key, required this.child});

  final Widget child;

  static NileKeyboardListState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ListScope>()?.state;

  @override
  State<NileKeyboardList> createState() => NileKeyboardListState();
}

class NileKeyboardListState extends State<NileKeyboardList> {
  /// -1 = nothing selected, which is the state the list starts and returns to.
  final ValueNotifier<int> selection = ValueNotifier<int>(-1);

  final Map<int, NileKeyboardItemState> _items = {};

  @override
  void initState() {
    super.initState();
    NileShortcuts.activeList = this;
  }

  @override
  void dispose() {
    if (identical(NileShortcuts.activeList, this)) {
      NileShortcuts.activeList = null;
    }
    selection.dispose();
    super.dispose();
  }

  void register(int index, NileKeyboardItemState item) => _items[index] = item;

  void unregister(int index, NileKeyboardItemState item) {
    if (identical(_items[index], item)) _items.remove(index);
  }

  /// Moves the ring by [delta], skipping over indices whose widgets have been
  /// recycled out of the viewport by clamping to what's registered.
  void move(int delta) {
    if (_items.isEmpty) return;
    final indices = _items.keys.toList()..sort();
    final current = selection.value;
    if (current < 0) {
      selection.value = indices.first;
      _reveal(selection.value);
      return;
    }
    final at = indices.indexOf(current);
    final next = at < 0
        // The selected card scrolled out and was disposed: fall back to the
        // nearest registered index in the direction of travel.
        ? (delta > 0
              ? indices.firstWhere((i) => i > current, orElse: () => indices.last)
              : indices.lastWhere((i) => i < current, orElse: () => indices.first))
        : indices[(at + delta).clamp(0, indices.length - 1)];
    selection.value = next;
    _reveal(next);
  }

  void _reveal(int index) {
    final item = _items[index];
    if (item == null || !item.mounted) return;
    Scrollable.ensureVisible(
      item.context,
      // Just below the app bar rather than flush against it.
      alignment: 0.15,
      duration: NileMotion.base,
      curve: NileMotion.curve,
    );
  }

  /// Returns false when there's nothing selected or the selected card doesn't
  /// offer that action, so the keystroke falls through to whatever else wants
  /// it instead of being silently swallowed.
  /// Named `trigger`, not `activate`: [State] already has an `activate()`.
  bool trigger(NileListAction action) {
    final item = _items[selection.value];
    if (item == null || !item.mounted) return false;
    final callback = switch (action) {
      NileListAction.open => item.widget.onOpen,
      NileListAction.like => item.widget.onLike,
      NileListAction.comment => item.widget.onComment,
    };
    if (callback == null) return false;
    callback();
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      _ListScope(state: this, child: widget.child);
}

class _ListScope extends InheritedWidget {
  const _ListScope({required this.state, required super.child});

  final NileKeyboardListState state;

  @override
  bool updateShouldNotify(_ListScope old) => !identical(state, old.state);
}

/// One keyboard-selectable row. Outside a [NileKeyboardList], or on a compact
/// window, it renders [child] untouched and costs nothing.
class NileKeyboardItem extends StatefulWidget {
  const NileKeyboardItem({
    super.key,
    required this.index,
    required this.child,
    this.onOpen,
    this.onLike,
    this.onComment,
  });

  final int index;
  final Widget child;
  final VoidCallback? onOpen;
  final VoidCallback? onLike;
  final VoidCallback? onComment;

  @override
  State<NileKeyboardItem> createState() => NileKeyboardItemState();
}

class NileKeyboardItemState extends State<NileKeyboardItem> {
  NileKeyboardListState? _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Phones have no keyboard to drive this, and the ring would only add a
    // 2 px inset to every card.
    final enabled = !NileBreakpoints.of(context).isCompact;
    final list = enabled ? NileKeyboardList.maybeOf(context) : null;
    if (identical(list, _list)) return;
    _list?.unregister(widget.index, this);
    _list = list;
    _list?.register(widget.index, this);
  }

  @override
  void didUpdateWidget(NileKeyboardItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _list?.unregister(oldWidget.index, this);
      _list?.register(widget.index, this);
    }
  }

  @override
  void dispose() {
    _list?.unregister(widget.index, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null) return widget.child;
    return ValueListenableBuilder<int>(
      valueListenable: list.selection,
      builder: (_, selected, child) => AnimatedContainer(
        duration: NileMotion.fast,
        curve: NileMotion.curve,
        // The 2 px inset is always reserved so selection never shifts layout.
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NileRadius.lg + 4),
          border: Border.all(
            color: selected == widget.index
                ? NileColors.volt
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
