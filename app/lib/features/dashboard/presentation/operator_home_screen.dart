import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routing/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../auth/presentation/session_controller.dart';
import '../../masters/data/settings_values.dart';
import '../../staff/data/staff_repository.dart';
import '../data/dashboard_repository.dart';
import '../domain/dashboard_models.dart';

/// The operator's home. Deliberately much simpler than the admin dashboard:
/// production entry is one tap away, and attendance is visible without asking
/// for it (§28, A33). Material entry is an administrator's job now (A30), so it
/// is not offered here at all.
class OperatorHomeScreen extends ConsumerWidget {
  const OperatorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(operatorDashboardProvider);
    final user = ref.watch(currentUserProvider);
    final factoryName = ref.watch(factoryNameProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Home'),
            Text(
              factoryName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myAttendanceProvider);
          return ref.refresh(operatorDashboardProvider.future);
        },
        child: AsyncView<OperatorDashboard>(
          value: snapshot,
          onRetry: () => ref.invalidate(operatorDashboardProvider),
          builder: (context, data) => _Content(
            data: data,
            operatorName: user?.name ?? '',
            employeeCode: user?.employeeCode ?? '',
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.data,
    required this.operatorName,
    required this.employeeCode,
  });

  final OperatorDashboard data;
  final String operatorName;
  final String employeeCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final assignment = data.assignment;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ---- Who and where ------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        operatorName.isEmpty ? '?' : operatorName[0],
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            operatorName,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            employeeCode,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      Fmt.relativeDay(data.date),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const Divider(height: 28),
                if (assignment == null)
                  // Being honest about a missing assignment is better than an
                  // empty box: without one the entry RPCs will refuse (DP006).
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          size: 20, color: AppTheme.low),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'No machine assigned. Ask your administrator to '
                          'assign one before recording production.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: _Fact(
                          icon: Icons.precision_manufacturing_outlined,
                          label: 'Machine',
                          value: assignment.machineName,
                        ),
                      ),
                      Expanded(
                        child: _Fact(
                          icon: Icons.schedule_rounded,
                          label: 'Shift',
                          value: assignment.shiftName ?? 'Not set',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),

        // ---- Primary action (§28: one tap) ----------------------------------
        const SectionHeader(title: 'Record'),
        _ActionCard(
          icon: Icons.add_box_outlined,
          label: 'Production Entry',
          caption: 'Bundles and bags produced this shift',
          onTap: () => context.pushNamed(AppRoute.productionEntry.name),
        ),

        // ---- Attendance (A33) ---------------------------------------------
        const SectionHeader(title: 'Attendance'),
        const _AttendanceSection(),

        // ---- Today ----------------------------------------------------------
        const SectionHeader(title: 'Today'),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Bundles produced',
                value: Fmt.count(data.bundlesToday),
                icon: Icons.inventory_2_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Entries',
                value: Fmt.count(data.entryCount),
                icon: Icons.checklist_rounded,
              ),
            ),
          ],
        ),

        if (data.consumptionToday.isNotEmpty) ...[
          const SectionHeader(title: 'Material used today'),
          Card(
            child: Column(
              children: [
                for (final (index, line) in data.consumptionToday.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  DataRow2(
                    label: line.name,
                    value: Fmt.qtyWithUnit(line.consumed, line.unit),
                  ),
                ],
              ],
            ),
          ),
        ],

        // ---- Recent ----------------------------------------------------------
        const SectionHeader(title: 'Recent entries'),
        if (data.recentProduction.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
              child: Center(
                child: Text('Nothing recorded yet today.'),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final (index, entry)
                    in data.recentProduction.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  ListTile(
                    title: Text(
                      '${entry.pipeTypeName} · ${entry.pipeSizeName}',
                    ),
                    subtitle: Text(
                      '${entry.shiftName} · ${Fmt.dateTime(entry.createdAt)}',
                    ),
                    trailing: Text(
                      Fmt.count(entry.bundles),
                      style: AppTheme.numeric(context, size: 16),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
    this.caption,
  });

  final IconData icon;
  final String label;
  final String? caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.primaryContainer,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
          child: Row(
            children: [
              Icon(icon, size: 32, color: scheme.onPrimaryContainer),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (caption != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        caption!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer
                              .withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

/// Today's attendance, then the week behind it (A33).
///
/// Read-only: the section reports what has been recorded. Row level security
/// limits `v_attendance_days` to the person signed in.
class _AttendanceSection extends ConsumerWidget {
  const _AttendanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(myAttendanceProvider);

    return days.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Attendance could not be loaded right now.'),
              ),
              TextButton(
                onPressed: () => ref.invalidate(myAttendanceProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (rows) {
        final todayIso = Fmt.isoDate(DateTime.now());
        AttendanceDay? today;
        for (final row in rows) {
          if (Fmt.isoDate(row.workDate) == todayIso) today = row;
        }
        final earlier =
            rows.where((r) => Fmt.isoDate(r.workDate) != todayIso).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TodayAttendance(day: today),
            if (earlier.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            'This week',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          Text(
                            '${earlier.where((d) => d.status == 'PRESENT').length} '
                            'of ${earlier.length} days present',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    for (final (index, day) in earlier.indexed) ...[
                      if (index > 0) const Divider(height: 1),
                      _AttendanceRow(day: day),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TodayAttendance extends StatelessWidget {
  const _TodayAttendance({required this.day});

  final AttendanceDay? day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final today = day;

    final (headline, tone, icon) = switch (today) {
      null => ('Not checked in yet', AppTheme.neutral, Icons.login_rounded),
      final d when d.isOnSite => ('On shift now', AppTheme.good, Icons.badge_outlined),
      final d when d.punchOutAt != null =>
        ('Shift complete', AppTheme.good, Icons.task_alt_rounded),
      final d when d.status == 'ABSENT' =>
        ('Marked absent', AppTheme.critical, Icons.event_busy_outlined),
      final d when d.status == 'PAID_LEAVE' =>
        ('On leave today', AppTheme.neutral, Icons.beach_access_outlined),
      _ => ('Attendance marked', AppTheme.neutral, Icons.event_available_outlined),
    };

    String time(DateTime? value) =>
        value == null ? '—' : Fmt.time(value.toLocal());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: tone.withValues(alpha: 0.14),
                  child: Icon(icon, color: tone, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        today?.shiftName == null
                            ? 'Today'
                            : 'Today · ${today!.shiftName} shift',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (today != null) StatusChip(status: today.status),
              ],
            ),
            if (today != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _TimeFact(
                      label: 'Checked in',
                      value: time(today.punchInAt),
                    ),
                  ),
                  Expanded(
                    child: _TimeFact(
                      label: 'Checked out',
                      value: time(today.punchOutAt),
                    ),
                  ),
                  Expanded(
                    child: _TimeFact(
                      label: 'Hours',
                      value: today.workedHours > 0
                          ? Fmt.quantity(today.workedHours)
                          : '—',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimeFact extends StatelessWidget {
  const _TimeFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: AppTheme.numeric(context, size: 17)),
      ],
    );
  }
}

class _AttendanceRow extends StatelessWidget {
  const _AttendanceRow({required this.day});

  final AttendanceDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final times = [
      if (day.punchInAt != null) Fmt.time(day.punchInAt!.toLocal()),
      if (day.punchOutAt != null) Fmt.time(day.punchOutAt!.toLocal()),
    ].join(' – ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Fmt.relativeDay(day.workDate),
                    style: theme.textTheme.bodyMedium),
                Text(
                  [
                    if (day.shiftName != null) day.shiftName!,
                    if (times.isNotEmpty) times,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (day.workedHours > 0) ...[
            Text('${Fmt.quantity(day.workedHours)} h',
                style: AppTheme.numeric(context, size: 14)),
            const SizedBox(width: 10),
          ],
          StatusChip(status: day.status),
        ],
      ),
    );
  }
}
