import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../masters/data/settings_values.dart';
import '../data/staff_repository.dart';
import '../../../core/widgets/responsive.dart';
import 'salary_slip_action.dart';

/// What a worker is owed and what they have been paid (A39).
///
/// The policies have always allowed a worker to read their own payslip; there
/// was simply no screen, so a slip only reached them on paper. This is that
/// screen, and it is read-only by construction: every write in the payroll
/// module calls `app.require_admin()`, so there is nothing here to guard
/// against — only a question to answer.
///
/// The question a worker actually asks is "why is this the amount?", so the
/// card shows the working rather than a single figure: the month's salary, what
/// they took during the month, anything deducted, and what is left.
class MyPayScreen extends ConsumerWidget {
  const MyPayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payslips = ref.watch(myPayslipsProvider);
    final advance = ref.watch(myAdvanceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My pay')),
      body: PageBody(child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myAdvanceProvider);
          await ref.read(myPayslipsProvider.future);
        },
        child: AsyncView<List<Payslip>>(
          value: payslips,
          onRetry: () => ref.invalidate(myPayslipsProvider),
          builder: (context, rows) => _Body(
            rows: rows,
            advance: advance.value,
          ),
        ),
      )),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.rows, required this.advance});

  final List<Payslip> rows;
  final StaffPay? advance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbol = ref.watch(currencySymbolProvider);
    final theme = Theme.of(context);

    // Draft months are left out. A worker seeing a figure that the office has
    // not agreed yet would be told a number that can still change, and would
    // reasonably treat it as a promise.
    final agreed = rows.where((r) => !r.isDraft).toList();
    final owed = agreed.fold<double>(0, (sum, r) => sum + r.outstanding);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: owed > 0 ? 'Owed to you' : 'Nothing owed',
                value: Fmt.money(owed, symbol: symbol),
                icon: Icons.account_balance_wallet_outlined,
                tone: owed > 0 ? AppTheme.low : AppTheme.good,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Advance to repay',
                value: Fmt.money(advance?.outstandingAdvance ?? 0,
                    symbol: symbol),
                icon: Icons.savings_outlined,
                tone: (advance?.outstandingAdvance ?? 0) > 0
                    ? AppTheme.low
                    : AppTheme.good,
              ),
            ),
          ],
        ),

        if (advance != null && advance!.monthlySalary != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                DataRow2(
                  label: 'Monthly salary',
                  value: Fmt.money(advance!.monthlySalary, symbol: symbol),
                ),
                if (advance!.salaryDay != null) ...[
                  const Divider(height: 1),
                  DataRow2(
                    label: 'Paid on',
                    value: '${Fmt.ordinalDay(advance!.salaryDay!)} '
                        'of the month',
                  ),
                ],
                if (advance!.joinedOn != null) ...[
                  const Divider(height: 1),
                  DataRow2(
                    label: 'Joined',
                    value: Fmt.date(advance!.joinedOn!),
                  ),
                ],
              ],
            ),
          ),
        ],

        if (agreed.isEmpty) ...[
          const SizedBox(height: 48),
          EmptyView(
            message: rows.isEmpty
                ? 'No payslips yet. One appears here after the office works '
                    'out the month.'
                : 'This month is still being worked out. It appears here once '
                    'the office has finished it.',
            icon: Icons.payments_outlined,
          ),
        ] else ...[
          const SectionHeader(title: 'Payslips'),
          for (final slip in agreed) ...[
            _MyPayslipCard(slip: slip),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 4),
          Text(
            'If a figure here does not look right, speak to the office — they '
            'can see the same record.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _MyPayslipCard extends ConsumerWidget {
  const _MyPayslipCard({required this.slip});

  final Payslip slip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final symbol = ref.watch(currencySymbolProvider);

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
                        Fmt.monthYear(slip.periodMonth),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (slip.salaryDueOn != null)
                        Text(
                          'Due ${Fmt.date(slip.salaryDueOn!)}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                StatusChip(status: slip.status.wire),
              ],
            ),
            const Divider(height: 22),
            _Line(label: 'Monthly salary', value: slip.monthlySalary),
            if (slip.advanceRecovered > 0)
              _Line(
                label: 'Advance you took',
                value: -slip.advanceRecovered,
              ),
            if (slip.deductionsAmount > 0)
              _Line(label: 'Deductions', value: -slip.deductionsAmount),
            const Divider(height: 20),
            _Line(label: 'Your pay', value: slip.netPayable, bold: true),
            const SizedBox(height: 2),
            _Line(label: 'Paid to you', value: slip.paidAmount),
            if (slip.outstanding > 0)
              _Line(
                label: 'Still to come',
                value: slip.outstanding,
                bold: true,
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => showSalarySlipOptions(context, ref, slip),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Get slip'),
              ),
            ),
            if (slip.paidAmount > 0) _Payments(payslipId: slip.id, symbol: symbol),
          ],
        ),
      ),
    );
  }
}

/// When and how the money arrived. A worker checking a figure wants the dates,
/// not just the total.
class _Payments extends ConsumerWidget {
  const _Payments({required this.payslipId, required this.symbol});

  final String payslipId;
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payments = ref.watch(paymentsProvider(payslipId));
    final theme = Theme.of(context);

    return payments.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 18),
            Text(
              'Payments',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            for (final p in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      p.isReversal ? Icons.undo_rounded : Icons.check_rounded,
                      size: 15,
                      color: p.isReversal
                          ? AppTheme.low
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [
                          Fmt.date(p.paidOn),
                          if ((p.method ?? '').isNotEmpty) p.method!,
                          // Said plainly rather than quietly netted off: a
                          // worker looking at two rows that cancel out should
                          // be able to see why.
                          if (p.isReversal) 'taken back',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      Fmt.money(p.amount, symbol: symbol),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: p.amount < 0 ? AppTheme.low : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Line extends ConsumerWidget {
  const _Line({required this.label, required this.value, this.bold = false});

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
