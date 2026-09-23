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
import '../data/wastage_repository.dart';

/// Wastage — what was lost, and how much of it can be used again (§24, §25).
class WastageScreen extends ConsumerWidget {
  const WastageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(wastageEntriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Wastage')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RecordWastageScreen()),
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Record'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(wastageEntriesProvider.future),
        child: AsyncView<List<WastageEntry>>(
          value: entries,
          onRetry: () => ref.invalidate(wastageEntriesProvider),
          builder: (context, rows) {
            if (rows.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  EmptyView(
                    message: 'No wastage recorded.\n'
                        'That is the ideal — anything logged will appear here.',
                    icon: Icons.recycling_outlined,
                  ),
                ],
              );
            }

            final today = Fmt.isoDate(DateTime.now());
            final todays =
                rows.where((r) => Fmt.isoDate(r.entryDate) == today).toList();

            double sum(Iterable<WastageEntry> items) =>
                items.fold<double>(0, (total, e) => total + e.quantity);

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'Lost today',
                        value: Fmt.quantity(sum(todays.where(
                            (e) => e.source == WastageSource.rawMaterialLoss))),
                        unit: 'kg',
                        icon: Icons.delete_outline_rounded,
                        tone: AppTheme.low,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        label: 'Recoverable today',
                        value:
                            Fmt.quantity(sum(todays.where((e) => e.reusable))),
                        unit: 'kg',
                        icon: Icons.recycling_outlined,
                        tone: AppTheme.good,
                      ),
                    ),
                  ],
                ),
                const SectionHeader(title: 'History'),
                Card(
                  child: Column(
                    children: [
                      for (final (i, entry) in rows.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        _WastageTile(entry: entry),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WastageTile extends StatelessWidget {
  const _WastageTile({required this.entry});

  final WastageEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final where = [
      if (entry.machineName != null) entry.machineName!,
      if (entry.shiftName != null) entry.shiftName!,
      if (entry.operatorName != null) entry.operatorName!,
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.materialName,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (entry.reusable) ...[
                      const SizedBox(width: 8),
                      const StatusChip(status: 'REUSABLE'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.source.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: entry.source == WastageSource.rawMaterialLoss
                        ? AppTheme.low
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (where.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    where,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.outline),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Fmt.quantity(entry.quantity),
                style: AppTheme.numeric(context, size: 17),
              ),
              Text(
                entry.unit,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                Fmt.relativeDay(entry.entryDate),
                style:
                    theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================

class RecordWastageScreen extends ConsumerStatefulWidget {
  const RecordWastageScreen({super.key});

  @override
  ConsumerState<RecordWastageScreen> createState() =>
      _RecordWastageScreenState();
}

class _RecordWastageScreenState extends ConsumerState<RecordWastageScreen> {
  final _quantity = TextEditingController();
  final _remarks = TextEditingController();

  String? _materialId;
  String? _machineId;
  WastageSource _source = WastageSource.productionScrap;
  bool _reusable = true;
  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;
  String? _attemptRef;

  @override
  void initState() {
    super.initState();
    _quantity.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _quantity.dispose();
    _remarks.dispose();
    super.dispose();
  }

  double get _amount => double.tryParse(_quantity.text.trim()) ?? 0;
  bool get _ready => _materialId != null && _amount > 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final materials = ref.watch(rawMaterialsProvider).value ?? const <RawMaterial>[];
    final machines = ref.watch(machinesProvider).value ?? const <Machine>[];
    final usable = materials.where((m) => m.active).toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('Record Wastage')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                const _FieldLabel('Material'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final material in usable)
                      ChoiceChip(
                        label: Text(material.name),
                        selected: _materialId == material.id,
                        onSelected: (_) =>
                            setState(() => _materialId = material.id),
                      ),
                  ],
                ),

                const SizedBox(height: 22),
                const _FieldLabel('What happened'),
                const SizedBox(height: 8),
                for (final source in WastageSource.values) ...[
                  _SourceOption(
                    source: source,
                    selected: _source == source,
                    onTap: () => setState(() {
                      _source = source;
                      // Scrap off the machine is normally collected; a spill on
                      // the floor normally is not. Still overridable below.
                      _reusable = _source == WastageSource.productionScrap;
                    }),
                  ),
                  const SizedBox(height: 8),
                ],

                const SizedBox(height: 10),
                SwitchListTile(
                  value: _reusable,
                  onChanged: (value) => setState(() => _reusable = value),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Collected for reuse'),
                  subtitle: Text(
                    'Adds it to recycled stock, kept separate from virgin '
                    'material.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),

                const SizedBox(height: 12),
                const _FieldLabel('Quantity'),
                const SizedBox(height: 8),
                TextField(
                  controller: _quantity,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}')),
                  ],
                  style: AppTheme.numeric(context, size: 26),
                  decoration: const InputDecoration(
                    hintText: '0.00',
                    suffixText: 'kg',
                  ),
                ),

                const SizedBox(height: 22),
                const _FieldLabel('Machine', trailing: 'optional'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Not machine specific'),
                      selected: _machineId == null,
                      onSelected: (_) => setState(() => _machineId = null),
                    ),
                    for (final machine in machines.where((m) => m.active))
                      ChoiceChip(
                        label: Text(machine.name),
                        selected: _machineId == machine.id,
                        onSelected: (_) =>
                            setState(() => _machineId = machine.id),
                      ),
                  ],
                ),

                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(Fmt.date(_date)),
                ),

                const SizedBox(height: 16),
                TextField(
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
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Material(
            elevation: 8,
            color: scheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: FilledButton(
                  onPressed: _ready && !_submitting ? _submit : null,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Record wastage'),
                ),
              ),
            ),
          ),
        ],
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

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
      _attemptRef ??= const Uuid().v4();
    });

    try {
      await ref.read(wastageRepositoryProvider).record(
            rawMaterialId: _materialId!,
            source: _source,
            quantity: _amount,
            clientRef: _attemptRef!,
            reusable: _reusable,
            machineId: _machineId,
            entryDate: _date,
            remarks:
                _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
          );

      if (!mounted) return;

      invalidateStock(ref);
      ref.invalidate(wastageEntriesProvider);
      ref.invalidate(adminDashboardProvider);

      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wastage recorded.')),
      );
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
      });
    }
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          text,
          style:
              theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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


/// A tappable explanation of one wastage source. The difference between the two
/// decides whether raw stock moves, so each carries its reasoning rather than
/// just a label.
class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final WastageSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: selected ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.label,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    source.description,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
