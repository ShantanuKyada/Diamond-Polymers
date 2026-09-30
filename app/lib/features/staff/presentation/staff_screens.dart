import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_exception.dart';
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

/// Salary (§33, A38).
///
/// The whole module in three tabs, in the order the factory works:
///
///   Pay       — calculate the month, see what each person is owed, close it
///   Advances  — hand somebody part of their salary before salary day
///   Salaries  — what each person is on
///
/// Nothing here prorates by attendance and nothing adds to a salary. A payslip
/// is the monthly figure, less anything drawn and anything deducted by hand.
class SalaryScreen extends ConsumerWidget {
  const SalaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Salary'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Pay'),
              Tab(text: 'Advances'),
              Tab(text: 'Salaries'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_PayTab(), _AdvancesTab(), _SalariesTab()],
        ),
      ),
    );
  }
}

// =============================================================================
// Pay
// =============================================================================

class _PayTab extends ConsumerWidget {
  const _PayTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(payrollMonthProvider);
    final payslips = ref.watch(payslipsProvider);
    final periods = ref.watch(payrollPeriodsProvider);

    final period = periods.value
        ?.where((p) =>
            p.periodMonth.year == month.year &&
            p.periodMonth.month == month.month)
        .firstOrNull;

    return Column(
      children: [
        _MonthBar(
          month: month,
          onChanged: (value) =>
              ref.read(payrollMonthProvider.notifier).show(value),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(payrollPeriodsProvider);
              await ref.read(payslipsProvider.future);
            },
            child: AsyncView<List<Payslip>>(
              value: payslips,
              onRetry: () => ref.invalidate(payslipsProvider),
              builder: (context, rows) =>
                  _PayslipList(rows: rows, month: month, period: period),
            ),
          ),
        ),
      ],
    );
  }
}

/// The month being worked on, and the way back to earlier ones.
class _MonthBar extends StatelessWidget {
  const _MonthBar({required this.month, required this.onChanged});

  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month, 1);
    final canGoForward = month.isBefore(thisMonth);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous month',
              onPressed: () =>
                  onChanged(DateTime(month.year, month.month - 1, 1)),
            ),
            Expanded(
              child: Text(
                Fmt.monthYear(month),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next month',
              onPressed: canGoForward
                  ? () => onChanged(DateTime(month.year, month.month + 1, 1))
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _PayslipList extends ConsumerWidget {
  const _PayslipList({
    required this.rows,
    required this.month,
    required this.period,
  });

  final List<Payslip> rows;
  final DateTime month;
  final PayrollPeriod? period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbol = ref.watch(currencySymbolProvider);
    final finalised = period != null && !period!.isDraft;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (rows.isEmpty) ...[
          const SizedBox(height: 60),
          EmptyView(
            message: 'Payroll has not been calculated for '
                '${Fmt.monthYear(month)}.',
            icon: Icons.payments_outlined,
          ),
          const SizedBox(height: 20),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Net payable',
                  value: Fmt.money(period?.netTotal ?? 0, symbol: symbol),
                  icon: Icons.account_balance_wallet_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: finalised ? 'Finalised' : 'Draft',
                  value: Fmt.count(rows.length),
                  icon: Icons.description_outlined,
                  tone: finalised ? AppTheme.good : null,
                ),
              ),
            ],
          ),
          const SectionHeader(title: 'Payslips'),
          for (final slip in rows) ...[
            _PayslipCard(slip: slip, month: month, editable: !finalised),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 8),
        _PayActions(month: month, period: period, payslipCount: rows.length),
      ],
    );
  }
}

/// Calculate, and then close. Kept at the foot of the list so the figures are
/// read before either is pressed.
class _PayActions extends ConsumerStatefulWidget {
  const _PayActions({
    required this.month,
    required this.period,
    required this.payslipCount,
  });

  final DateTime month;
  final PayrollPeriod? period;
  final int payslipCount;

  @override
  ConsumerState<_PayActions> createState() => _PayActionsState();
}

class _PayActionsState extends ConsumerState<_PayActions> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final finalised = widget.period != null && !widget.period!.isDraft;

    if (finalised) {
      return InlineBanner(
        message: '${Fmt.monthYear(widget.month)} is finalised. The advances '
            'shown have come off the ledger.',
        icon: Icons.lock_outline,
        color: AppTheme.good,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          InlineBanner(
            message: _error!,
            icon: Icons.error_outline,
            color: AppTheme.low,
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _calculate,
          icon: const Icon(Icons.calculate_outlined),
          label: Text(widget.payslipCount == 0
              ? 'Calculate ${Fmt.monthYear(widget.month)}'
              : 'Recalculate'),
        ),
        if (widget.payslipCount > 0) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _finalise,
            icon: const Icon(Icons.lock_outline),
            label: const Text('Finalise and pay'),
          ),
          const SizedBox(height: 8),
          Text(
            'Finalising takes the advances off the ledger and closes the '
            'month. Nothing can be changed afterwards.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }

  Future<void> _calculate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(staffRepositoryProvider).runPayroll(widget.month);
      if (!mounted) return;
      invalidatePayroll(ref);
      setState(() => _busy = false);
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  Future<void> _finalise() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Finalise ${Fmt.monthYear(widget.month)}?'),
        content: Text(
          'This pays ${Fmt.money(widget.period?.netTotal ?? 0, symbol: ref.read(currencySymbolProvider))} '
          'across ${widget.payslipCount} '
          '${widget.payslipCount == 1 ? 'payslip' : 'payslips'} and takes the '
          'advances off the ledger. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Finalise'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(staffRepositoryProvider).finalisePayroll(widget.month);
      if (!mounted) return;
      invalidatePayroll(ref);
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${Fmt.monthYear(widget.month)} finalised.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }
}

class _PayslipCard extends ConsumerWidget {
  const _PayslipCard({
    required this.slip,
    required this.month,
    required this.editable,
  });

  final Payslip slip;
  final DateTime month;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            _Money(label: 'Monthly salary', value: slip.monthlySalary),
            if (slip.deductionsAmount > 0)
              _Money(label: 'Deductions', value: -slip.deductionsAmount),
            if (slip.advanceRecovered > 0)
              _Money(label: 'Advance taken', value: -slip.advanceRecovered),
            const Divider(height: 20),
            _Money(label: 'Net payable', value: slip.netPayable, bold: true),
            if (editable) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => showDeductionSheet(
                    context,
                    ref,
                    profileId: slip.profileId,
                    staffName: slip.staffName,
                    month: month,
                  ),
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  label: const Text('Deduct'),
                ),
              ),
            ],
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

// =============================================================================
// Advances
// =============================================================================

class _AdvancesTab extends ConsumerWidget {
  const _AdvancesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advances = ref.watch(advancesProvider);
    final symbol = ref.watch(currencySymbolProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(advancesProvider.future),
        child: AsyncView<List<StaffAdvance>>(
          value: advances,
          onRetry: () => ref.invalidate(advancesProvider),
          builder: (context, rows) {
            final outstanding = rows.where((r) => r.outstanding > 0).toList();
            final total = rows.fold<double>(0, (sum, r) => sum + r.outstanding);

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                StatTile(
                  label: 'Outstanding across ${outstanding.length} '
                      '${outstanding.length == 1 ? 'person' : 'people'}',
                  value: Fmt.money(total, symbol: symbol),
                  icon: Icons.savings_outlined,
                  tone: total > 0 ? AppTheme.low : AppTheme.good,
                ),
                if (rows.isEmpty) ...[
                  const SizedBox(height: 60),
                  const EmptyView(
                    message: 'No advances have been given.',
                    icon: Icons.savings_outlined,
                  ),
                ] else ...[
                  const SectionHeader(title: 'By person'),
                  Card(
                    child: Column(
                      children: [
                        for (final (i, row) in rows.indexed) ...[
                          if (i > 0) const Divider(height: 1),
                          DataRow2(
                            label: row.staffName,
                            caption: 'Given ${Fmt.money(row.totalIssued, symbol: symbol)} · '
                                'recovered ${Fmt.money(row.totalRecovered, symbol: symbol)}',
                            value: Fmt.money(row.outstanding, symbol: symbol),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAdvanceSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Give advance'),
      ),
    );
  }
}

// =============================================================================
// Salaries
// =============================================================================

class _SalariesTab extends ConsumerWidget {
  const _SalariesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pay = ref.watch(staffPayProvider);
    final symbol = ref.watch(currencySymbolProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.refresh(staffPayProvider.future),
      child: AsyncView<List<StaffPay>>(
        value: pay,
        onRetry: () => ref.invalidate(staffPayProvider),
        builder: (context, rows) {
          if (rows.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                EmptyView(
                  message: 'Nobody is on the payroll yet.',
                  icon: Icons.badge_outlined,
                ),
              ],
            );
          }

          final unpaid = rows.where((r) => !r.hasSalary).length;

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (unpaid > 0)
                InlineBanner(
                  message: '$unpaid ${unpaid == 1 ? 'person has' : 'people have'} '
                      'no salary set and will be left off the payroll.',
                  icon: Icons.info_outline,
                  color: AppTheme.low,
                ),
              const SectionHeader(title: 'Monthly salary'),
              Card(
                child: Column(
                  children: [
                    for (final (i, row) in rows.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      InkWell(
                        onTap: () => showSalarySheet(context, ref, person: row),
                        child: DataRow2(
                          label: row.staffName,
                          caption: _caption(row, symbol),
                          value: row.hasSalary
                              ? Fmt.money(row.monthlySalary, symbol: symbol)
                              : '—',
                          trailing: const Icon(Icons.chevron_right, size: 18),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _caption(StaffPay row, String symbol) {
    final parts = <String>[row.employeeCode];
    if (row.upcomingSalary != null && row.upcomingFrom != null) {
      parts.add('${Fmt.money(row.upcomingSalary, symbol: symbol)} '
          'from ${Fmt.date(row.upcomingFrom!)}');
    }
    if (row.outstandingAdvance > 0) {
      parts.add('${Fmt.money(row.outstandingAdvance, symbol: symbol)} drawn');
    }
    return parts.join(' · ');
  }
}

// =============================================================================
// The three things an administrator does here
// =============================================================================

/// Put somebody on a salary, or change the one they are on.
Future<void> showSalarySheet(
  BuildContext context,
  WidgetRef ref, {
  required StaffPay person,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _SalarySheet(person: person),
    ),
  );
}

class _SalarySheet extends ConsumerStatefulWidget {
  const _SalarySheet({required this.person});

  final StaffPay person;

  @override
  ConsumerState<_SalarySheet> createState() => _SalarySheetState();
}

class _SalarySheetState extends ConsumerState<_SalarySheet> {
  final _amount = TextEditingController();
  late DateTime _from;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    // Dates only. The salary on file is a date at midnight and DateTime.now()
    // is not, so comparing the two directly would read "today is after today"
    // and offer a start date the database refuses.
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);

    // A change has to start after the period already open, so the earliest it
    // can begin is the day after that one did.
    final open = widget.person.upcomingFrom ?? widget.person.effectiveFrom;
    if (open != null) {
      final openDay = DateTime(open.year, open.month, open.day);
      if (!openDay.isBefore(_from)) {
        _from = openDay.add(const Duration(days: 1));
      }
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbol = ref.watch(currencySymbolProvider);
    final person = widget.person;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              person.hasSalary ? 'Change salary' : 'Set salary',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              person.hasSalary
                  ? '${person.staffName} is on '
                      '${Fmt.money(person.monthlySalary, symbol: symbol)} a month.'
                  : '${person.staffName} has no salary set.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Monthly salary',
                prefixText: '$symbol ',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text('From ${Fmt.date(_from)}'),
            ),
            const SizedBox(height: 4),
            Text(
              'The old figure is kept with an end date, so payslips already '
              'issued keep the rate they were paid at.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineBanner(
                message: _error!,
                icon: Icons.error_outline,
                color: AppTheme.low,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a monthly salary greater than zero.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(staffRepositoryProvider).setSalary(
            profileId: widget.person.profileId,
            monthlySalary: amount,
            effectiveFrom: _from,
          );
      if (!mounted) return;
      invalidatePayroll(ref);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.person.staffName} is now on '
            '${Fmt.money(amount, symbol: ref.read(currencySymbolProvider))} '
            'a month.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }
}

/// Hand somebody part of their salary before salary day.
Future<void> showAdvanceSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: const _AdvanceSheet(),
    ),
  );
}

class _AdvanceSheet extends ConsumerStatefulWidget {
  const _AdvanceSheet();

  @override
  ConsumerState<_AdvanceSheet> createState() => _AdvanceSheetState();
}

class _AdvanceSheetState extends ConsumerState<_AdvanceSheet> {
  final _amount = TextEditingController();
  final _remarks = TextEditingController();
  String? _profileId;
  String? _attemptRef;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _remarks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbol = ref.watch(currencySymbolProvider);
    final people = ref.watch(staffPayProvider).value ?? const <StaffPay>[];
    final chosen = people.where((p) => p.profileId == _profileId).firstOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Give advance',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'This comes off the next payslip, as much of it as that month '
              'can cover.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _profileId,
              decoration: const InputDecoration(
                labelText: 'Who',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in people)
                  DropdownMenuItem(
                    value: p.profileId,
                    child: Text('${p.staffName} · ${p.employeeCode}'),
                  ),
              ],
              onChanged: (value) => setState(() => _profileId = value),
            ),
            if (chosen != null && chosen.outstandingAdvance > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${chosen.staffName} has already drawn '
                '${Fmt.money(chosen.outstandingAdvance, symbol: symbol)}.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.low),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '$symbol ',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _remarks,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineBanner(
                message: _error!,
                icon: Icons.error_outline,
                color: AppTheme.low,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Give advance'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    if (_profileId == null) {
      setState(() => _error = 'Choose who the advance is for.');
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _attemptRef ??= const Uuid().v4();
    });

    try {
      await ref.read(staffRepositoryProvider).issueAdvance(
            profileId: _profileId!,
            amount: amount,
            clientRef: _attemptRef!,
            remarks: _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
          );
      if (!mounted) return;
      invalidatePayroll(ref);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Advance of '
            '${Fmt.money(amount, symbol: ref.read(currencySymbolProvider))} '
            'recorded.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }
}

/// Take something off one person's pay for one month.
Future<void> showDeductionSheet(
  BuildContext context,
  WidgetRef ref, {
  required String profileId,
  required String staffName,
  required DateTime month,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _DeductionSheet(
        profileId: profileId,
        staffName: staffName,
        month: month,
      ),
    ),
  );
}

class _DeductionSheet extends ConsumerStatefulWidget {
  const _DeductionSheet({
    required this.profileId,
    required this.staffName,
    required this.month,
  });

  final String profileId;
  final String staffName;
  final DateTime month;

  @override
  ConsumerState<_DeductionSheet> createState() => _DeductionSheetState();
}

class _DeductionSheetState extends ConsumerState<_DeductionSheet> {
  final _label = TextEditingController();
  final _amount = TextEditingController();
  String? _attemptRef;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbol = ref.watch(currencySymbolProvider);
    final mine = (ref.watch(deductionsProvider).value ??
            const <StaffDeduction>[])
        .where((d) => d.profileId == widget.profileId)
        .toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Deduct from ${widget.staffName}',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'For ${Fmt.monthYear(widget.month)}. Recalculate the month '
              'afterwards to see it on the payslip.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (mine.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final d in mine)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(d.label),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(Fmt.money(d.amount, symbol: symbol)),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Remove',
                        onPressed: _busy ? null : () => _remove(d),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What for',
                hintText: 'Canteen, damage, long absence…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '$symbol ',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineBanner(
                message: _error!,
                icon: Icons.error_outline,
                color: AppTheme.low,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Add deduction'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(StaffDeduction d) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(staffRepositoryProvider).removeDeduction(d.id);
      if (!mounted) return;
      invalidatePayroll(ref);
      setState(() => _busy = false);
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  Future<void> _save() async {
    final label = _label.text.trim();
    final amount = double.tryParse(_amount.text.trim());
    if (label.isEmpty) {
      setState(() => _error = 'Say what the deduction is for.');
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount greater than zero.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _attemptRef ??= const Uuid().v4();
    });

    try {
      await ref.read(staffRepositoryProvider).addDeduction(
            profileId: widget.profileId,
            periodMonth: widget.month,
            label: label,
            amount: amount,
            clientRef: _attemptRef!,
          );
      if (!mounted) return;
      invalidatePayroll(ref);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deduction added. Recalculate the month to apply it.'),
        ),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }
}
