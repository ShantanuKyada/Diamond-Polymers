import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../dashboard/domain/dashboard_models.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/domain/masters.dart';
import '../../masters/presentation/widgets/master_scaffold.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';

/// Inventory (§13, §30, Phase 3).
///
/// Three tabs because there are three genuinely different inventories, not one
/// with a filter: raw material in kilograms, finished goods in bundles, and
/// regrind, which is raw material that used to be finished goods.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Inventory'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Raw material'),
              Tab(text: 'Finished goods'),
              Tab(text: 'Regrind'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => invalidateStock(ref),
            ),
          ],
        ),
        body: const TabBarView(
          children: [
            _RawMaterialTab(),
            _FinishedGoodsTab(),
            _RegrindTab(),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Raw material
// =============================================================================

class _RawMaterialTab extends ConsumerWidget {
  const _RawMaterialTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final materials = ref.watch(rawMaterialsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(rawMaterialsProvider),
      child: AsyncView<List<RawMaterial>>(
        value: materials,
        onRetry: () => ref.invalidate(rawMaterialsProvider),
        builder: (context, rows) {
          if (rows.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 100),
                EmptyView(
                  message: 'No raw materials configured.',
                  icon: Icons.science_outlined,
                ),
              ],
            );
          }

          // Virgin first, regrind after: they are read differently, and mixing
          // them in one alphabetical list hides the split that matters.
          final virgin = rows.where((m) => !m.isRecycled).toList();
          final regrind = rows.where((m) => m.isRecycled).toList();

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final material in virgin)
                _MaterialTile(
                  material: material,
                  onStockIn: () => _movement(context, ref, material, stockIn: true),
                  onAdjust: () => _movement(context, ref, material, stockIn: false),
                ),
              if (regrind.isNotEmpty) ...[
                const SectionHeader(title: 'Regrind'),
                for (final material in regrind)
                  _MaterialTile(
                    material: material,
                    onStockIn: () =>
                        _movement(context, ref, material, stockIn: true),
                    onAdjust: () =>
                        _movement(context, ref, material, stockIn: false),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _movement(
    BuildContext context,
    WidgetRef ref,
    RawMaterial material, {
    required bool stockIn,
  }) async {
    final quantity = TextEditingController();
    final remarks = TextEditingController();
    // One reference per submission attempt, reused on retry: that is what makes
    // a double tap or a timeout-then-retry post the stock once (§47).
    final clientRef = const Uuid().v4();

    final saved = await showEditSheet(
      context: context,
      title: stockIn ? 'Stock in — ${material.name}' : 'Adjust ${material.name}',
      saveLabel: stockIn ? 'Add to stock' : 'Post adjustment',
      fields: (rebuild) => [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'In stock now: '
            '${Fmt.qtyWithUnit(material.quantity, material.unit)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        SheetField(
          controller: quantity,
          label: stockIn
              ? 'Quantity received (${material.unit})'
              : 'Adjustment (${material.unit})',
          required: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          helper: stockIn
              ? 'Goods received. Corrections go through Adjust instead, so the '
                  'ledger keeps them apart.'
              : 'Signed. Use a minus sign to reduce stock. The balance still '
                  'cannot go below zero — the movement is refused, not clamped.',
          validator: (value) {
            final parsed = double.tryParse((value ?? '').trim());
            if (parsed == null) return 'Enter a number';
            if (stockIn && parsed <= 0) return 'Must be greater than zero';
            if (!stockIn && parsed == 0) return 'An adjustment cannot be zero';
            return null;
          },
        ),
        SheetField(
          controller: remarks,
          label: 'Remarks',
          maxLines: 2,
          helper: stockIn
              ? 'Supplier, invoice number — whatever makes this traceable later.'
              : 'Why the correction was needed. This is kept on the ledger row.',
        ),
      ],
      onSave: () async {
        final amount = double.parse(quantity.text.trim());
        final repository = ref.read(inventoryRepositoryProvider);
        if (stockIn) {
          await repository.stockIn(
            rawMaterialId: material.id,
            quantity: amount,
            clientRef: clientRef,
            remarks: remarks.text.trim().isEmpty ? null : remarks.text.trim(),
          );
        } else {
          await repository.adjust(
            rawMaterialId: material.id,
            delta: amount,
            clientRef: clientRef,
            remarks: remarks.text.trim().isEmpty ? null : remarks.text.trim(),
          );
        }
      },
    );

    if (saved) {
      invalidateStock(ref);
      if (context.mounted) {
        showMessage(context, stockIn ? 'Stock added' : 'Adjustment posted');
      }
    }
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({
    required this.material,
    required this.onStockIn,
    required this.onAdjust,
  });

  final RawMaterial material;
  final VoidCallback onStockIn;
  final VoidCallback onAdjust;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      title: Row(
        children: [
          Expanded(child: Text(material.name)),
          StatusChip(status: material.status),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Fmt.qtyWithUnit(material.quantity, material.unit),
                    style: AppTheme.numeric(context, size: 22),
                  ),
                  Text(
                    material.minimumStock == 0
                        ? '${material.code} · no reorder level'
                        : '${material.code} · reorder at '
                            '${Fmt.qtyWithUnit(material.minimumStock, material.unit)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onStockIn, child: const Text('Stock in')),
            TextButton(onPressed: onAdjust, child: const Text('Adjust')),
          ],
        ),
      ),
      isThreeLine: true,
    );
  }
}

// =============================================================================
// Finished goods
// =============================================================================

class _FinishedGoodsTab extends ConsumerWidget {
  const _FinishedGoodsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stock = ref.watch(finishedGoodsProvider);
    // Weights come from the product catalogue, so bundles can also be shown in
    // kilograms. A pair with no product has no weight, which is itself worth
    // saying: production of it would be refused.
    final products = ref.watch(productsProvider).value ?? const <PipeProduct>[];
    final weights = {
      for (final p in products) '${p.pipeTypeId}|${p.pipeSizeId}': p.bundleWeightKg,
    };
    final bagged = {
      for (final p in products)
        if (p.hasBagPacking) '${p.pipeTypeId}|${p.pipeSizeId}',
    };

    return RefreshIndicator(
      onRefresh: () async => invalidateStock(ref),
      child: AsyncView<List<FinishedGoodsStock>>(
        value: stock,
        onRetry: () => ref.invalidate(finishedGoodsProvider),
        builder: (context, rows) {
          if (rows.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 100),
                EmptyView(
                  message: 'No pipe types and sizes configured yet.',
                  icon: Icons.category_outlined,
                ),
              ],
            );
          }

          return ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = rows[index];
              return _FinishedGoodsTile(
                row: row,
                bundleWeightKg: weights[row.productKey],
                packedInBags: bagged.contains(row.productKey),
              );
            },
          );
        },
      ),
    );
  }
}

class _FinishedGoodsTile extends StatelessWidget {
  const _FinishedGoodsTile({
    required this.row,
    required this.bundleWeightKg,
    this.packedInBags = false,
  });

  final FinishedGoodsStock row;
  final double? bundleWeightKg;

  /// Bags are a separate balance (A25), shown only where the product is packed
  /// in bags or bag stock exists.
  final bool packedInBags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Row(
        children: [
          Expanded(child: Text(row.label)),
          StatusChip(status: row.status),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              Fmt.count(row.bundles),
              style: AppTheme.numeric(context, size: 22),
            ),
            const SizedBox(width: 4),
            Text('bundles', style: Theme.of(context).textTheme.bodySmall),
            if (packedInBags || row.bags > 0) ...[
              const SizedBox(width: 12),
              Text(
                Fmt.count(row.bags),
                style: AppTheme.numeric(context, size: 22),
              ),
              const SizedBox(width: 4),
              Text('bags', style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                bundleWeightKg == null
                    // Actionable, not decorative: this pair cannot be produced.
                    ? 'No bundle weight set'
                    : '≈ ${Fmt.quantity(row.bundles * bundleWeightKg!)} kg',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: bundleWeightKg == null
                          ? AppTheme.low
                          : scheme.onSurfaceVariant,
                    ),
              ),
            ),
            if (row.minimumStock > 0)
              Text(
                'min ${Fmt.count(row.minimumStock)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Regrind
// =============================================================================

class _RegrindTab extends ConsumerWidget {
  const _RegrindTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stock = ref.watch(recycledStockProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(recycledStockProvider),
      child: AsyncView<List<RecycledStock>>(
        value: stock,
        onRetry: () => ref.invalidate(recycledStockProvider),
        builder: (context, rows) {
          if (rows.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 100),
                EmptyView(
                  message: 'No regrind pools configured. Mark a raw material '
                      'as RECYCLED to create one.',
                  icon: Icons.recycling_outlined,
                ),
              ],
            );
          }

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const _RegrindNote(),
              for (final pool in rows)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pool.name,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _Figure(
                              label: 'On hand',
                              value: Fmt.quantity(pool.quantity),
                              unit: pool.unit,
                              tone: AppTheme.good,
                            ),
                            _Figure(
                              label: 'Recovered',
                              value: Fmt.quantity(pool.totalRecovered),
                              unit: pool.unit,
                            ),
                            _Figure(
                              label: 'Fed back in',
                              value: Fmt.quantity(pool.totalConsumed),
                              unit: pool.unit,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RegrindNote extends StatelessWidget {
  const _RegrindNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        'Regrind is ordinary raw material: shredded pipe returns here in '
        'kilograms and is mixed back in like anything else. "Recovered" is what '
        'the shredder has produced; "fed back in" is what mixtures have since '
        'consumed.',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.unit,
    this.tone,
  });

  final String label;
  final String value;
  final String unit;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              text: value,
              style: AppTheme.numeric(context, size: 18)
                  .copyWith(color: tone ?? scheme.onSurface),
              children: [
                TextSpan(
                  text: ' $unit',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
