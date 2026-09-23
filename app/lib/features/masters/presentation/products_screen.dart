import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// Products — the Type → Size → Packaging master (A21, A24).
///
/// Each row is one size configured under one pipe type, with its bundle weight
/// and how many pipes make a bundle and a bag. Rows are grouped by type so the
/// screen reads as the hierarchy it represents.
///
/// This is the most consequential screen in the master data. `bundle_weight_kg`
/// is the only bridge between the kilograms that go into a machine and the
/// bundles that come out: without it "we consumed 900 kg and made 30 bundles"
/// is not a statement anyone can check, and production of the product is
/// refused outright (DP008).
///
/// Changing a weight does not re-value history — entries snapshot the weight
/// they were recorded against — but it does change every future entry, so the
/// form says so before saving.
class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Grouped by type, then by size within it.
    final products = ref.watch(productsProvider).whenData((rows) {
      final sorted = [...rows]..sort((a, b) {
          final byType = a.pipeTypeName.compareTo(b.pipeTypeName);
          return byType != 0 ? byType : a.pipeSizeName.compareTo(b.pipeSizeName);
        });
      return sorted;
    });

    final firstOfType = <String>{};
    final seenTypes = <String>{};
    for (final product in products.value ?? const <PipeProduct>[]) {
      if (seenTypes.add(product.pipeTypeId)) firstOfType.add(product.id);
    }

    return MasterScaffold<PipeProduct>(
      title: 'Products & Packaging',
      subtitle: 'Pipe type → size → pipes per bundle and bag',
      items: products,
      addLabel: 'Product',
      emptyMessage: 'No products configured. Production cannot be recorded '
          'until at least one has a bundle weight.',
      emptyIcon: Icons.category_outlined,
      onRefresh: () => ref.invalidate(productsProvider),
      onAdd: () => _edit(context, ref, null),
      header: const _WeightNote(),
      itemBuilder: (context, product) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (firstOfType.contains(product.id))
            _TypeHeader(name: product.pipeTypeName),
          _ProductTile(
            product: product,
            onEdit: () => _edit(context, ref, product),
            onThreshold: () => _threshold(context, ref, product),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    PipeProduct? existing,
  ) async {
    final types = ref.read(pipeTypesProvider).value ?? const <PipeType>[];
    final sizes = ref.read(pipeSizesProvider).value ?? const <PipeSize>[];

    if (types.isEmpty || sizes.isEmpty) {
      showMessage(
        context,
        'Add at least one pipe type and one size first.',
        error: true,
      );
      return;
    }

    final sku = TextEditingController(text: existing?.sku ?? '');
    final weight = TextEditingController(
      text: existing == null ? '' : Fmt.quantity(existing.bundleWeightKg),
    );
    final perBundle = TextEditingController(
      text: existing?.pipesPerBundle?.toString() ?? '',
    );
    final perBag = TextEditingController(
      text: existing?.pipesPerBag?.toString() ?? '',
    );
    var typeId = existing?.pipeTypeId;
    var sizeId = existing?.pipeSizeId;
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add product' : 'Edit ${existing.sku}',
      fields: (rebuild) => [
        // The pair is the product's identity and is what every stock row is
        // keyed by, so it cannot move once bundles exist against it.
        SheetDropdown<String>(
          label: 'Pipe type',
          value: typeId,
          required: true,
          items: [
            for (final t in types.where((t) => t.active))
              DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: existing != null
              ? (_) {}
              : (value) {
                  typeId = value;
                  rebuild();
                },
        ),
        SheetDropdown<String>(
          label: 'Pipe size',
          value: sizeId,
          required: true,
          helper: existing != null
              ? 'Type and size identify the product and cannot be changed. '
                  'Create a new product instead.'
              : null,
          items: [
            for (final s in sizes.where((s) => s.active))
              DropdownMenuItem(
                value: s.id,
                child: Text(s.diameterMm == null
                    ? s.name
                    : '${s.name} · ${Fmt.quantity(s.diameterMm)} mm'),
              ),
          ],
          onChanged: existing != null
              ? (_) {}
              : (value) {
                  sizeId = value;
                  rebuild();
                },
        ),
        SheetField(
          controller: sku,
          label: 'Product code',
          hint: 'TA-S1',
          required: true,
        ),
        SheetField(
          controller: weight,
          label: 'Bundle weight (kg)',
          hint: '18.5',
          required: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          helper: existing == null
              ? 'How many kilograms one bundle of this product weighs.'
              : 'Changing this affects future entries only. Everything already '
                  'recorded keeps the weight it was made at.',
          validator: (value) {
            final parsed = double.tryParse((value ?? '').trim());
            if (parsed == null) return 'Enter a number';
            if (parsed <= 0) return 'Must be greater than zero';
            return null;
          },
        ),
        SheetField(
          controller: perBundle,
          label: 'Pipes per bundle',
          hint: '5',
          keyboardType: TextInputType.number,
          helper: 'How many pipes make one bundle. Needed before this product '
              'can be packed in bags.',
          validator: (value) {
            final text = (value ?? '').trim();
            if (text.isEmpty) {
              return perBag.text.trim().isEmpty
                  ? null
                  : 'Needed when pipes per bag is set';
            }
            final parsed = int.tryParse(text);
            if (parsed == null || parsed <= 0) return 'Enter a whole number';
            return null;
          },
        ),
        SheetField(
          controller: perBag,
          label: 'Pipes per bag',
          hint: '16',
          keyboardType: TextInputType.number,
          helper: 'How many pipes make one bag. Leave blank if this product is '
              'only sold in bundles.',
          validator: (value) {
            final text = (value ?? '').trim();
            if (text.isEmpty) return null;
            final parsed = int.tryParse(text);
            if (parsed == null || parsed <= 0) return 'Enter a whole number';
            return null;
          },
        ),
        SwitchListTile(
          value: active,
          onChanged: (value) {
            active = value;
            rebuild();
          },
          title: const Text('In production'),
          subtitle: const Text('Discontinued products stay in stock reports.'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveProduct(
            pipeTypeId: typeId!,
            pipeSizeId: sizeId!,
            sku: sku.text,
            bundleWeightKg: double.parse(weight.text.trim()),
            pipesPerBundle: int.tryParse(perBundle.text.trim()),
            pipesPerBag: int.tryParse(perBag.text.trim()),
            active: active,
          ),
    );

    if (saved) {
      ref.invalidate(productsProvider);
      if (context.mounted) {
        showMessage(context, existing == null ? 'Product added' : 'Saved');
      }
    }
  }

  Future<void> _threshold(
    BuildContext context,
    WidgetRef ref,
    PipeProduct product,
  ) async {
    final minimum =
        TextEditingController(text: product.minimumStock.toString());

    final saved = await showEditSheet(
      context: context,
      title: '${product.label} — reorder level',
      fields: (rebuild) => [
        SheetField(
          controller: minimum,
          label: 'Low-stock threshold (bundles)',
          required: true,
          keyboardType: TextInputType.number,
          helper: 'Administrators are alerted when stock falls to or below '
              'this. Zero disables the alert.',
          validator: (value) {
            final parsed = int.tryParse((value ?? '').trim());
            if (parsed == null) return 'Enter a whole number';
            if (parsed < 0) return 'Cannot be negative';
            return null;
          },
        ),
      ],
      onSave: () =>
          ref.read(mastersRepositoryProvider).setFinishedGoodsThreshold(
                pipeTypeId: product.pipeTypeId,
                pipeSizeId: product.pipeSizeId,
                minimumStock: int.parse(minimum.text.trim()),
              ),
    );

    if (saved) {
      ref.invalidate(productsProvider);
      if (context.mounted) showMessage(context, 'Reorder level updated');
    }
  }
}

class _WeightNote extends StatelessWidget {
  const _WeightNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.scale_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Bundle weight converts kilograms of material into bundles. '
              'Pipes per bundle and per bag define the packaging: a product '
              'can be produced and dispatched in bags only once both are set.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.onEdit,
    required this.onThreshold,
  });

  final PipeProduct product;
  final VoidCallback onEdit;
  final VoidCallback onThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      title: Row(
        children: [
          Expanded(child: Text(product.label)),
          StatusChip(status: product.status),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  product.sku,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                if (product.diameterMm != null) ...[
                  const SizedBox(width: 8),
                  Text('⌀ ${Fmt.quantity(product.diameterMm)} mm',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
                if (!product.active) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Discontinued',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // The packaging mapping (A24).
            Row(
              children: [
                _Figure(
                  label: '1 bundle',
                  value: product.pipesPerBundle == null
                      ? 'Not set'
                      : '${product.pipesPerBundle}',
                  suffix: product.pipesPerBundle == null ? null : 'pipes',
                  tone: product.pipesPerBundle == null
                      ? scheme.onSurfaceVariant
                      : scheme.primary,
                ),
                _Figure(
                  label: '1 bag',
                  value: product.hasBagPacking
                      ? '${product.pipesPerBag}'
                      : 'Not bagged',
                  suffix: product.hasBagPacking ? 'pipes' : null,
                  tone: product.hasBagPacking
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                _Figure(
                  label: 'Bundle weight',
                  value: '${Fmt.quantity(product.bundleWeightKg)} kg',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _Figure(
                  label: 'Bundles',
                  value: Fmt.count(product.quantityBundles),
                ),
                _Figure(
                  label: 'Bags',
                  value: Fmt.count(product.quantityBags),
                ),
                _Figure(
                  label: 'Weight',
                  value: Fmt.quantity(product.stockWeightKg),
                  suffix: 'kg',
                ),
                _Figure(
                  label: 'Reorder at',
                  value: product.minimumStock == 0
                      ? '—'
                      : Fmt.count(product.minimumStock),
                  tone: product.minimumStock == 0
                      ? scheme.onSurfaceVariant
                      : AppTheme.low,
                ),
              ],
            ),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) =>
            value == 'edit' ? onEdit() : onThreshold(),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit product')),
          PopupMenuItem(value: 'threshold', child: Text('Reorder level')),
        ],
      ),
      onTap: onEdit,
      isThreeLine: true,
    );
  }
}

class _TypeHeader extends StatelessWidget {
  const _TypeHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Icon(Icons.category_outlined, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            name,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    this.suffix,
    this.tone,
  });

  final String label;
  final String value;
  final String? suffix;
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
              style: AppTheme.numeric(context, size: 14)
                  .copyWith(color: tone ?? scheme.onSurface),
              children: [
                if (suffix != null)
                  TextSpan(
                    text: ' $suffix',
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
