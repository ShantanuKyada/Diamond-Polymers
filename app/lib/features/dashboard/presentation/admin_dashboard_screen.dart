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
import '../data/dashboard_repository.dart';
import '../domain/dashboard_models.dart';

/// "What is happening in the factory today?" (§27)
class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(adminDashboardProvider);
    final user = ref.watch(currentUserProvider);
    final factoryName = ref.watch(factoryNameProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Dashboard'),
            Text(
              factoryName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => context.pushNamed(AppRoute.notifications.name),
            icon: Badge(
              isLabelVisible: (snapshot.value?.unreadNotifications ?? 0) > 0,
              label: Text('${snapshot.value?.unreadNotifications ?? 0}'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(adminDashboardProvider.future),
        child: AsyncView<AdminDashboard>(
          value: snapshot,
          onRetry: () => ref.invalidate(adminDashboardProvider),
          loadingLabel: 'Loading factory data…',
          builder: (context, data) => _Content(
            data: data,
            greeting: user?.name,
            unit: ref.watch(wastageUnitProvider),
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.data, required this.unit, this.greeting});

  final AdminDashboard data;
  final String? greeting;

  /// The factory's wastage unit (A7), not a literal.
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          greeting == null ? 'Today' : 'Welcome, $greeting',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        Text(
          Fmt.date(data.date),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),

        if (data.alerts.isNotEmpty) ...[
          const SectionHeader(title: 'Alerts'),
          Card(
            child: Column(
              children: [
                for (final (index, alert) in data.alerts.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.warning_amber_rounded,
                      color: AppTheme.low,
                    ),
                    title: Text(alert, style: theme.textTheme.bodyMedium),
                    dense: true,
                  ),
                ],
              ],
            ),
          ),
        ],

        // ---- Today's production ------------------------------------------
        const SectionHeader(title: "Today's production"),
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
                label: 'Production entries',
                value: Fmt.count(data.entryCount),
                icon: Icons.checklist_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Dispatched today',
                value: Fmt.count(data.dispatchBundlesToday),
                unit: 'bundles',
                icon: Icons.local_shipping_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Finished goods',
                value: Fmt.count(data.finishedGoodsTotal),
                unit: 'bundles',
                icon: Icons.warehouse_outlined,
              ),
            ),
          ],
        ),

        if (data.productionByMachine.isNotEmpty) ...[
          const SectionHeader(title: 'Production by machine'),
          _BreakdownCard(
            rows: data.productionByMachine,
            suffix: 'bundles',
          ),
        ],

        if (data.productionByType.isNotEmpty) ...[
          const SectionHeader(title: 'Production by pipe type'),
          _BreakdownCard(rows: data.productionByType, suffix: 'bundles'),
        ],

        if (data.productionBySize.isNotEmpty) ...[
          const SectionHeader(title: 'Production by size'),
          _BreakdownCard(rows: data.productionBySize, suffix: 'bundles'),
        ],

        // ---- Raw material -------------------------------------------------
        const SectionHeader(title: 'Raw material stock'),
        Card(
          child: Column(
            children: [
              for (final (index, material) in data.rawMaterials.indexed) ...[
                if (index > 0) const Divider(height: 1),
                DataRow2(
                  label: material.name,
                  caption: 'Minimum '
                      '${Fmt.qtyWithUnit(material.minimumStock, material.unit)}',
                  value: Fmt.qtyWithUnit(material.quantity, material.unit),
                  trailing: StatusChip(status: material.status),
                ),
              ],
              if (data.rawMaterials.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No raw materials configured yet.'),
                ),
            ],
          ),
        ),

        if (data.consumptionToday.isNotEmpty) ...[
          const SectionHeader(title: "Today's consumption"),
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

        // ---- Finished goods ------------------------------------------------
        const SectionHeader(title: 'Finished goods stock'),
        Card(
          child: Column(
            children: [
              for (final (index, item) in data.finishedGoods.indexed) ...[
                if (index > 0) const Divider(height: 1),
                DataRow2(
                  label: item.label,
                  value: Fmt.count(item.bundles),
                  caption: 'Minimum ${item.minimumStock} bundles',
                  trailing: StatusChip(status: item.status),
                ),
              ],
              if (data.finishedGoods.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No finished goods configured yet.'),
                ),
            ],
          ),
        ),

        // ---- Wastage --------------------------------------------------------
        const SectionHeader(title: "Today's wastage"),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Material loss',
                value: Fmt.quantity(data.rawWastageToday),
                unit: unit,
                icon: Icons.delete_outline_rounded,
                tone: data.rawWastageToday > 0 ? AppTheme.low : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Reusable collected',
                value: Fmt.quantity(data.reusableCollectedToday),
                unit: unit,
                icon: Icons.recycling_outlined,
                tone: AppTheme.good,
              ),
            ),
          ],
        ),

        // ---- Machines --------------------------------------------------------
        const SectionHeader(title: 'Machines'),
        Card(
          child: Column(
            children: [
              for (final (index, machine) in data.machines.indexed) ...[
                if (index > 0) const Divider(height: 1),
                ListTile(
                  title: Text(machine.name),
                  subtitle: Text(
                    machine.operators.isEmpty
                        ? 'No operator assigned'
                        : machine.operators.join(', '),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        Fmt.count(machine.bundlesToday),
                        style: AppTheme.numeric(context, size: 16),
                      ),
                      const SizedBox(height: 2),
                      StatusChip(status: machine.status),
                    ],
                  ),
                ),
              ],
              if (data.machines.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No machines configured yet.'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.rows, required this.suffix});

  final List<NamedCount> rows;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (sum, row) => sum + row.value);

    return Card(
      child: Column(
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(row.name)),
                      Text(
                        '${Fmt.count(row.value)} $suffix',
                        style: AppTheme.numeric(context, size: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // A proportion bar communicates share at a glance without
                  // pulling in a charting library for four rows (§27).
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : row.value / total,
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
