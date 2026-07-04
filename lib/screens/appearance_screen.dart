import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/nile_glass_app_bar.dart';
import '../widgets/theme_mode_picker.dart';

/// Theme Light/Dark/System picker, split out of Settings into its own screen.
/// Selecting a mode applies instantly app-wide via ThemeService.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      extendBodyBehindAppBar: true,
      appBar: NileGlassBar.appBar(title: const Text('Appearance')),
      body: NileMaxWidth(
        child: ListView(
          padding: EdgeInsets.fromLTRB(NileSpacing.s16, topInset + NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: NileSpacing.s4,
                bottom: NileSpacing.s8,
              ),
              child: Text('APPEARANCE', style: NileTextStyles.labelSm()),
            ),
            const ThemeModePicker(),
          ],
        ),
      ),
    );
  }
}
