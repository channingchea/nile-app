import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../router.dart';
import '../services/auth_gate.dart';
import '../services/mac_host.dart';
import 'nile_destinations.dart';

/// Performs an Edit-menu action on whatever currently has focus.
///
/// The Edit items carry their real key equivalents (⌘C and friends), which
/// means AppKit claims those keystrokes at `performKeyEquivalent` and they never
/// reach the Flutter view — so declaring the menu without doing the work would
/// break copy and paste rather than merely duplicate them. This dispatches the
/// same intent, at the same context, that Flutter's own text-editing shortcuts
/// would have: [ShortcutManager] invokes actions against the primary focus, and
/// [EditableText] registers its handlers above its own [Focus].
///
/// A no-op when nothing focused can honour the intent — with focus outside a
/// text field, [Actions.maybeInvoke] finds no enabled action and returns null.
void nileInvokeTextIntent(Intent intent) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context != null) Actions.maybeInvoke(context, intent);
}

/// The Mac menu bar.
///
/// Built in Dart with [PlatformMenuBar] rather than by editing `MainMenu.xib`,
/// which is what the plan originally assumed. A xib item can only fire an
/// Objective-C selector on the responder chain, so every Nile destination would
/// have needed a hand-written bridge back into Dart; here each item is an
/// ordinary callback that calls the same router the nav rail calls. The xib
/// still supplies the menu until the first frame — Flutter replaces it — so it
/// is left alone.
///
/// Off macOS this renders [child] and nothing else, so the phone and web trees
/// are unaffected.
class NileMenuBar extends StatefulWidget {
  const NileMenuBar({super.key, required this.child});

  final Widget child;

  @override
  State<NileMenuBar> createState() => _NileMenuBarState();
}

class _NileMenuBarState extends State<NileMenuBar> {
  @override
  void initState() {
    super.initState();
    // Signing in and out adds and removes most of the menu, so the bar has to
    // rebuild with the gate rather than once at startup.
    AuthGate.instance.addListener(_onAuth);
  }

  @override
  void dispose() {
    AuthGate.instance.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (mounted) setState(() {});
  }

  /// Menu selections can arrive while the window is hidden — the app is still
  /// running, and its menu bar is live whenever it is frontmost — so anything
  /// that changes what is on screen has to bring the window back first.
  void _go(String location, {bool push = false}) {
    MacHost.showWindow();
    push ? nileRouter.push(location) : nileRouter.go(location);
  }

  void _edit(Intent intent) => nileInvokeTextIntent(intent);

  /// The rail's own rows, in the rail's order, so the menu and the rail can
  /// never disagree about what Nile's destinations are or what ⌘2 means.
  List<PlatformMenuItem> _destinations() => [
    for (final (slot, entry) in kNileRailEntries.indexed)
      PlatformMenuItem(
        label: entry.destination.label,
        shortcut: slot < 9 ? SingleActivator(_digits[slot], meta: true) : null,
        onSelected: () => entry.isBranch
            ? _go(kNileBranchLocations[entry.branch!])
            : _go(entry.location!, push: true),
      ),
  ];

  static const _digits = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  List<PlatformMenuItem> _menus(bool signedIn) => [
    PlatformMenu(
      // macOS ignores this label and uses the bundle name, but it is what the
      // menu is keyed on.
      label: 'Nile',
      menus: [
        // The standard About panel, populated from Info.plist: the app icon,
        // "Nile", the version and build from pubspec, and PRODUCT_COPYRIGHT.
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.about,
        ),
        if (signedIn)
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Settings…',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.comma,
                  meta: true,
                ),
                onSelected: () => _go(NileRoutes.settings, push: true),
              ),
            ],
          ),
        const PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
          ],
        ),
        const PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.showAllApplications,
            ),
          ],
        ),
        const PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ],
        ),
      ],
    ),
    if (signedIn)
      PlatformMenu(
        label: 'File',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'New Post',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  meta: true,
                ),
                onSelected: () => _go(NileRoutes.createPost, push: true),
              ),
              PlatformMenuItem(
                label: 'New Event',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  meta: true,
                  shift: true,
                ),
                onSelected: () => _go(NileRoutes.createEvent, push: true),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Close Window',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyW,
                  meta: true,
                ),
                // Hides rather than closes, matching the red button. See
                // MainFlutterWindow.performClose for why.
                onSelected: MacHost.hideWindow,
              ),
            ],
          ),
        ],
      ),
    // Not gated on `signedIn`: the login screen is two text fields, and an app
    // whose Edit menu appears only after you sign in is stranger than one that
    // always has it.
    PlatformMenu(
      label: 'Edit',
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Cut',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyX,
                meta: true,
              ),
              onSelected: () => _edit(
                const CopySelectionTextIntent.cut(
                  SelectionChangedCause.keyboard,
                ),
              ),
            ),
            PlatformMenuItem(
              label: 'Copy',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyC,
                meta: true,
              ),
              onSelected: () => _edit(CopySelectionTextIntent.copy),
            ),
            PlatformMenuItem(
              label: 'Paste',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
              ),
              onSelected: () =>
                  _edit(const PasteTextIntent(SelectionChangedCause.keyboard)),
            ),
            PlatformMenuItem(
              label: 'Select All',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
              ),
              onSelected: () => _edit(
                const SelectAllTextIntent(SelectionChangedCause.keyboard),
              ),
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Emoji & Symbols',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.space,
                control: true,
                meta: true,
              ),
              onSelected: MacHost.showCharacterPalette,
            ),
          ],
        ),
      ],
    ),
    if (signedIn)
      PlatformMenu(
        label: 'View',
        menus: [
          PlatformMenuItemGroup(members: _destinations()),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Your Profile',
                onSelected: () => _go(kNileBranchLocations[3]),
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.toggleFullScreen,
              ),
            ],
          ),
        ],
      ),
    const PlatformMenu(
      label: 'Window',
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
            ),
          ],
        ),
      ],
    ),
    if (signedIn)
      PlatformMenu(
        label: 'Help',
        menus: [
          PlatformMenuItem(
            label: 'Report a Bug or Idea',
            onSelected: () => _go(NileRoutes.settingsReport, push: true),
          ),
        ],
      ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!MacHost.supported) return widget.child;
    return PlatformMenuBar(
      menus: _menus(AuthGate.instance.stage == GateStage.ready),
      child: widget.child,
    );
  }
}
