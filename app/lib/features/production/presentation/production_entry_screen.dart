import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../auth/presentation/session_controller.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/data/settings_values.dart';
import '../../masters/domain/masters.dart';
import '../../mixture/data/mixture_repository.dart';
import '../data/production_repository.dart';
import '../../../core/widgets/responsive.dart';

/// Production Entry — the operator records what came off the machine (§18,
/// §19, A27, A28).
///
/// Machine, operator and date come from the assignment and the clock; the
/// operator chooses shift, product and quantities. Everything else is a
/// confirmation.
///
/// Three quantities, and they mean different things:
///
///   * **bundles and bags** — the good output, each into its own stock. Bags
///     are offered only for a product whose packaging is configured, because
///     the database refuses them otherwise (A26);
///   * **scrap generated** — kilograms lost during the run. It never reduces
///     the bundles, which are already the net good output;
///   * **wastage material used** — recycled material fed into the run. It is
///     recorded for analysis and moves no stock, because material entry
///     already accounts for it (A28).
class ProductionEntryScreen extends ConsumerStatefulWidget {
  const ProductionEntryScreen({super.key});

  @override
  ConsumerState<ProductionEntryScreen> createState() =>
      _ProductionEntryScreenState();
}

class _ProductionEntryScreenState extends ConsumerState<ProductionEntryScreen> {
  final _bundles = TextEditingController();
  final _bags = TextEditingController();
  final _scrap = TextEditingController();
  final _usedKg = TextEditingController();
  final _remarks = TextEditingController();

  DateTime _entryDate = DateTime.now();
  String? _shiftId;
  String? _pipeTypeId;
  String? _pipeSizeId;

  /// The batch this run came out of (A37). Defaults to the most recent batch
  /// on the machine, which is almost always the right one — the operator
  /// charged it minutes ago.
  String? _batchId;

  /// The machine the operator says they are on (A40). Defaulted to the one they
  /// are assigned to, then theirs to change.
  String? _machineId;

  /// Null until the operator answers — the question is asked, not assumed.
  bool? _wastageUsed;

  bool _submitting = false;
  String? _error;

  /// One reference per attempt, reused on retry so a double tap on a bad
  /// connection records a single entry (§47).
  String? _attemptRef;

  @override
  void initState() {
    super.initState();
    for (final controller in [_bundles, _bags, _usedKg]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final controller in [_bundles, _bags, _scrap, _usedKg, _remarks]) {
      controller.dispose();
    }
    super.dispose();
  }

  int get _bundleCount => int.tryParse(_bundles.text.trim()) ?? 0;
  int get _bagCount => int.tryParse(_bags.text.trim()) ?? 0;
  double get _scrapKg => double.tryParse(_scrap.text.trim()) ?? 0;
  double get _usedWastageKg => double.tryParse(_usedKg.text.trim()) ?? 0;

  PipeProduct? _product(List<PipeProduct> products) {
    for (final p in products) {
      if (p.pipeTypeId == _pipeTypeId && p.pipeSizeId == _pipeSizeId) return p;
    }
    return null;
  }

  /// Why the entry cannot be submitted yet, or null when it can. Shown under
  /// the button so a greyed-out Review never leaves anyone guessing.
  String? _blocker(PipeProduct? product) {
    if (_shiftId == null) return 'Choose the shift.';
    if (_pipeTypeId == null) return 'Choose the pipe type.';
    if (_pipeSizeId == null) return 'Choose the pipe size.';
    if (_bundleCount + _bagCount == 0) return 'Enter the bundles or bags produced.';
    if (_bagCount > 0 && !(product?.hasBagPacking ?? false)) {
      return 'This product is not packed in bags.';
    }
    if (_wastageUsed == null) return 'Say whether wastage material was used.';
    if (_wastageUsed! && _usedWastageKg <= 0) {
      return 'Enter the wastage material used, in kg.';
    }
    return null;
  }

  void _reset() {
    for (final controller in [_bundles, _bags, _scrap, _usedKg, _remarks]) {
      controller.clear();
    }
    _wastageUsed = null;
    _attemptRef = null;
    _error = null;
  }

  @override
  Widget build(BuildContext context) {
    // A40: the machine is a choice, not a fact read off an assignment. It used
    // to be the latter, because the database refused any other machine with
    // DP006; the factory moves people between machines during a shift, so that
    // refusal is gone and this asks instead.
    final mine = ref.watch(operatorMachinesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Production Entry')),
      body: PageBody(child: AsyncView<List<OperatorMachine>>(
        value: mine,
        onRetry: () => ref.invalidate(operatorMachinesProvider),
        builder: (context, machines) {
          if (machines.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: EmptyView(
                message: 'No machines are running, so production cannot be '
                    'recorded. Ask an administrator.',
                icon: Icons.precision_manufacturing_outlined,
              ),
            );
          }

          final usual = machines.where((m) => m.isMine).firstOrNull;
          _machineId ??= (usual ?? machines.first).machineId;
          final chosen = machines
                  .where((m) => m.machineId == _machineId)
                  .firstOrNull ??
              machines.first;

          return _form(context, machines, chosen, usual);
        },
      )),
    );
  }

  Widget _form(
    BuildContext context,
    List<OperatorMachine> machines,
    OperatorMachine chosen,
    OperatorMachine? usual,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final shifts = (ref.watch(shiftsProvider).value ?? const <Shift>[])
        .where((s) => s.active)
        .toList(growable: false);
    final types = (ref.watch(pipeTypesProvider).value ?? const <PipeType>[])
        .where((t) => t.active)
        .toList(growable: false);
    final sizes = ref.watch(pipeSizesProvider).value ?? const <PipeSize>[];
    final products = (ref.watch(productsProvider).value ?? const <PipeProduct>[])
        .where((p) => p.active)
        .toList(growable: false);

    // Default to the shift on their own machine's assignment, but only while it
    // is one that is in use. Editable either way: somebody covering a different
    // shift says so.
    if (_shiftId == null && shifts.any((s) => s.id == usual?.myShiftId)) {
      _shiftId = usual!.myShiftId;
    }

    // Type -> size is the product mapping (A24): offer only the sizes this type
    // is actually made in.
    final sizeIds = {
      for (final p in products)
        if (p.pipeTypeId == _pipeTypeId) p.pipeSizeId,
    };
    final sizesForType = sizes
        .where((s) => s.active && sizeIds.contains(s.id))
        .toList(growable: false)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final unit = ref.watch(wastageUnitProvider);
    final product = _product(products);
    final bagsAllowed = product?.hasBagPacking ?? false;
    final pipes = product?.pipesFor(bundles: _bundleCount, bags: _bagCount);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _MachineCard(
                machines: machines,
                selectedId: chosen.machineId,
                usualMachineId: usual?.machineId,
                date: _entryDate,
                onPickDate: _pickDate,
                onSelect: (id) => setState(() {
                  _machineId = id;
                  // The batch belongs to a machine, so changing machine drops
                  // a batch that was charged into a different one.
                  _batchId = null;
                }),
              ),

              const SizedBox(height: 20),
              const _Label(text: 'Material batch'),
              const SizedBox(height: 8),
              _BatchPicker(
                machineId: chosen.machineId,
                selected: _batchId,
                onSelect: (id) => setState(() => _batchId = id),
              ),

              const SizedBox(height: 20),
              const _Label(text: 'Shift'),
              const SizedBox(height: 8),
              _ChoiceRow(
                options: [
                  for (final shift in shifts) (shift.id, shift.name),
                ],
                selected: _shiftId,
                onSelect: (id) => setState(() => _shiftId = id),
              ),

              const SizedBox(height: 20),
              const _Label(text: 'Pipe type'),
              const SizedBox(height: 8),
              _ChoiceRow(
                options: [for (final t in types) (t.id, t.name)],
                selected: _pipeTypeId,
                onSelect: (id) => setState(() {
                  if (_pipeTypeId != id) _pipeSizeId = null;
                  _pipeTypeId = id;
                }),
              ),

              const SizedBox(height: 20),
              const _Label(text: 'Pipe size'),
              const SizedBox(height: 8),
              if (_pipeTypeId == null)
                const _Hint('Choose the pipe type first.')
              else if (sizesForType.isEmpty)
                const _Hint('No sizes are set up for this type yet.')
              else
                _ChoiceRow(
                  options: [
                    for (final s in sizesForType)
                      (
                        s.id,
                        s.diameterMm == null
                            ? s.name
                            : '${s.name} · ${Fmt.quantity(s.diameterMm)} mm'
                      ),
                  ],
                  selected: _pipeSizeId,
                  onSelect: (id) => setState(() => _pipeSizeId = id),
                ),

              const SizedBox(height: 24),
              const _Label(text: 'Quantity produced'),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('bundles'),
                      controller: _bundles,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: AppTheme.numeric(context, size: 24),
                      decoration: InputDecoration(
                        labelText: 'Bundles',
                        hintText: '0',
                        helperText: product?.pipesPerBundle == null
                            ? null
                            : '${product!.pipesPerBundle} pipes each',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('bags'),
                      controller: _bags,
                      enabled: bagsAllowed,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: AppTheme.numeric(context, size: 24),
                      decoration: InputDecoration(
                        labelText: 'Bags',
                        hintText: '0',
                        helperText: product == null
                            ? null
                            : bagsAllowed
                                ? '${product.pipesPerBag} pipes each'
                                // Bags are refused until somebody says how
                                // many pipes are in one, because the database
                                // cannot weigh a bag without it (A26). That
                                // reads as "this product has no bags", which
                                // is indistinguishable from "nobody has set it
                                // up" — so it says which, and where to go.
                                : 'No pipes-per-bag set for this product',
                      ),
                    ),
                  ),
                ],
              ),
              if (pipes != null && pipes > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '= ${Fmt.count(pipes)} pipes in total',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],

              const SizedBox(height: 24),
              const _Label(text: 'Was wastage material used?'),
              const SizedBox(height: 4),
              Text(
                'Recycled or reground material fed into this run.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                key: const Key('wastage-used'),
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('Yes'),
                    icon: Icon(Icons.recycling_outlined),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('No'),
                    icon: Icon(Icons.block_outlined),
                  ),
                ],
                selected: {?_wastageUsed},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: (value) => setState(() {
                  _wastageUsed = value.isEmpty ? null : value.first;
                  // "No" carries no quantity (A28).
                  if (_wastageUsed != true) _usedKg.clear();
                }),
              ),
              if (_wastageUsed == true) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('wastage-used-kg'),
                  controller: _usedKg,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Wastage material used',
                    hintText: '0.0',
                    suffixText: unit,
                    errorText: _usedKg.text.isNotEmpty && _usedWastageKg <= 0
                        ? 'Must be more than zero'
                        : null,
                  ),
                ),
              ],

              const SizedBox(height: 24),
              const _Label(text: 'Scrap generated', trailing: 'optional'),
              const SizedBox(height: 8),
              TextField(
                controller: _scrap,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                decoration: InputDecoration(
                  hintText: '0.00',
                  suffixText: unit,
                  helperText: 'Offcuts and purge from this run. It does not '
                      'reduce the quantity above.',
                  helperMaxLines: 2,
                ),
              ),

              const SizedBox(height: 20),
              const _Label(text: 'Remarks', trailing: 'optional'),
              const SizedBox(height: 8),
              TextField(
                controller: _remarks,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Anything worth noting about this run',
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 20, color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        _SubmitBar(
          bundles: _bundleCount,
          bags: _bagCount,
          blocker: _blocker(product),
          busy: _submitting,
          onSubmit: _blocker(product) == null
              ? () => _review(context, chosen, product!)
              : null,
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _entryDate,
      // Backdating a shift is routine; recording tomorrow's output is not.
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _entryDate = picked);
  }

  /// §44: a confirmation summary before anything is written.
  Future<void> _review(
    BuildContext context,
    OperatorMachine chosen,
    PipeProduct product,
  ) async {
    final shifts = ref.read(shiftsProvider).value ?? const <Shift>[];
    final shiftName =
        shifts.where((s) => s.id == _shiftId).firstOrNull?.name ?? '—';

    final confirmed = await showAppSheet<bool>(
      context: context,
      builder: (context) => _ConfirmSheet(
        machine: chosen.label,
        operator: ref.read(currentUserProvider)?.name ?? '—',
        shift: shiftName,
        product: product,
        date: _entryDate,
        bundles: _bundleCount,
        bags: _bagCount,
        wastageUsedKg: _wastageUsed == true ? _usedWastageKg : null,
        scrap: _scrapKg,
        unit: ref.read(wastageUnitProvider),
      ),
    );

    if (confirmed != true || !mounted) return;
    await _submit(chosen);
  }

  Future<void> _submit(OperatorMachine chosen) async {
    setState(() {
      _submitting = true;
      _error = null;
      _attemptRef ??= const Uuid().v4();
    });

    try {
      final result = await ref.read(productionRepositoryProvider).record(
            machineId: chosen.machineId,
            shiftId: _shiftId!,
            pipeTypeId: _pipeTypeId!,
            pipeSizeId: _pipeSizeId!,
            bundleQuantity: _bundleCount,
            bagQuantity: _bagCount,
            clientRef: _attemptRef!,
            entryDate: _entryDate,
            wastageQuantity: _scrapKg,
            wastageUsed: _wastageUsed == true,
            wastageUsedKg: _wastageUsed == true ? _usedWastageKg : null,
            remarks: _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
            mixtureEntryId: _batchId,
          );

      if (!mounted) return;

      invalidateStock(ref);
      ref.invalidate(productsProvider);
      ref.invalidate(operatorDashboardProvider);
      ref.invalidate(myProductionProvider);

      final added = [
        if (result.bundleQuantity > 0) Fmt.bundles(result.bundleQuantity),
        if (result.bagQuantity > 0)
          '${Fmt.count(result.bagQuantity)} '
              '${result.bagQuantity == 1 ? 'bag' : 'bags'}',
      ].join(' and ');

      final message = result.duplicate
          ? 'That entry was already recorded — nothing was counted twice.'
          : 'Production recorded — $added added.';

      setState(() {
        _submitting = false;
        _reset();
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
      });
    }
  }
}

// -----------------------------------------------------------------------------

class _Label extends StatelessWidget {
  const _Label({required this.text, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// Wrapped choice chips. Tapping beats typing on a factory floor (§43), and a
/// handful of options fits better here than a dropdown that hides them.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final List<(String, String)> options;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const _Hint('Nothing configured yet.');

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (id, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: selected == id,
            onSelected: (_) => onSelect(id),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
      ],
    );
  }
}

/// Which machine the operator is on, and which day (A40).
///
/// This used to state the machine as a fact, because the operator could only
/// record for the one they were assigned to. It asks now. Their usual machine
/// is marked and selected, so the common case is still one glance and no taps.
class _MachineCard extends StatelessWidget {
  const _MachineCard({
    required this.machines,
    required this.selectedId,
    required this.usualMachineId,
    required this.date,
    required this.onPickDate,
    required this.onSelect,
  });

  final List<OperatorMachine> machines;
  final String selectedId;
  final String? usualMachineId;
  final DateTime date;
  final VoidCallback onPickDate;
  final ValueChanged<String> onSelect;

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
                Icon(Icons.precision_manufacturing_outlined,
                    color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Machine',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: onPickDate,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(Fmt.relativeDay(date)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // A Wrap, not a Row: a factory with eight machines would overflow
            // a phone, and the number of machines is the factory's to change.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final machine in machines)
                  ChoiceChip(
                    label: Text(machine.machineId == usualMachineId
                        ? '${machine.name} · yours'
                        : machine.name),
                    selected: machine.machineId == selectedId,
                    onSelected: (_) => onSelect(machine.machineId),
                  ),
              ],
            ),
            if (usualMachineId != null && selectedId != usualMachineId) ...[
              const SizedBox(height: 10),
              Text(
                'Not your usual machine — that is fine, the entry is recorded '
                'against the one you picked.',
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

class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.bundles,
    required this.bags,
    required this.blocker,
    required this.busy,
    required this.onSubmit,
  });

  final int bundles;
  final int bags;
  final String? blocker;
  final bool busy;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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
                    Text.rich(
                      TextSpan(
                        text: Fmt.count(bundles),
                        style: AppTheme.numeric(context, size: 22),
                        children: [
                          TextSpan(
                            text: bundles == 1 ? ' bundle' : ' bundles',
                            style: theme.textTheme.bodySmall,
                          ),
                          TextSpan(
                            text: '   ${Fmt.count(bags)}',
                            style: AppTheme.numeric(context, size: 22),
                          ),
                          TextSpan(
                            text: bags == 1 ? ' bag' : ' bags',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (blocker != null)
                      Text(
                        blocker!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.machine,
    required this.operator,
    required this.shift,
    required this.product,
    required this.date,
    required this.bundles,
    required this.bags,
    required this.wastageUsedKg,
    required this.scrap,
    required this.unit,
  });

  final String machine;
  final String operator;
  final String shift;
  final PipeProduct product;
  final DateTime date;
  final int bundles;
  final int bags;
  final double? wastageUsedKg;
  final double scrap;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pipes = product.pipesFor(bundles: bundles, bags: bags);

    return SingleChildScrollView(
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
            'Confirm production',
            style:
                theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          _Line(label: 'Date', value: Fmt.date(date)),
          _Line(label: 'Machine', value: machine),
          _Line(label: 'Operator', value: operator),
          _Line(label: 'Shift', value: shift),
          _Line(label: 'Pipe type', value: product.pipeTypeName),
          _Line(label: 'Pipe size', value: product.pipeSizeName),
          const Divider(height: 24),
          _Line(label: 'Bundles', value: Fmt.count(bundles), bold: true),
          _Line(label: 'Bags', value: Fmt.count(bags), bold: true),
          if (pipes != null && pipes > 0)
            _Line(label: 'Pipes in total', value: Fmt.count(pipes)),
          _Line(
            label: 'Wastage material used',
            value: wastageUsedKg == null
                ? 'No'
                : 'Yes · ${Fmt.quantity(wastageUsedKg)} $unit',
          ),
          if (scrap > 0)
            _Line(label: 'Scrap generated', value: '${Fmt.quantity(scrap)} $unit'),
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
                  child: const Text('Confirm production'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: bold
                  ? AppTheme.numeric(context, size: 18)
                  : theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which material batch this run came out of (A37).
///
/// Defaults to the newest batch on the machine, because that is almost always
/// the one the operator just charged. A batch that has already produced is
/// still offered — one batch can yield two sizes — but it says so, because
/// picking the wrong one is how a run gets counted against the wrong material.
///
/// With no batch at all the answer is not a disabled dropdown but a way out:
/// the Material tab, which is where the operator has to go anyway.
class _BatchPicker extends ConsumerWidget {
  const _BatchPicker({
    required this.machineId,
    required this.selected,
    required this.onSelect,
  });

  final String machineId;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final batches = ref.watch(machineBatchesProvider(machineId));

    return batches.when(
      loading: () => const LinearProgressIndicator(minHeight: 2),
      error: (error, stack) => Text(
        ErrorMapper.map(error, stack).message,
        style: TextStyle(color: scheme.error),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.science_outlined, size: 18,
                    color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No material recorded for this machine yet. Record what '
                    'went in first — production is linked to it.',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      context.goNamed(AppRoute.operatorMaterialEntry.name),
                  child: const Text('Record'),
                ),
              ],
            ),
          );
        }

        // Newest first, so the default is the batch just charged.
        final value = selected ?? rows.first.id;
        if (selected == null) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => onSelect(rows.first.id));
        }

        return DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final batch in rows)
              DropdownMenuItem(
                value: batch.id,
                child: Text(
                  '${Fmt.relativeDay(batch.entryDate)} · '
                  '${Fmt.quantity(batch.chargedKg)} kg'
                  '${batch.shiftName == null ? '' : ' · ${batch.shiftName}'}'
                  '${batch.hasProduction ? '  (already produced)' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onSelect,
        );
      },
    );
  }
}
