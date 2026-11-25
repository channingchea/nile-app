import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../router.dart';
import '../widgets/nile_command_palette.dart';
import '../widgets/nile_destinations.dart';
import '../widgets/nile_keyboard_list.dart';
import 'shell_state.dart';

/// App-wide keyboard shortcuts for the desktop build.
///
/// Deliberately a [HardwareKeyboard] handler rather than a `Shortcuts` widget:
/// the bindings have to work no matter what happens to hold focus, and the one
/// thing that must never happen — swallowing a keystroke meant for a text field
/// — is easier to guarantee with a single explicit check than by reasoning
/// about where a `Shortcuts` widget sits in the focus chain.
///
/// Bindings:
///   ⌘K / Ctrl K   command palette
///   ⌘\            collapse / expand the nav rail
///   ⌘1 – ⌘5       jump to a rail destination, in rail order
///   J / K         next / previous item in the focused list
///   L             like the selected item
///   C             comment on the selected item
///   Enter         open the selected item
///   Esc           close whatever is on top
class NileShortcuts {
  NileShortcuts._();

  static bool _installed = false;

  /// Supplied by the desktop shell, which owns the branch navigator.
  static void Function(int index)? branchSwitcher;

  /// False while a tab other than the feed is showing, so J/K can't drive a
  /// list that is mounted but not visible inside the shell's IndexedStack.
  static bool listEnabled = true;

  /// The list currently accepting J/K/L/C. Set by [NileKeyboardList].
  static NileKeyboardListState? activeList;

  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
    branchSwitcher = null;
    activeList = null;
  }

  /// True while a text field has focus. Every binding is a bare letter, so this
  /// check is what keeps typing "cool" from liking a post.
  static bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.widget is EditableText;
  }

  /// The tab shell is the bottom page of the shell navigator, so "something is
  /// pushed above it" is exactly "the feed isn't what you're looking at".
  ///
  /// The *shell* navigator, not the root one: since the desktop chrome moved
  /// above the detail routes they push here, and the root navigator holds one
  /// page forever — asking it would answer "nothing is pushed" while an event
  /// page is open, and J would scroll a feed nobody can see.
  static bool get _shellOnTop =>
      shellNavigatorKey.currentState?.canPop() == false;

  // Digits count down the rail as it is drawn, not down the branch list — ⌘2 is
  // whatever sits second in the rail, which is Schedule, not branch 2. Values
  // are rail *slots*, not branch indices, because three rail rows (Currents,
  // Notifications, My Tickets) are routes with no branch to name.
  //
  // Not const: LogicalKeyboardKey overrides ==, which const maps disallow.
  static final _tabKeys = <LogicalKeyboardKey, int>{
    for (final (slot, _) in kNileRailEntries.indexed)
      if (slot < _digits.length) _digits[slot]: slot,
  };

  static const _digits = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ];

  /// The ⌘-digit bindings as key → rail slot. Exposed so a test can assert
  /// the digits follow the rail's order rather than the branch list's, which is
  /// the kind of thing that silently inverts when a destination is added.
  @visibleForTesting
  static Map<LogicalKeyboardKey, int> get debugTabKeys =>
      Map.unmodifiable(_tabKeys);

  static bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_typing) return false;

    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;

    // ⌘ on macOS, Ctrl everywhere else — accept either rather than branching on
    // platform, since an external keyboard can be plugged into anything.
    if (keyboard.isMetaPressed || keyboard.isControlPressed) {
      if (key == LogicalKeyboardKey.keyK) return _openPalette();
      if (key == LogicalKeyboardKey.backslash) {
        // Harmless on a window too narrow for a labelled rail: the choice is
        // stored and takes effect the next time there is room for labels.
        NileShellState.toggleRail();
        return true;
      }
      final slot = _tabKeys[key];
      if (slot != null) {
        final entry = kNileRailEntries[slot];
        if (entry.isBranch) {
          if (branchSwitcher == null) return false;
          branchSwitcher!(entry.branch!);
        } else {
          // Route rows have no branch to switch to, so they go through the
          // router directly — the same push the rail itself performs.
          nileRouter.push(entry.location!);
        }
        return true;
      }
      return false;
    }
    if (keyboard.isAltPressed) return false;

    if (key == LogicalKeyboardKey.escape) return _escape();

    final list = _list;
    if (list == null) return false;

    switch (key) {
      case LogicalKeyboardKey.keyJ:
        list.move(1);
        return true;
      case LogicalKeyboardKey.keyK:
        list.move(-1);
        return true;
      case LogicalKeyboardKey.keyL:
        return list.trigger(NileListAction.like);
      case LogicalKeyboardKey.keyC:
        return list.trigger(NileListAction.comment);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return list.trigger(NileListAction.open);
    }
    return false;
  }

  static NileKeyboardListState? get _list {
    if (!listEnabled || !_shellOnTop) return null;
    final list = activeList;
    return (list != null && list.mounted) ? list : null;
  }

  static bool _openPalette() {
    final context = rootNavigatorKey.currentContext;
    if (context == null || NileCommandPalette.isOpen) return true;
    NileCommandPalette.show(context);
    return true;
  }

  /// Closes the top route. Dialogs and the palette already handle Escape
  /// themselves (they hold focus), so in practice this is "back out of a
  /// pushed screen" — the desktop equivalent of the iOS swipe.
  static bool _escape() {
    // Try the shell navigator first — that's where pushed screens live — then
    // the root, which still owns dialogs and anything opened with
    // `useRootNavigator`.
    for (final nav in [
      shellNavigatorKey.currentState,
      rootNavigatorKey.currentState,
    ]) {
      if (nav != null && nav.canPop()) {
        nav.pop();
        return true;
      }
    }
    return false;
  }

  /// Shortcuts are a desktop affordance; on a phone there is no keyboard to
  /// press them with and the handler is pure overhead.
  static bool get supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}
