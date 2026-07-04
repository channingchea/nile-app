import 'package:flutter/material.dart';
import '../theme.dart';

/// Branded launch screen shown while the app boots and auth resolves.
///
/// Animates the Nile wordmark in with a fade + rise and a pulsing volt
/// accent dot. Purely presentational — routing stays in [_AuthGate].
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  late final Animation<double> _fade = CurvedAnimation(
    parent: _intro,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _rise = Tween(
    begin: const Offset(0, 0.25),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: SizedBox(
          width: double.infinity,
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _rise,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Nile', style: NileTextStyles.displayLg()),
                    Padding(
                      padding: const EdgeInsets.only(bottom: NileSpacing.s8, left: NileSpacing.s4),
                      child: FadeTransition(
                        opacity: _pulse,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: NileColors.volt,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
