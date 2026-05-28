import 'package:supabase_flutter/supabase_flutter.dart';

/// Global convenience getter — use [supabase] anywhere in the app
/// instead of Supabase.instance.client.
///
/// Example:
///   final user = supabase.auth.currentUser;
///   final data = await supabase.from('posts').select().limit(20);
SupabaseClient get supabase => Supabase.instance.client;
