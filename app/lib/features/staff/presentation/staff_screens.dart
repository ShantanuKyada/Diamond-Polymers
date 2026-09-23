import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../masters/data/settings_values.dart';
import '../data/staff_repository.dart';

/// Punches — who is on site today, and the month behind it (§33).
class PunchesScreen extends ConsumerWidget {
  const PunchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(attendanceProvider);
    final month = ref.watch(monthlyAttendanceProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Punches'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Today'), Tab(text: 'This month')],
          ),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: () async => ref.refresh(attendanceProvider.future),
              child: AsyncView<List<AttendanceDay>>(
                value: today,
                onRetry: () => ref.invalidate(attendanceProvider),
                builder: (context, rows) => _TodayTab(rows: rows),
              ),
            ),
            RefreshIndicator(
              onRefresh: () async =>
                  ref.refresh(monthlyAttendanceProvider.future),
              child: AsyncView<List<MonthlyAttendance>>(
                value: month,
                onRetry: () => ref.invalidate(monthlyAttendanceProvider),
                builder: (context, rows) => _MonthTab(rows: rows),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodayTab extends StatelessWidget {
  const _TodayTab({required this.rows});

  final List<AttendanceDay> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            message: 'Nobody has punched in today.',
            icon: Icons.how_to_reg_outlined,
          ),
        ],
      );
    }

    final onSite = rows.where((r) => r.isOnSite).length;
    final present = rows.where((r) => r.status == 'PRESENT').length;
    final hours = rows.fold<double>(0, (sum, r) => sum + r.workedHours);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'On site now',
                value: Fmt.count(onSite),
                icon: Icons.badge_outlined,
                tone: onSite > 0 ? AppTheme.good : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Marked present',
                value: Fmt.count(present),
                icon: Icons.how_to_reg_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        StatTile(
          label: 'Hours worked today',
          value: Fmt.quantity(hours),
          unit: 'hours',
          icon: Icons.schedule_rounded,
        ),
        const SectionHeader(title: 'Attendance'),
        Card(
          child: Column(
            children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) const Divider(height: 1),
                _AttendanceTile(day: row),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AttendanceTile extends StatelessWidget {
  const _AttendanceTile({required this.day});

  final AttendanceDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final times = [
      if (day.punchInAt != null) 'In ${Fmt.time(day.punchInAt!.toLocal())}',
      if (day.punchOutAt != null) 'Out ${Fmt.time(day.punchOutAt!.toLocal())}',
      if (day.shiftName != null) day.shiftName!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: day.isOnSite
                ? AppTheme.good.withValues(alpha: 0.15)
                : scheme.surfaceContainerHighest,
            child: Icon(
              day.isOnSite ? Icons.login_rounded : Icons.person_outline_rounded,
              size: 18,
              color: day.isOnSite ? AppTheme.good : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  day.staffName,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (times.isNotEmpty)
                  Text(
                    times,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusChip(status: day.status),
              if (day.workedHours > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${Fmt.quantity(day.workedHours)} h',
                  style: AppTheme.numeric(context, size: 14),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MonthTab extends StatelessWidget {
  const _MonthTab({required this.rows});

  final List<MonthlyAttendance> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            message: 'No attendance has been marked this month.',
            icon: Icons.calendar_month_outlined,
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SectionHeader(title: Fmt.monthYear(DateTime.now())),
        Card(
          child: Column(
            children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.staffName,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(
                            '${row.presentDays} days',
                            style: AppTheme.numeric(context, size: 15),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 14,
                        children: [
                          _Metric(label: 'Present', value: '${row.presentDays}'),
                          _Metric(label: 'Absent', value: '${row.absentDays}'),
                          _Metric(
                              label: 'Leave', value: '${row.paidLeaveDays}'),
                          _Metric(
                            label: 'Overtime',
                            value: '${Fmt.quantity(row.overtimeHours)} h',
                          ),
                        ],
                      ),
                    ],
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

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        text: '$label ',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        children: [
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// =============================================================================

/// Salary — payslips for the current period and outstanding advances (§33).
class SalaryScreen extends ConsumerWidget {
  const SalaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payslips = ref.watch(payslipsProvider);
    final advances = ref.watch(advancesProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Salary'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Payslips'), Tab(text: 'Advances')],
          ),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: () async => ref.refresh(payslipsProvider.future),
              child: AsyncView<List<Payslip>>(
                value: payslips,
                onRetry: () => ref.invalidate(payslipsProvider),
                builder: (context, rows) => _PayslipsTab(rows: rows),
              ),
            ),
            RefreshIndicator(
              onRefresh: () async => ref.refresh(advancesProvider.future),
              child: AsyncView<List<StaffAdvance>>(
                value: advances,
                onRetry: () => ref.invalidate(advancesProvider),
                builder: (context, rows) => _AdvancesTab(rows: rows),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayslipsTab extends ConsumerWidget {
  const _PayslipsTab({required this.rows});

  final List<Payslip> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            message: 'No payroll has been run yet.',
            icon: Icons.payments_outlined,
          ),
        ],
      );
    }

    final total = rows.fold<double>(0, (sum, r) => sum + r.netPayable);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Net payable',
                value: Fmt.money(total, symbol: ref.watch(currencySymbolProvider)),
                icon: Icons.account_balance_wallet_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Payslips',
                value: Fmt.count(rows.length),
                icon: Icons.description_outlined,
              ),
            ),
          ],
        ),
        const SectionHeader(title: 'Payslips'),
        for (final slip in rows) ...[
          _PayslipCard(slip: slip),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _PayslipCard extends StatelessWidget {
  const _PayslipCard({required this.slip});

  final Payslip slip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slip.staffName,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${slip.employeeCode} · '
                        '${Fmt.monthYear(slip.periodMonth)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                StatusChip(status: slip.periodStatus),
              ],
            ),
            const Divider(height: 22),
            _Money(label: 'Basic', value: slip.basicAmount),
            if (slip.overtimeAmount > 0)
              _Money(label: 'Overtime', value: slip.overtimeAmount),
            if (slip.additionsAmount > 0)
              _Money(label: 'Additions', value: slip.additionsAmount),
            if (slip.deductionsAmount > 0)
              _Money(label: 'Deductions', value: -slip.deductionsAmount),
            if (slip.advanceRecovered > 0)
              _Money(label: 'Advance recovered', value: -slip.advanceRecovered),
            const Divider(height: 20),
            _Money(label: 'Net payable', value: slip.netPayable, bold: true),
            const SizedBox(height: 6),
            Text(
              '${slip.presentDays} days present · '
              '${Fmt.quantity(slip.payableDays)} payable',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Money extends ConsumerWidget {
  const _Money({required this.label, required this.value, this.bold = false});

  final String label;
  final double value;
  final bool bold;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: bold ? null : theme.colorScheme.onSurfaceVariant,
                fontWeight: bold ? FontWeight.w700 : null,
              ),
            ),
          ),
          Text(
            Fmt.money(value, symbol: ref.watch(currencySymbolProvider)),
            style: bold
                ? AppTheme.numeric(context, size: 18)
                : theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: value < 0 ? AppTheme.low : null,
                  ),
          ),
        ],
      ),
    );
  }
}

class _AdvancesTab extends ConsumerWidget {
  const _AdvancesTab({required this.rows});

  final List<StaffAdvance> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outstanding = rows.where((r) => r.outstanding > 0).toList();

    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            message: 'No advances have been issued.',
            icon: Icons.savings_outlined,
          ),
        ],
      );
    }

    final total = rows.fold<double>(0, (sum, r) => sum + r.outstanding);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        StatTile(
          label: 'Outstanding across ${outstanding.length} '
              '${outstanding.length == 1 ? 'person' : 'people'}',
          value: Fmt.money(total, symbol: ref.watch(currencySymbolProvider)),
          icon: Icons.savings_outlined,
          tone: total > 0 ? AppTheme.low : AppTheme.good,
        ),
        const SectionHeader(title: 'By person'),
        Card(
          child: Column(
            children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) const Divider(height: 1),
                DataRow2(
                  label: row.staffName,
                  caption: 'Issued ${Fmt.money(row.totalIssued, symbol: ref.watch(currencySymbolProvider))} · '
                      'recovered ${Fmt.money(row.totalRecovered, symbol: ref.watch(currencySymbolProvider))}',
                  value: Fmt.money(row.outstanding, symbol: ref.watch(currencySymbolProvider)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
