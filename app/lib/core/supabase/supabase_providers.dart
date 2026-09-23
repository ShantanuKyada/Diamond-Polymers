import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The single Supabase entry point for the whole app.
///
/// Nothing outside `*/data/*` may read this provider — repositories own all
/// database access so the UI never issues a query directly (§3).
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

/// Auth state as a stream, so session restoration, token refresh and sign-out
/// all propagate without any screen polling for them (§5).
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseClientProvider).auth.onAuthStateChange;
});
