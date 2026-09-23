import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../../core/widgets/state_views.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/domain/masters.dart';
import '../data/dispatch_repository.dart';

/// Dispatch history, and the entry point for recording a new one (§22).
class DispatchScreen extends ConsumerWidget {
  const DispatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dispatches = ref.watch(dispatchesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Dispatch')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const NewDispatchScreen()),
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New dispatch'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(dispatchesProvider.future),
        child: AsyncView<List<Dispatch>>(
          value: dispatches,
          onRetry: () => ref.invalidate(dispatchesProvider),
          builder: (context, rows) {
            if (rows.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  EmptyView(
                    message: 'No dispatches recorded yet.\n'
                        'Deliveries you record will be listed here.',
                    icon: Icons.local_shipping_outlined,
                  ),
                ],
              );
            }

            final todayIso = Fmt.isoDate(DateTime.now());
            final today =
                rows.where((d) => Fmt.isoDate(d.date) == todayIso).toList();
            final bundles = today.fold<int>(0, (sum, d) => sum + d.totalBundles);
            final bags = today.fold<int>(0, (sum, d) => sum + d.totalBags);

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'Bundles today',
                        value: Fmt.count(bundles),
                        icon: Icons.inventory_2_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'Bags today',
                        value: Fmt.count(bags),
                        icon: Icons.shopping_bag_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'Vehicles',
                        value: Fmt.count(today.length),
                        icon: Icons.local_shipping_outlined,
                      ),
                    ),
                  ],
                ),
                const SectionHeader(title: 'History'),
                for (final dispatch in rows) ...[
                  _DispatchCard(dispatch: dispatch),
                  const SizedBox(height: 12),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// "20 bundles · 10 bags", leaving out whichever is zero.
String _packed(int bundles, int bags) {
  final parts = [
    if (bundles > 0) Fmt.bundles(bundles),
    if (bags > 0) Fmt.bags(bags),
  ];
  return parts.isEmpty ? '—' : parts.join(' · ');
}

class _DispatchCard extends StatelessWidget {
  const _DispatchCard({required this.dispatch});

  final Dispatch dispatch;

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dispatch.customerName,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          Fmt.relativeDay(dispatch.date),
                          if (dispatch.reference?.isNotEmpty ?? false)
                            dispatch.reference!,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (dispatch.vehicleNumber?.isNotEmpty ?? false)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outline),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.local_shipping_outlined,
                            size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          dispatch.vehicleNumber!,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const Divider(height: 22),
            for (final line in dispatch.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 6, color: scheme.outline),
                    const SizedBox(width: 10),
                    Expanded(child: Text(line.product)),
                    Text(
                      _packed(line.bundleQuantity, line.bagQuantity),
                      style: AppTheme.numeric(context, size: 14),
                    ),
                  ],
                ),
              ),
            if (dispatch.lines.length > 1) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Total ${_packed(dispatch.totalBundles, dispatch.totalBags)}',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
            if (dispatch.remarks?.isNotEmpty ?? false) ...[
              const SizedBox(height: 10),
              Text(
                dispatch.remarks!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================

/// Recording a dispatch (§22, A25).
///
/// Every product shows both balances beside its two inputs, so a consignment
/// that cannot be filled is obvious before it is submitted. Bags are offered
/// only for products packed in bags.
class NewDispatchScreen extends ConsumerStatefulWidget {
  const NewDispatchScreen({super.key});

  @override
  ConsumerState<NewDispatchScreen> createState() => _NewDispatchScreenState();
}

class _NewDispatchScreenState extends ConsumerState<NewDispatchScreen> {
  final _formKey = GlobalKey<FormState>();
  final _buyer = TextEditingController();
  final _vehicle = TextEditingController();
  final _reference = TextEditingController();
  final _remarks = TextEditingController();
  final _bundles = <String, TextEditingController>{};
  final _bags = <String, TextEditingController>{};

  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;
  String? _attemptRef;

  @override
  void initState() {
    super.initState();
    _buyer.addListener(() => setState(() {}));
    _vehicle.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final controller in [
      _buyer,
      _vehicle,
      _reference,
      _remarks,
      ..._bundles.values,
      ..._bags.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(
      Map<String, TextEditingController> into, String key) {
    return into.putIfAbsent(key, () {
      final controller = TextEditingController();
      controller.addListener(() => setState(() {}));
      return controller;
    });
  }

  static int _read(TextEditingController? c) =>
      int.tryParse(c?.text.trim() ?? '') ?? 0;

  List<DispatchLine> _lines(List<PipeProduct> products) => [
        for (final p in products)
          if (_read(_bundles[p.id]) + _read(_bags[p.id]) > 0)
            DispatchLine(
              pipeTypeId: p.pipeTypeId,
              pipeSizeId: p.pipeSizeId,
              pipeTypeName: p.pipeTypeName,
              pipeSizeName: p.pipeSizeName,
              bundleQuantity: _read(_bundles[p.id]),
              bagQuantity: _read(_bags[p.id]),
            ),
      ];

  bool _overdrawn(List<PipeProduct> products) => products.any((p) =>
      _read(_bundles[p.id]) > p.quantityBundles ||
      _read(_bags[p.id]) > p.quantityBags);

  static String? _vehicleProblem(String value) {
    final v = normaliseVehicle(value);
    if (v.isEmpty) return 'Enter the vehicle number';
    if (!RegExp(r'^[A-Z0-9]{4,15}$').hasMatch(v)) {
      return 'Letters and numbers only, e.g. GJ01AB1234';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('New Dispatch')),
      body: AsyncView<List<PipeProduct>>(
        value: products,
        onRetry: () => ref.invalidate(productsProvider),
        builder: (context, all) {
          final stocked = all
              .where((p) => p.quantityBundles > 0 || p.quantityBags > 0)
              .toList(growable: false);
          final lines = _lines(all);
          final overdrawn = _overdrawn(all);
          final ready = lines.isNotEmpty &&
              !overdrawn &&
              _buyer.text.trim().isNotEmpty &&
              _vehicleProblem(_vehicle.text) == null;

          return Form(
            key: _formKey,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      TextFormField(
                        key: const Key('buyer'),
                        controller: _buyer,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Buyer name',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Enter the buyer name'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('vehicle'),
                        controller: _vehicle,
                        textCapitalization: TextCapitalization.characters,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle number',
                          hintText: 'GJ01AB1234',
                          prefixIcon: Icon(Icons.local_shipping_outlined),
                        ),
                        validator: (v) => _vehicleProblem(v ?? ''),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _reference,
                              decoration: const InputDecoration(
                                labelText: 'Reference',
                                hintText: 'Optional',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickDate,
                              icon: const Icon(Icons.event_outlined, size: 18),
                              label: Text(Fmt.relativeDay(_date)),
                            ),
                          ),
                        ],
                      ),

                      const SectionHeader(title: 'Products'),
                      if (stocked.isEmpty)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'There is no finished stock available to '
                              'dispatch.',
                            ),
                          ),
                        )
                      else
                        for (final product in stocked) ...[
                          _ProductCard(
                            product: product,
                            bundles: _field(_bundles, product.id),
                            bags: _field(_bags, product.id),
                          ),
                          const SizedBox(height: 10),
                        ],

                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _remarks,
                        maxLines: 2,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Remarks (optional)',
                        ),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _DispatchSubmitBar(
                  lines: lines,
                  note: overdrawn
                      ? 'More than is in stock'
                      : lines.isEmpty
                          ? 'Enter bundles or bags to send'
                          : _buyer.text.trim().isEmpty
                              ? 'Enter the buyer name'
                              : _vehicleProblem(_vehicle.text),
                  busy: _submitting,
                  onSubmit: ready ? () => _review(lines) : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _review(List<DispatchLine> lines) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _DispatchConfirmSheet(
        buyer: _buyer.text.trim(),
        date: _date,
        vehicle: normaliseVehicle(_vehicle.text),
        reference: _reference.text.trim(),
        lines: lines,
      ),
    );

    if (confirmed != true || !mounted) return;
    await _submit(lines);
  }

  Future<void> _submit(List<DispatchLine> lines) async {
    setState(() {
      _submitting = true;
      _error = null;
      _attemptRef ??= const Uuid().v4();
    });

    try {
      final result = await ref.read(dispatchRepositoryProvider).create(
            customerName: _buyer.text.trim(),
            lines: lines,
            clientRef: _attemptRef!,
            date: _date,
            reference:
                _reference.text.trim().isEmpty ? null : _reference.text.trim(),
            vehicleNumber: normaliseVehicle(_vehicle.text),
            remarks:
                _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
          );

      if (!mounted) return;

      invalidateStock(ref);
      ref.invalidate(productsProvider);
      ref.invalidate(dispatchesProvider);
      ref.invalidate(adminDashboardProvider);

      final message = result.duplicate
          ? 'That dispatch was already recorded — stock was not deducted twice.'
          : 'Dispatch recorded — '
              '${_packed(result.totalBundles, result.totalBags)} sent.';

      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // Nothing was deducted, so say so — an interrupted dispatch is the one
        // thing a storekeeper will worry about.
        _error = error.kind == AppErrorKind.insufficientStock
            ? '${error.message} Nothing was dispatched.'
            : error.message;
      });
    }
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.bundles,
    required this.bags,
  });

  final PipeProduct product;
  final TextEditingController bundles;
  final TextEditingController bags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final wantBundles = int.tryParse(bundles.text.trim()) ?? 0;
    final wantBags = int.tryParse(bags.text.trim()) ?? 0;
    final pipes = product.pipesFor(bundles: wantBundles, bags: wantBags);

    Widget input({
      required String label,
      required TextEditingController controller,
      required int available,
      required bool enabled,
      required String? disabledNote,
      required Key key,
    }) {
      final want = int.tryParse(controller.text.trim()) ?? 0;
      final over = want > available;

      return TextField(
        key: key,
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.right,
        style: AppTheme.numeric(context, size: 18),
        decoration: InputDecoration(
          labelText: label,
          hintText: '0',
          isDense: true,
          helperText: enabled ? '${Fmt.count(available)} in stock' : disabledNote,
          errorText: over ? 'Only ${Fmt.count(available)} in stock' : null,
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    product.label,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  product.sku,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: input(
                    key: Key('bundles-${product.sku}'),
                    label: 'Bundles',
                    controller: bundles,
                    available: product.quantityBundles,
                    enabled: product.quantityBundles > 0,
                    disabledNote: 'None in stock',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: input(
                    key: Key('bags-${product.sku}'),
                    label: 'Bags',
                    controller: bags,
                    available: product.quantityBags,
                    enabled: product.hasBagPacking && product.quantityBags > 0,
                    disabledNote: product.hasBagPacking
                        ? 'None in stock'
                        : 'Not packed in bags',
                  ),
                ),
              ],
            ),
            if (pipes != null && pipes > 0) ...[
              const SizedBox(height: 6),
              Text(
                '= ${Fmt.count(pipes)} pipes',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DispatchSubmitBar extends StatelessWidget {
  const _DispatchSubmitBar({
    required this.lines,
    required this.note,
    required this.busy,
    required this.onSubmit,
  });

  final List<DispatchLine> lines;
  final String? note;
  final bool busy;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bundles = lines.fold<int>(0, (sum, l) => sum + l.bundleQuantity);
    final bags = lines.fold<int>(0, (sum, l) => sum + l.bagQuantity);

    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      lines.isEmpty
                          ? 'Nothing selected'
                          : '${_packed(bundles, bags)} · ${lines.length} '
                              '${lines.length == 1 ? 'product' : 'products'}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (note != null)
                      Text(
                        note!,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy ? null : onSubmit,
                style: FilledButton.styleFrom(minimumSize: const Size(120, 52)),
                child: busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Review'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DispatchConfirmSheet extends StatelessWidget {
  const _DispatchConfirmSheet({
    required this.buyer,
    required this.date,
    required this.vehicle,
    required this.reference,
    required this.lines,
  });

  final String buyer;
  final DateTime date;
  final String vehicle;
  final String reference;
  final List<DispatchLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bundles = lines.fold<int>(0, (sum, l) => sum + l.bundleQuantity);
    final bags = lines.fold<int>(0, (sum, l) => sum + l.bagQuantity);

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
            const SizedBox(height: 20),
            Text(
              'Confirm dispatch',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _Row(label: 'Buyer', value: buyer),
            _Row(label: 'Vehicle', value: vehicle),
            _Row(label: 'Date', value: Fmt.date(date)),
            if (reference.isNotEmpty) _Row(label: 'Reference', value: reference),
            const Divider(height: 24),
            for (final line in lines)
              _Row(
                label: line.product,
                value: _packed(line.bundleQuantity, line.bagQuantity),
              ),
            const Divider(height: 24),
            _Row(label: 'Bundles dispatched', value: Fmt.count(bundles), bold: true),
            _Row(label: 'Bags dispatched', value: Fmt.count(bags), bold: true),
            const SizedBox(height: 8),
            Text(
              'Stock is checked before anything is deducted. If any product is '
              'short, the whole dispatch is refused.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Confirm dispatch'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: bold
                ? AppTheme.numeric(context, size: 18)
                : theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
