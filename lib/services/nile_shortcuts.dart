import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../router.dart';
import '../widgets/nile_command_palette.dart';
import '../widgets/nile_keyboard_list.dart';

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
///   ⌘1 – ⌘4       jump to a tab
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

  /// The tab shell is the only route on the root navigator, so "something is
  /// pushed above it" is exactly "the feed isn't what you're looking at".
  static bool get _shellOnTop =>
      rootNavigatorKey.currentState?.canPop() == false;

  // Not const: LogicalKeyboardKey overrides ==, which const maps disallow.
  static final _tabKeys = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit1: 0,
    LogicalKeyboardKey.digit2: 1,
    LogicalKeyboardKey.digit3: 2,
    LogicalKeyboardKey.digit4: 3,
  };

  static bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_typing) return false;

    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;

    // ⌘ on macOS, Ctrl everywhere else — accept either rather than branching on
    // platform, since an external keyboard can be plugged into anything.
    if (keyboard.isMetaPressed || keyboard.isControlPressed) {
      if (key == LogicalKeyboardKey.keyK) return _openPalette();
      final tab = _tabKeys[key];
      if (tab != null && branchSwitcher != null) {
        branchSwitcher!(tab);
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
    final nav = rootNavigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }

  /// Shortcuts are a desktop affordance; on a phone there is no keyboard to
  /// press them with and the handler is pure overhead.
  static bool get supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}
