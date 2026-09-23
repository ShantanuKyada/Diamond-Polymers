import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Notification categories (§41).
enum NotificationCategory {
  stockLow('STOCK_LOW'),
  dispatch('DISPATCH'),
  production('PRODUCTION'),
  wastage('WASTAGE'),
  system('SYSTEM');

  const NotificationCategory(this.wire);

  final String wire;

  static NotificationCategory fromWire(String? value) {
    return NotificationCategory.values.firstWhere(
      (c) => c.wire == value,
      orElse: () => NotificationCategory.system,
    );
  }

  IconData get icon => switch (this) {
        NotificationCategory.stockLow => Icons.warning_amber_rounded,
        NotificationCategory.dispatch => Icons.local_shipping_outlined,
        NotificationCategory.production => Icons.inventory_2_outlined,
        NotificationCategory.wastage => Icons.delete_outline_rounded,
        NotificationCategory.system => Icons.info_outline_rounded,
      };

  Color get color => switch (this) {
        NotificationCategory.stockLow => AppTheme.low,
        NotificationCategory.dispatch => AppTheme.good,
        NotificationCategory.production => AppTheme.neutral,
        NotificationCategory.wastage => AppTheme.low,
        NotificationCategory.system => AppTheme.neutral,
      };
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.category,
    required this.createdAt,
    required this.isRead,
    this.metadata = const {},
  });

  final String id;
  final String title;
  final String message;
  final NotificationCategory category;
  final DateTime createdAt;
  final bool isRead;
  final Map<String, dynamic> metadata;

  factory AppNotification.from(Map<String, dynamic> row) {
    return AppNotification(
      id: row['id'] as String,
      title: row['title'] as String? ?? '',
      message: row['message'] as String? ?? '',
      category: NotificationCategory.fromWire(row['type'] as String?),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      isRead: row['is_read'] as bool? ?? false,
      metadata: row['metadata'] as Map<String, dynamic>? ?? const {},
    );
  }
}
