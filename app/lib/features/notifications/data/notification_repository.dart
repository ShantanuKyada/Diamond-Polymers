import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../domain/app_notification.dart';

/// The in-app notification centre (§41).
///
/// Reads come from `v_my_notifications`, which already resolves per-person read
/// state for role broadcasts (A10). Writes go through RPCs so an operator
/// cannot mark someone else's notification read.
class NotificationRepository {
  const NotificationRepository(this._client);

  final SupabaseClient _client;

  Future<List<AppNotification>> list({int limit = 50}) async {
    try {
      final rows = await _client
          .from('v_my_notifications')
          .select('id, title, message, type, metadata, created_at, is_read')
          .order('created_at', ascending: false)
          .limit(limit);

      return rows.map(AppNotification.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<void> markRead(String id) async {
    try {
      await _client.rpc<void>(
        'mark_notification_read',
        params: {'p_notification_id': id},
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<void> markAllRead() async {
    try {
      await _client.rpc<void>('mark_all_notifications_read');
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final notificationRepositoryProvider = Provider<NotificationRepository>((ref) {
  return NotificationRepository(ref.watch(supabaseClientProvider));
});

final notificationsProvider =
    FutureProvider<List<AppNotification>>((ref) async {
  return ref.watch(notificationRepositoryProvider).list();
});
