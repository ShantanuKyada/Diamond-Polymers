import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/domain/dashboard_models.dart';
import '../../inventory/data/inventory_repository.dart';
import '../../masters/data/masters_repository.dart';
import '../../masters/domain/masters.dart';
import '../data/mixture_repository.dart';

/// Who is filling this form in.
///
/// One screen, two callers (A34). The material inputs, the running total, the
/// confirmation summary and the retry handling are identical either way — the
/// only real difference is where the machine comes from, so duplicating the
/// screen would have meant maintaining that arithmetic twice.
enum MaterialEntryMode {
  /// An administrator, who may record against any machine and is told which
  /// operator the batch will be credited to.
  admin,

  /// An operator, recording the machine they are assigned to. They cannot
  /// choose a different one — and the database refuses it anyway (DP006).
  operator,
}

/// Material Entry — what went into a machine (§15, §16, A34).
///
/// Production has two halves: material in, product out. This is the first half.
///
/// Access (A34, reversing A30): an operator records their **own** machine,
/// because they are the person loading it; an administrator may record any
/// machine. `consume_raw_materials()` enforces exactly that, so the screen
/// being scoped is a convenience rather than the protection.
///
/// Three things it has to get right, whichever mode it is in:
///
///   * the batch is credited to the right person — the operator themselves, or
///     for an admin, whoever runs the chosen machine, named before saving;
///   * every material shows what is actually in stock beside its input, so a
///     short batch is obvious before it is submitted rather than after;
///   * the submission carries one reference for the whole attempt, reused on
///     retry, so a double tap on a bad connection records one batch.
class MixtureEntryScreen extends ConsumerStatefulWidget {
  const MixtureEntryScreen({super.key, this.mode = MaterialEntryMode.admin});

  final MaterialEntryMode mode;

  @override
  ConsumerState<MixtureEntryScreen> createState() => _MixtureEntryScreenState();
}

class _MixtureEntryScreenState extends ConsumerState<MixtureEntryScreen> {
  final _quantities = <String, TextEditingController>{};
  final _remarks = TextEditingController();

  DateTime _entryDate = DateTime.now();
  String? _shiftId;
  bool _submitting = false;
  String? _error;

  /// Minted once per submission attempt and deliberately NOT regenerated on a
  /// failed retry: reusing it is what makes the retry safe. Cleared only after
  /// the batch is recorded, so the next one is genuinely new (§47).
  String? _attemptRef;

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    _remarks.dispose();
    super.dispose();
  }

  TextEditingController _controllerFor(String materialId) {
    return _quantities.putIfAbsent(materialId, () {
      final controller = TextEditingController();
      controller.addListener(() => setState(() {}));
      return controller;
    });
  }

  double _quantityOf(String materialId) {
    final text = _quantities[materialId]?.text.trim() ?? '';
    if (text.isEmpty) return 0;
    return double.tryParse(text) ?? 0;
  }

  List<MixtureLine> get _lines {
    final lines = <MixtureLine>[];
    for (final entry in _quantities.entries) {
      final quantity = _quantityOf(entry.key);
      if (quantity > 0) {
        lines.add(MixtureLine(rawMaterialId: entry.key, quantity: quantity));
      }
    }
    return lines;
  }

  double get _total =>
      _lines.fold<double>(0, (sum, line) => sum + line.quantity);

  void _reset() {
    for (final controller in _quantities.values) {
      controller.clear();
    }
    _remarks.clear();
    _attemptRef = null;
    _error = null;
  }

  String? _machineId;

  bool get _isOperator => widget.mode == MaterialEntryMode.operator;

  @override
  Widget build(BuildContext context) {
    return _isOperator ? _buildOperator(context) : _buildAdmin(context);
  }

  /// The operator's machine is not a choice, so the form waits on their
  /// assignment rather than on the machine list. Without one the database
  /// would refuse the batch with DP006 whatever was typed, so the form is not
  /// offered at all.
  Widget _buildOperator(BuildContext context) {
    final dashboard = ref.watch(operatorDashboardProvider);
    final materials = ref.watch(rawMaterialsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Material Entry')),
      body: AsyncView<OperatorDashboard>(
        value: dashboard,
        onRetry: () => ref.invalidate(operatorDashboardProvider),
        builder: (context, data) {
          final assignment = data.assignment;
          if (assignment == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: EmptyView(
                message: 'You are not assigned to a machine, so material '
                    'cannot be recorded. Ask an administrator to assign you.',
                icon: Icons.link_off_rounded,
              ),
            );
          }

          _machineId = assignment.machineId;

          return AsyncView<List<RawMaterial>>(
            value: materials,
            onRetry: () => ref.invalidate(rawMaterialsProvider),
            builder: (context, allMaterials) {
              final usable =
                  allMaterials.where((m) => m.active).toList(growable: false);
              if (usable.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: EmptyView(
                    message: 'No raw materials are configured.',
                    icon: Icons.science_outlined,
                  ),
                );
              }
              return _form(context, const <Machine>[], usable,
                  fixedAssignment: assignment);
            },
          );
        },
      ),
    );
  }

  Widget _buildAdmin(BuildContext context) {
    final machines = ref.watch(machinesProvider);
    final materials = ref.watch(rawMaterialsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Material Entry')),
      body: AsyncView<List<Machine>>(
        value: machines,
        onRetry: () => ref.invalidate(machinesProvider),
        builder: (context, allMachines) {
          final usableMachines =
              allMachines.where((m) => m.active).toList(growable: false);

          if (usableMachines.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: EmptyView(
                message: 'No machines are configured yet.',
                icon: Icons.precision_manufacturing_outlined,
              ),
            );
          }

          return AsyncView<List<RawMaterial>>(
            value: materials,
            onRetry: () => ref.invalidate(rawMaterialsProvider),
            builder: (context, allMaterials) {
              final usable =
                  allMaterials.where((m) => m.active).toList(growable: false);

              if (usable.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: EmptyView(
                    message: 'No raw materials are configured.',
                    icon: Icons.science_outlined,
                  ),
                );
              }

              return _form(context, usableMachines, usable);
            },
          );
        },
      ),
    );
  }

  /// The shift the clock is in, so the usual case needs no tap.
  static String? _currentShiftId(List<Shift> shifts) {
    final now = TimeOfDay.now();
    final minutes = now.hour * 60 + now.minute;

    int? parse(String value) {
      if (value.length < 5) return null;
      final h = int.tryParse(value.substring(0, 2));
      final m = int.tryParse(value.substring(3, 5));
      return h == null || m == null ? null : h * 60 + m;
    }

    for (final shift in shifts.where((s) => s.active)) {
      final start = parse(shift.startTime);
      final end = parse(shift.endTime);
      if (start == null || end == null) continue;
      final inside = start < end
          ? minutes >= start && minutes < end
          : minutes >= start || minutes < end;
      if (inside) return shift.id;
    }
    return shifts.where((s) => s.active).firstOrNull?.id;
  }

  /// The chosen machine, in the shape the confirmation and submit steps use.
  OperatorAssignment? _target(List<Machine> machines, List<Shift> shifts) {
    final machine = machines.where((m) => m.id == _machineId).firstOrNull;
    if (machine == null) return null;
    final shift = shifts.where((s) => s.id == _shiftId).firstOrNull;

    return OperatorAssignment(
      machineId: machine.id,
      machineName: machine.name,
      machineCode: machine.code,
      machineStatus: machine.status.wire,
      shiftId: shift?.id,
      shiftName: shift?.name,
      startTime: shift?.startTime,
      endTime: shift?.endTime,
    );
  }

  /// Who the database will credit the batch to: the operator on this machine
  /// and shift, then anyone on this machine (A30).
  String? _creditedTo(List<MachineAssignment> assignments) {
    final onMachine =
        assignments.where((a) => a.machineId == _machineId).toList();
    if (onMachine.isEmpty) return null;
    final onShift = onMachine.where((a) => a.shiftId == _shiftId);
    return (onShift.isNotEmpty ? onShift.first : onMachine.first).operatorName;
  }

  Widget _form(
    BuildContext context,
    List<Machine> machines,
    List<RawMaterial> materials, {
    OperatorAssignment? fixedAssignment,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final shifts = ref.watch(shiftsProvider).value ?? const <Shift>[];
    final assignments =
        ref.watch(assignmentsProvider).value ?? const <MachineAssignment>[];

    // An operator's shift comes from their assignment when they have a fixed
    // one; otherwise, as for an admin, from the clock.
    _shiftId ??= fixedAssignment?.shiftId ?? _currentShiftId(shifts);
    final target = fixedAssignment ?? _target(machines, shifts);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              if (fixedAssignment != null)
                _AssignedMachineCard(
                  assignment: fixedAssignment,
                  entryDate: _entryDate,
                  onPickDate: _pickDate,
                )
              else
                _MachineCard(
                  machines: machines,
                  selectedId: _machineId,
                  creditedTo:
                      _machineId == null ? null : _creditedTo(assignments),
                  entryDate: _entryDate,
                  onSelect: (id) => setState(() => _machineId = id),
                  onPickDate: _pickDate,
                ),
              const SizedBox(height: 16),
              if (shifts.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _shiftId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Shift *',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final shift in shifts.where((s) => s.active))
                      DropdownMenuItem(
                        value: shift.id,
                        child: Text('${shift.name} · ${shift.range}'),
                      ),
                  ],
                  onChanged: (value) => setState(() => _shiftId = value),
                ),
              const SizedBox(height: 20),
              Text(
                'Materials used',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Leave a material blank if none was used. If any one of them is '
                'short, the whole batch is refused and nothing is deducted.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              for (final material in materials)
                _MaterialInput(
                  material: material,
                  controller: _controllerFor(material.id),
                  entered: _quantityOf(material.id),
                ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _remarks,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Remarks',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
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
                          size: 18, color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.onErrorContainer),
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
          total: _total,
          lineCount: _lines.length,
          busy: _submitting,
          onSubmit: _lines.isEmpty || _shiftId == null || target == null
              ? null
              : () => _review(context, target, materials),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _entryDate,
      // Backdating a shift is normal; recording tomorrow's work is not.
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _entryDate = picked);
  }

  /// §44: a confirmation summary before anything is written.
  Future<void> _review(
    BuildContext context,
    OperatorAssignment assignment,
    List<RawMaterial> materials,
  ) async {
    final byId = {for (final m in materials) m.id: m};

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ConfirmSheet(
        assignment: assignment,
        entryDate: _entryDate,
        lines: _lines,
        materials: byId,
        total: _total,
      ),
    );

    if (confirmed != true || !mounted) return;
    await _submit(assignment);
  }

  Future<void> _submit(OperatorAssignment assignment) async {
    setState(() {
      _submitting = true;
      _error = null;
      // Reused if this attempt fails and is retried; only a fresh batch gets a
      // fresh reference.
      _attemptRef ??= const Uuid().v4();
    });

    try {
      final result = await ref.read(mixtureRepositoryProvider).consume(
            machineId: assignment.machineId,
            shiftId: _shiftId!,
            lines: _lines,
            clientRef: _attemptRef!,
            entryDate: _entryDate,
            remarks: _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
          );

      if (!mounted) return;

      invalidateStock(ref);
      ref.invalidate(adminDashboardProvider);

      final message = result.duplicate
          ? 'That batch was already recorded — nothing was deducted twice.'
          : 'Batch recorded: ${Fmt.quantity(result.totalQuantity)} kg.';

      setState(() {
        _submitting = false;
        _reset();
      });

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _explain(error);
      });
    }
  }

  /// Insufficient stock carries the numbers in `data`; using them turns
  /// "not enough Raizin" into something an operator can act on.
  String _explain(AppException error) {
    if (error.kind != AppErrorKind.insufficientStock) return error.message;

    final available = error.data['available'];
    final requested = error.data['requested'];
    if (available == null || requested == null) return error.message;

    final short = (_asDouble(requested) - _asDouble(available)).abs();
    return '${error.message} You entered '
        '${Fmt.quantity(_asDouble(requested))} — '
        '${Fmt.quantity(short)} more than there is. Nothing was deducted.';
  }

  static double _asDouble(Object? value) => switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s) ?? 0,
        _ => 0,
      };
}

/// Which machine the batch went into, who it will be credited to, and when.
class _MachineCard extends StatelessWidget {
  const _MachineCard({
    required this.machines,
    required this.selectedId,
    required this.creditedTo,
    required this.entryDate,
    required this.onSelect,
    required this.onPickDate,
  });

  final List<Machine> machines;
  final String? selectedId;
  final String? creditedTo;
  final DateTime entryDate;
  final ValueChanged<String> onSelect;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.precision_manufacturing_outlined,
                  color: scheme.primary),
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
                icon: const Icon(Icons.calendar_today_rounded, size: 16),
                label: Text(Fmt.relativeDay(entryDate)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final machine in machines)
                ChoiceChip(
                  label: Text(machine.name),
                  selected: machine.id == selectedId,
                  onSelected: (_) => onSelect(machine.id),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            selectedId == null
                ? 'Choose the machine this batch was loaded into.'
                : creditedTo == null
                    ? 'Nobody is assigned to this machine — the batch will be '
                        'recorded against your account.'
                    : 'Credited to $creditedTo.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MaterialInput extends StatelessWidget {
  const _MaterialInput({
    required this.material,
    required this.controller,
    required this.entered,
  });

  final RawMaterial material;
  final TextEditingController controller;
  final double entered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A hint, not a verdict: the database holds the authoritative balance and
    // may have moved since this screen loaded. It still catches the common case
    // before a batch is thrown away.
    final short = entered > material.quantity;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(material.name,
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  'In stock ${Fmt.qtyWithUnit(material.quantity, material.unit)}'
                  '${material.isRecycled ? ' · regrind' : ''}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: short ? AppTheme.critical : scheme.onSurfaceVariant,
                        fontWeight: short ? FontWeight.w700 : null,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: TextFormField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                suffixText: material.unit,
                isDense: true,
                border: const OutlineInputBorder(),
                errorText: short ? 'Only ${Fmt.quantity(material.quantity)}' : null,
                errorStyle: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.total,
    required this.lineCount,
    required this.busy,
    required this.onSubmit,
  });

  final double total;
  final int lineCount;
  final bool busy;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                      'Batch total',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    Text.rich(
                      TextSpan(
                        text: Fmt.quantity(total),
                        style: AppTheme.numeric(context, size: 24),
                        children: [
                          TextSpan(
                            text: '  kg · $lineCount '
                                '${lineCount == 1 ? 'material' : 'materials'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy ? null : onSubmit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(120, 52),
                ),
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
    required this.assignment,
    required this.entryDate,
    required this.lines,
    required this.materials,
    required this.total,
  });

  final OperatorAssignment assignment;
  final DateTime entryDate;
  final List<MixtureLine> lines;
  final Map<String, RawMaterial> materials;
  final double total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Confirm this batch',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '${assignment.machineName} · ${Fmt.date(entryDate)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(materials[line.rawMaterialId]?.name ?? 'Material'),
                  ),
                  Text(
                    Fmt.qtyWithUnit(
                      line.quantity,
                      materials[line.rawMaterialId]?.unit ?? 'kg',
                    ),
                    style: AppTheme.numeric(context, size: 16),
                  ),
                ],
              ),
            ),
          const Divider(height: 28),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${Fmt.quantity(total)} kg',
                style: AppTheme.numeric(context, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('Record batch'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back and change it'),
          ),
        ],
      ),
    );
  }
}

/// The operator's own machine, shown rather than chosen (A34).
///
/// Deliberately not a disabled dropdown: a control that looks interactive and
/// is not invites tapping. This states the fact and moves on.
class _AssignedMachineCard extends StatelessWidget {
  const _AssignedMachineCard({
    required this.assignment,
    required this.entryDate,
    required this.onPickDate,
  });

  final OperatorAssignment assignment;
  final DateTime entryDate;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.precision_manufacturing_outlined, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  assignment.machineName,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  assignment.shiftName == null
                      ? assignment.machineCode
                      : '${assignment.machineCode} · ${assignment.shiftName}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onPickDate,
            icon: const Icon(Icons.calendar_today_rounded, size: 16),
            label: Text(Fmt.relativeDay(entryDate)),
          ),
        ],
      ),
    );
  }
}
