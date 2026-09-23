import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../domain/app_user.dart';

/// All authentication and profile access. No screen talks to Supabase Auth
/// directly (§3).
class AuthRepository {
  const AuthRepository(this._client);

  final SupabaseClient _client;

  Session? get currentSession => _client.auth.currentSession;

  /// Signs in and returns the factory profile behind the credentials.
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );

      final user = response.user;
      if (user == null) {
        throw const AppException(
          kind: AppErrorKind.authentication,
          message: 'Sign-in failed. Please try again.',
        );
      }

      return await _loadProfile(user.id);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Changes the signed-in person's name and phone, and nothing else (A31).
  ///
  /// Goes through `update_my_profile()` rather than the table: row level
  /// security grants no UPDATE on profiles, precisely so a person cannot write
  /// their own role.
  Future<AppUser> updateMyProfile({
    required String name,
    String? phone,
  }) async {
    try {
      await _client.rpc<Map<String, dynamic>>(
        'update_my_profile',
        params: {'p_name': name.trim(), 'p_phone': phone?.trim()},
      );

      final user = _client.auth.currentUser;
      if (user == null) {
        throw const AppException(
          kind: AppErrorKind.authentication,
          message: 'Your session has ended. Please sign in again.',
        );
      }
      return await _loadProfile(user.id);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Restores the profile for an existing session (§5 session restoration).
  /// Returns null when nobody is signed in.
  Future<AppUser?> restore() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    try {
      return await _loadProfile(user.id);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Reads the profile row for an auth user.
  ///
  /// A missing row is a real condition, not a bug: an account can exist in
  /// Supabase Auth before an administrator links it to a factory profile (A3).
  /// Saying so plainly beats a blank screen.
  Future<AppUser> _loadProfile(String authUserId) async {
    final row = await _client
        .from('profiles')
        .select('id, auth_user_id, name, employee_code, role, active, phone')
        .eq('auth_user_id', authUserId)
        .maybeSingle();

    if (row == null) {
      // Leaving the orphaned session signed in would trap the user on a screen
      // they cannot leave, so it is cleared here.
      await _client.auth.signOut();
      throw const AppException(
        kind: AppErrorKind.authorization,
        message: 'This login is not linked to a staff profile yet. '
            'Ask your administrator to set it up.',
        technicalDetail: 'No profiles row for auth user',
      );
    }

    final user = AppUser.fromProfileRow(row);

    if (!user.active) {
      await _client.auth.signOut();
      throw const AppException(
        kind: AppErrorKind.authorization,
        message: 'This account has been deactivated. '
            'Please contact your administrator.',
      );
    }

    return user;
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});
