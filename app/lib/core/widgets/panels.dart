import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small presentational building blocks shared across dashboards and lists.

/// A labelled figure. The number is the loudest thing in the tile (§42).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.tone,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final Color? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: tone ?? scheme.primary),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.numeric(context, size: 26)
                          .copyWith(color: tone ?? scheme.onSurface),
                    ),
                  ),
                  if (unit != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      unit!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stock status pill. The three states map to the `status` column produced by
/// `v_raw_material_stock` / `v_finished_goods_stock`.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final String status;

  (Color, String) get _appearance => switch (status.toUpperCase()) {
        'GOOD' => (AppTheme.good, 'Good'),
        'LOW' => (AppTheme.low, 'Low stock'),
        'OUT' => (AppTheme.critical, 'Out of stock'),
        'ACTIVE' => (AppTheme.good, 'Active'),
        'MAINTENANCE' => (AppTheme.low, 'Maintenance'),
        'INACTIVE' => (AppTheme.neutral, 'Inactive'),
        'REUSABLE' => (AppTheme.good, 'Reusable'),
        'PRESENT' => (AppTheme.good, 'Present'),
        'ABSENT' => (AppTheme.critical, 'Absent'),
        'PAID_LEAVE' => (AppTheme.neutral, 'Paid leave'),
        'UNMARKED' => (AppTheme.neutral, 'Not marked'),
        'DRAFT' => (AppTheme.low, 'Draft'),
        'FINALISED' || 'FINALIZED' => (AppTheme.good, 'Finalised'),
        _ => (AppTheme.neutral, status),
      };

  @override
  Widget build(BuildContext context) {
    final (color, label) = _appearance;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// A titled group with optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A single labelled row inside a card — used for breakdown lists such as
/// "production by machine".
class DataRow2 extends StatelessWidget {
  const DataRow2({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.trailing,
  });

  final String label;
  final String value;
  final String? caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyLarge),
                if (caption != null)
                  Text(
                    caption!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          Text(value, style: AppTheme.numeric(context, size: 16)),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// A banner for connection state and other persistent notices (§46).
class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.message,
    required this.icon,
    required this.color,
    this.action,
  });

  final String message;
  final IconData icon;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
