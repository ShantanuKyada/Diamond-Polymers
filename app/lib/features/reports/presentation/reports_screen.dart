import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../dashboard/domain/dashboard_models.dart';
import '../../dispatch/data/dispatch_repository.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/domain/masters.dart';
import '../../production/data/production_repository.dart';
import '../../production/domain/production.dart';
import '../../wastage/data/wastage_repository.dart';

/// Reports (§49).
///
/// Composed from the same reads the operational screens use rather than a
/// parallel set of queries, so a number here can never disagree with the number
/// on the screen it came from. The period selector drives everything at once.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _days = 7;

  DateTime get _from {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _days == 0 ? today : today.subtract(Duration(days: _days - 1));
  }

  String get _periodLabel => switch (_days) {
        0 => 'Today',
        7 => 'Last 7 days',
        30 => 'Last 30 days',
        _ => 'Last $_days days',
      };

  @override
  Widget build(BuildContext context) {
    // Date-only, and no open end: a filter carrying DateTime.now() would be a
    // different value on every build, and since it is the provider family key
    // the screen would refetch itself in a loop.
    final filter = ProductionFilter(from: _from);
    final production = ref.watch(productionRecordsProvider(filter));

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(productionRecordsProvider(filter));
          ref.invalidate(dispatchesProvider);
          ref.invalidate(wastageEntriesProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _PeriodPicker(
              selected: _days,
              onSelect: (days) => setState(() => _days = days),
            ),

            AsyncView<List<ProductionEntry>>(
              value: production,
              onRetry: () => ref.invalidate(productionRecordsProvider(filter)),
              builder: (context, entries) => _ProductionSection(
                entries: entries,
                periodLabel: _periodLabel,
              ),
            ),

            _DispatchSection(from: _from),
            _WastageSection(from: _from),
            const _ClosingStockSection(),
          ],
        ),
      ),
    );
  }
}

class _PeriodPicker extends StatelessWidget {
  const _PeriodPicker({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (days, label) in const [
          (0, 'Today'),
          (7, '7 days'),
          (30, '30 days'),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: selected == days,
              onSelected: (_) => onSelect(days),
            ),
          ),
      ],
    );
  }
}

class _ProductionSection extends StatelessWidget {
  const _ProductionSection({required this.entries, required this.periodLabel});

  final List<ProductionEntry> entries;
  final String periodLabel;

  @override
  Widget build(BuildContext context) {
    final bundles = entries.fold<int>(0, (sum, e) => sum + e.bundleQuantity);
    final bags = entries.fold<int>(0, (sum, e) => sum + e.bagQuantity);
    final scrap =
        entries.fold<double>(0, (sum, e) => sum + e.wastageQuantity);
    final used =
        entries.fold<double>(0, (sum, e) => sum + (e.wastageUsedKg ?? 0));
    final usedEntries = entries.where((e) => e.wastageUsed).length;

    Map<String, int> groupBy(String Function(ProductionEntry) key) {
      final totals = <String, int>{};
      for (final entry in entries) {
        totals[key(entry)] = (totals[key(entry)] ?? 0) + entry.bundleQuantity;
      }
      return totals;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: 'Production · $periodLabel'),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Bundles produced',
                value: Fmt.count(bundles),
                icon: Icons.inventory_2_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Bags produced',
                value: Fmt.count(bags),
                icon: Icons.shopping_bag_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Wastage material used',
                value: Fmt.quantity(used),
                unit: 'kg',
                icon: Icons.recycling_outlined,
                tone: used > 0 ? AppTheme.good : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Scrap generated',
                value: Fmt.quantity(scrap),
                unit: 'kg',
                icon: Icons.delete_outline_rounded,
                tone: scrap > 0 ? AppTheme.low : null,
              ),
            ),
          ],
        ),
        if (entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              'Wastage material was used in $usedEntries of '
              '${entries.length} ${entries.length == 1 ? 'entry' : 'entries'}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No production in this period.'),
              ),
            ),
          )
        else ...[
          const SectionHeader(title: 'By shift'),
          _Breakdown(totals: groupBy((e) => e.shiftName), unit: 'bundles'),
          const SectionHeader(title: 'By machine'),
          _Breakdown(totals: groupBy((e) => e.machineName), unit: 'bundles'),
          const SectionHeader(title: 'By operator'),
          _Breakdown(totals: groupBy((e) => e.operatorName), unit: 'bundles'),
          const SectionHeader(title: 'By product'),
          _Breakdown(totals: groupBy((e) => e.product), unit: 'bundles'),
        ],
      ],
    );
  }
}

class _DispatchSection extends ConsumerWidget {
  const _DispatchSection({required this.from});

  final DateTime from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dispatches = ref.watch(dispatchesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Dispatch'),
        AsyncView<List<Dispatch>>(
          value: dispatches,
          onRetry: () => ref.invalidate(dispatchesProvider),
          builder: (context, rows) {
            final inPeriod = rows
                .where((d) => !d.date.isBefore(from))
                .toList(growable: false);
            final bundles =
                inPeriod.fold<int>(0, (sum, d) => sum + d.totalBundles);
            final bags = inPeriod.fold<int>(0, (sum, d) => sum + d.totalBags);

            final byCustomer = <String, int>{};
            for (final dispatch in inPeriod) {
              byCustomer[dispatch.customerName] =
                  (byCustomer[dispatch.customerName] ?? 0) +
                      dispatch.totalBundles;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'Bundles dispatched',
                        value: Fmt.count(bundles),
                        icon: Icons.local_shipping_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        label: 'Bags dispatched',
                        value: Fmt.count(bags),
                        icon: Icons.shopping_bag_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        label: 'Vehicles',
                        value: Fmt.count(inPeriod.length),
                        icon: Icons.receipt_long_outlined,
                      ),
                    ),
                  ],
                ),
                if (byCustomer.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Breakdown(totals: byCustomer, unit: 'bundles'),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _WastageSection extends ConsumerWidget {
  const _WastageSection({required this.from});

  final DateTime from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wastage = ref.watch(wastageEntriesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Wastage'),
        AsyncView<List<WastageEntry>>(
          value: wastage,
          onRetry: () => ref.invalidate(wastageEntriesProvider),
          builder: (context, rows) {
            final inPeriod =
                rows.where((w) => !w.entryDate.isBefore(from)).toList();

            double sum(bool Function(WastageEntry) test) => inPeriod
                .where(test)
                .fold<double>(0, (total, w) => total + w.quantity);

            return Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Material lost',
                    value: Fmt.quantity(
                        sum((w) => w.source == WastageSource.rawMaterialLoss)),
                    unit: 'kg',
                    icon: Icons.delete_outline_rounded,
                    tone: AppTheme.low,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatTile(
                    label: 'Recovered',
                    value: Fmt.quantity(sum((w) => w.reusable)),
                    unit: 'kg',
                    icon: Icons.recycling_outlined,
                    tone: AppTheme.good,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ClosingStockSection extends ConsumerWidget {
  const _ClosingStockSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final finished = ref.watch(finishedGoodsProvider);
    final materials = ref.watch(rawMaterialsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Closing stock'),
        AsyncView<List<RawMaterial>>(
          value: materials,
          onRetry: () => ref.invalidate(rawMaterialsProvider),
          builder: (context, rows) => Card(
            child: Column(
              children: [
                for (final (i, material) in rows.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  DataRow2(
                    label: material.name,
                    value: Fmt.qtyWithUnit(material.quantity, material.unit),
                    trailing: StatusChip(status: material.status),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        AsyncView<List<FinishedGoodsStock>>(
          value: finished,
          onRetry: () => ref.invalidate(finishedGoodsProvider),
          builder: (context, rows) {
            final total = rows.fold<int>(0, (sum, r) => sum + r.bundles);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatTile(
                  label: 'Finished goods on hand',
                  value: Fmt.count(total),
                  unit: 'bundles',
                  icon: Icons.warehouse_outlined,
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      for (final (i, item) in rows.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        DataRow2(
                          label: item.label,
                          value: Fmt.count(item.bundles),
                          trailing: StatusChip(status: item.status),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// A ranked breakdown with proportion bars. Rank plus share answers "who and
/// how much" faster than a table of numbers does.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.totals, required this.unit});

  final Map<String, int> totals;
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (totals.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing to report for this period.'),
        ),
      );
    }

    final entries = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = entries.first.value;

    return Card(
      child: Column(
        children: [
          for (final (i, entry) in entries.indexed) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(entry.key)),
                      Text(
                        '${Fmt.count(entry.value)} $unit',
                        style: AppTheme.numeric(context, size: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : entry.value / max,
                      minHeight: 6,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
