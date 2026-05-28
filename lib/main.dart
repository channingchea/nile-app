import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const NileApp());
}

class NileApp extends StatelessWidget {
  const NileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nile',
      debugShowCheckedModeBanner: false,
      theme: nileTheme(),
      home: const _AuthGate(),
    );
  }
}

/// Listens to Supabase auth state and routes accordingly.
/// - Authenticated   → HomeScreen
/// - Unauthenticated → LoginScreen
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // While waiting for the first auth event, show a loading screen
        // to avoid a flash of the wrong route.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: NileColors.bgPage,
            body: Center(
              child: CircularProgressIndicator(color: NileColors.volt),
            ),
          );
        }

        final session = snapshot.data?.session;
        if (session != null) {
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
