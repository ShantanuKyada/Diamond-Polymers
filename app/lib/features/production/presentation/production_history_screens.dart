import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../auth/domain/app_user.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/domain/masters.dart';
import '../data/production_repository.dart';
import '../domain/production.dart';

/// My Entries — the operator's own history (§29).
///
/// Read-only by design: an operator cannot edit a past entry, because a
/// correction has to be a new reversing movement rather than a quiet overwrite
/// of the record the stock balance was built from.
class MyEntriesScreen extends ConsumerWidget {
  const MyEntriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(myProductionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My Entries')),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(myProductionProvider.future),
        child: AsyncView<List<ProductionEntry>>(
          value: entries,
          onRetry: () => ref.invalidate(myProductionProvider),
          builder: (context, rows) {
            if (rows.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  EmptyView(
                    message: 'Nothing recorded in the last 7 days.\n'
                        'Entries you submit will appear here.',
                    icon: Icons.receipt_long_outlined,
                  ),
                ],
              );
            }

            return _GroupedEntryList(
              rows: rows,
              showOperator: false,
              oldestFirst: true,
              header: _WeekSummary(rows: rows),
            );
          },
        ),
      ),
    );
  }
}

/// Production Records — every entry in the factory, with filters (§49, §50).
class ProductionRecordsScreen extends ConsumerStatefulWidget {
  const ProductionRecordsScreen({super.key});

  @override
  ConsumerState<ProductionRecordsScreen> createState() =>
      _ProductionRecordsScreenState();
}

class _ProductionRecordsScreenState
    extends ConsumerState<ProductionRecordsScreen> {
  ProductionFilter _filter = const ProductionFilter();

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(productionRecordsProvider(_filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Production'),
        actions: [
          IconButton(
            tooltip: 'Filter',
            onPressed: _openFilters,
            icon: Badge(
              isLabelVisible: _filter.activeCount > 0,
              label: Text('${_filter.activeCount}'),
              child: const Icon(Icons.tune_rounded),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_filter.activeCount > 0)
            _ActiveFilterBar(
              filter: _filter,
              onClear: () => setState(() => _filter = const ProductionFilter()),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.refresh(productionRecordsProvider(_filter).future),
              child: AsyncView<List<ProductionEntry>>(
                value: entries,
                onRetry: () =>
                    ref.invalidate(productionRecordsProvider(_filter)),
                builder: (context, rows) {
                  if (rows.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 120),
                        EmptyView(
                          message: _filter.isEmpty
                              ? 'No production has been recorded yet.'
                              : 'No entries match these filters.',
                          icon: Icons.factory_outlined,
                          action: _filter.isEmpty
                              ? null
                              : OutlinedButton(
                                  onPressed: () => setState(
                                      () => _filter = const ProductionFilter()),
                                  child: const Text('Clear filters'),
                                ),
                        ),
                      ],
                    );
                  }

                  return _GroupedEntryList(rows: rows, showOperator: true);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openFilters() async {
    final machines = ref.read(machinesProvider).value ?? const <Machine>[];
    final staff = ref.read(staffProvider).value ?? const <StaffMember>[];
    final types = ref.read(pipeTypesProvider).value ?? const <PipeType>[];

    final result = await showModalBottomSheet<ProductionFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _FilterSheet(
        initial: _filter,
        machines: machines,
        operators: staff
            .where((s) => s.role == UserRole.operator.wire)
            .toList(),
        types: types,
      ),
    );

    if (result != null) setState(() => _filter = result);
  }
}

// -----------------------------------------------------------------------------

/// Entries grouped by day, with a per-day total. A flat list of thirty rows
/// tells you far less than "Today: 129 bundles" does.
class _GroupedEntryList extends StatelessWidget {
  const _GroupedEntryList({
    required this.rows,
    required this.showOperator,
    this.oldestFirst = false,
    this.header,
  });

  final List<ProductionEntry> rows;
  final bool showOperator;

  /// Chronological for an operator's own week (A32); newest first for the
  /// admin list, where the latest activity is what people look for.
  final bool oldestFirst;

  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final byDay = <DateTime, List<ProductionEntry>>{};
    for (final row in rows) {
      final day = DateTime(row.entryDate.year, row.entryDate.month, row.entryDate.day);
      byDay.putIfAbsent(day, () => []).add(row);
    }

    final days = byDay.keys.toList()
      ..sort((a, b) => oldestFirst ? a.compareTo(b) : b.compareTo(a));

    for (final entries in byDay.values) {
      entries.sort((a, b) => oldestFirst
          ? a.createdAt.compareTo(b.createdAt)
          : b.createdAt.compareTo(a.createdAt));
    }

    final offset = header == null ? 0 : 1;

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: days.length + offset,
      itemBuilder: (context, index) {
        if (index < offset) return header!;

        final day = days[index - offset];
        final entries = byDay[day]!;
        final bundles =
            entries.fold<int>(0, (sum, e) => sum + e.bundleQuantity);
        final bags = entries.fold<int>(0, (sum, e) => sum + e.bagQuantity);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '${Fmt.relativeDay(day)} · ${Fmt.weekday(day)}',
              trailing: Text(
                bags == 0
                    ? Fmt.bundles(bundles)
                    : '${Fmt.bundles(bundles)} · ${Fmt.bags(bags)}',
                style: AppTheme.numeric(context, size: 14),
              ),
            ),
            Card(
              child: Column(
                children: [
                  for (final (i, entry) in entries.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _EntryTile(entry: entry, showOperator: showOperator),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The week in three figures, above the day-by-day list.
class _WeekSummary extends StatelessWidget {
  const _WeekSummary({required this.rows});

  final List<ProductionEntry> rows;

  @override
  Widget build(BuildContext context) {
    final bundles = rows.fold<int>(0, (sum, e) => sum + e.bundleQuantity);
    final bags = rows.fold<int>(0, (sum, e) => sum + e.bagQuantity);
    final used = rows.fold<double>(0, (sum, e) => sum + (e.wastageUsedKg ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
          child: Text(
            'Your last $myEntriesDays days · ${rows.length} '
            '${rows.length == 1 ? 'entry' : 'entries'}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Bundles',
                value: Fmt.count(bundles),
                icon: Icons.inventory_2_outlined,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                label: 'Bags',
                value: Fmt.count(bags),
                icon: Icons.shopping_bag_outlined,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                label: 'Wastage used',
                value: Fmt.quantity(used),
                unit: 'kg',
                icon: Icons.recycling_outlined,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.showOperator});

  final ProductionEntry entry;
  final bool showOperator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final context2 = [
      entry.machineName,
      entry.shiftName,
      if (showOperator) entry.operatorName,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.product,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  context2,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _Tag(
                      icon: Icons.recycling_outlined,
                      text: entry.wastageUsed
                          ? 'Wastage used ${Fmt.quantity(entry.wastageUsedKg)} kg'
                          : 'No wastage used',
                      color: entry.wastageUsed
                          ? AppTheme.good
                          : scheme.onSurfaceVariant,
                    ),
                    if (entry.wastageQuantity > 0)
                      _Tag(
                        icon: Icons.delete_outline_rounded,
                        text: '${Fmt.quantity(entry.wastageQuantity)} kg scrap',
                        color: AppTheme.low,
                      ),
                  ],
                ),
                if (entry.remarks != null && entry.remarks!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.remarks!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Quantity(value: entry.bundleQuantity, unit: 'bundles'),
              if (entry.bagQuantity > 0) ...[
                const SizedBox(height: 4),
                _Quantity(value: entry.bagQuantity, unit: 'bags'),
              ],
              const SizedBox(height: 4),
              Text(
                Fmt.time(entry.createdAt.toLocal()),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Quantity extends StatelessWidget {
  const _Quantity({required this.value, required this.unit});

  final int value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        text: Fmt.count(value),
        style: AppTheme.numeric(context, size: 17),
        children: [
          TextSpan(
            text: ' $unit',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _ActiveFilterBar extends StatelessWidget {
  const _ActiveFilterBar({required this.filter, required this.onClear});

  final ProductionFilter filter;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.primaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.filter_alt_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${filter.activeCount} filter'
              '${filter.activeCount == 1 ? '' : 's'} applied',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.machines,
    required this.operators,
    required this.types,
  });

  final ProductionFilter initial;
  final List<Machine> machines;
  final List<StaffMember> operators;
  final List<PipeType> types;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late ProductionFilter _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Filter production',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),

            const SectionHeader(title: 'Period'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _period('Any time', null),
                _period('Today', 0),
                _period('Last 7 days', 7),
                _period('Last 30 days', 30),
              ],
            ),

            const SectionHeader(title: 'Machine'),
            _chips(
              options: [for (final m in widget.machines) (m.id, m.name)],
              selected: _draft.machineId,
              onSelect: (id) => setState(() => _draft = id == null
                  ? _draft.copyWith(clearMachine: true)
                  : _draft.copyWith(machineId: id)),
            ),

            const SectionHeader(title: 'Operator'),
            _chips(
              options: [for (final o in widget.operators) (o.id, o.name)],
              selected: _draft.operatorId,
              onSelect: (id) => setState(() => _draft = id == null
                  ? _draft.copyWith(clearOperator: true)
                  : _draft.copyWith(operatorId: id)),
            ),

            const SectionHeader(title: 'Pipe type'),
            _chips(
              options: [for (final t in widget.types) (t.id, t.name)],
              selected: _draft.pipeTypeId,
              onSelect: (id) => setState(() => _draft = id == null
                  ? _draft.copyWith(clearType: true)
                  : _draft.copyWith(pipeTypeId: id)),
            ),

            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context)
                        .pop(const ProductionFilter()),
                    child: const Text('Clear all'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _period(String label, int? days) {
    final active = days == null
        ? _draft.from == null
        : _draft.from != null &&
            _draft.from!.difference(DateTime.now()).inDays.abs() == days;

    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => setState(() {
        if (days == null) {
          _draft = _draft.copyWith(clearDates: true);
        } else {
          final now = DateTime.now();
          _draft = _draft.copyWith(
            from: DateTime(now.year, now.month, now.day)
                .subtract(Duration(days: days)),
            to: now,
          );
        }
      }),
    );
  }

  Widget _chips({
    required List<(String, String)> options,
    required String? selected,
    required ValueChanged<String?> onSelect,
  }) {
    if (options.isEmpty) {
      return Text('Nothing configured.',
          style: Theme.of(context).textTheme.bodySmall);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: const Text('Any'),
          selected: selected == null,
          onSelected: (_) => onSelect(null),
        ),
        for (final (id, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: selected == id,
            onSelected: (_) => onSelect(id),
          ),
      ],
    );
  }
}
