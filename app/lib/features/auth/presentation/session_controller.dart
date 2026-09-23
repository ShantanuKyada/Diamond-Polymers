import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../data/auth_repository.dart';
import '../domain/app_user.dart';

/// The signed-in session.
///
/// `null` data means "signed out" — a legitimate resting state, not an error.
/// The router watches this to decide which application a person sees (§5).
class SessionController extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    final repository = ref.watch(authRepositoryProvider);

    // React to sign-out and token expiry wherever they originate, including
    // another tab or a revoked refresh token.
    ref.listen(authStateChangesProvider, (previous, next) {
      final event = next.value?.event;
      if (event == AuthChangeEvent.signedOut) {
        state = const AsyncValue.data(null);
      }
    });

    try {
      return await repository.restore();
    } on AppException {
      // A stored session that no longer maps to a usable profile is treated as
      // signed out rather than as a crash on launch.
      return null;
    }
  }

  /// Signs in. Throws [AppException] so the form can show the reason inline;
  /// the controller itself never parks in an error state, because a failed
  /// attempt still leaves the user legitimately signed out.
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final repository = ref.read(authRepositoryProvider);
    state = const AsyncValue.loading();

    try {
      final user = await repository.signIn(email: email, password: password);
      state = AsyncValue.data(user);
    } catch (error, stack) {
      state = const AsyncValue.data(null);
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Saves profile edits and swaps the refreshed user into the session, so
  /// every screen showing the name updates at once. Throws [AppException].
  Future<void> updateProfile({required String name, String? phone}) async {
    final repository = ref.read(authRepositoryProvider);
    final updated = await repository.updateMyProfile(name: name, phone: phone);
    state = AsyncValue.data(updated);
  }

  Future<void> signOut() async {
    final repository = ref.read(authRepositoryProvider);
    try {
      await repository.signOut();
    } finally {
      // Even if the network call fails, the local session is gone; leaving the
      // user on an admin screen would be worse than a best-effort sign-out.
      state = const AsyncValue.data(null);
    }
  }
}

final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, AppUser?>(SessionController.new);

/// The current user, or null while loading or signed out.
final currentUserProvider = Provider<AppUser?>((ref) {
  return ref.watch(sessionControllerProvider).value;
});

/// Convenience guard for admin-only UI. Route protection also enforces this,
/// and RLS enforces it again server-side (§38).
final isAdminProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider)?.isAdmin ?? false;
});
