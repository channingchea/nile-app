import 'package:flutter/material.dart';
import '../theme.dart';

/// The original opaque Material 3 bottom navigation bar, preserved so the
/// Liquid Glass migration can be reverted with a one-line swap in
/// `home_screen.dart` (use [NileMaterialNavBar] in place of `NileGlassNavBar`).
///
/// If reverting: also set `extendBody: false` on the Scaffold and drop the
/// extra `NileGlassNavBar.reservedHeight` bottom padding added to the tab
/// scroll views (the opaque bar doesn't need content to flow behind it).
class NileMaterialNavBar extends StatelessWidget {
  const NileMaterialNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      backgroundColor: NileColors.bgSurface,
      indicatorColor: NileColors.volt.withValues(alpha: 0.15),
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home, color: NileColors.volt),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search, color: NileColors.volt),
          label: 'Discover',
        ),
        NavigationDestination(
          icon: Icon(Icons.send_outlined),
          selectedIcon: Icon(Icons.send, color: NileColors.volt),
          label: 'Messages',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person, color: NileColors.volt),
          label: 'Profile',
        ),
      ],
    );
  }
}
