import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// The four small catalogues behind Settings: shifts, pipe types, pipe sizes
/// and raw materials.
///
/// They live in one file because each is the same shape — a list and a short
/// form — and splitting them into four near-identical files would make the
/// differences between them harder to see, not easier.

// =============================================================================
// Shifts
// =============================================================================

/// The shift master (A29).
///
/// The factory runs exactly two shifts, Morning and Night. They cannot be
/// added to, renamed or switched off — the database refuses all three — so the
/// screen offers only what can change: the times.
class ShiftsScreen extends ConsumerWidget {
  const ShiftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Retired shifts stay in the database for history but are not managed here.
    final shifts = ref
        .watch(shiftsProvider)
        .whenData((rows) => rows.where((s) => s.active).toList());

    return MasterScaffold<Shift>(
      title: 'Shifts',
      subtitle: 'Morning and Night',
      items: shifts,
      emptyMessage: 'No shifts defined.',
      emptyIcon: Icons.schedule_outlined,
      onRefresh: () => ref.invalidate(shiftsProvider),
      header: const _ShiftNote(),
      itemBuilder: (context, shift) => ListTile(
        leading: Icon(
          shift.name.toLowerCase() == 'night'
              ? Icons.nightlight_outlined
              : Icons.wb_sunny_outlined,
        ),
        title: Text('${shift.name} Shift'),
        subtitle: Text(shift.range),
        trailing: const Icon(Icons.edit_outlined, size: 20),
        onTap: () => _edit(context, ref, shift),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Shift existing) async {
    var start = _parseTime(existing.startTime) ??
        const TimeOfDay(hour: 6, minute: 0);
    var end =
        _parseTime(existing.endTime) ?? const TimeOfDay(hour: 18, minute: 0);

    final saved = await showEditSheet(
      context: context,
      title: '${existing.name} Shift — timings',
      fields: (rebuild) => [
        _TimeRow(
          label: 'Starts',
          value: start,
          onPick: (picked) {
            start = picked;
            rebuild();
          },
        ),
        _TimeRow(
          label: 'Ends',
          value: end,
          onPick: (picked) {
            end = picked;
            rebuild();
          },
        ),
        // A night shift legitimately ends before it starts (A16). Say so rather
        // than validating it away.
        if (_crossesMidnight(start, end))
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'This shift crosses midnight. That is supported — an entry is '
              'recorded against the date the shift started.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveShift(
            id: existing.id,
            name: existing.name,
            startTime: _wireTime(start),
            endTime: _wireTime(end),
            active: true,
          ),
    );

    if (saved) {
      ref.invalidate(shiftsProvider);
      if (context.mounted) showMessage(context, 'Saved');
    }
  }

  static bool _crossesMidnight(TimeOfDay start, TimeOfDay end) {
    final s = start.hour * 60 + start.minute;
    final e = end.hour * 60 + end.minute;
    return e <= s;
  }

  static TimeOfDay? _parseTime(String? value) {
    if (value == null || value.length < 5) return null;
    final hour = int.tryParse(value.substring(0, 2));
    final minute = int.tryParse(value.substring(3, 5));
    if (hour == null || minute == null) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static String _wireTime(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:00';
}

class _ShiftNote extends StatelessWidget {
  const _ShiftNote();

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
          Icon(Icons.schedule_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The factory runs two shifts. Their timings can be adjusted; '
              'shifts cannot be added or removed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          alignment: Alignment.centerLeft,
        ),
        onPressed: () async {
          final picked =
              await showTimePicker(context: context, initialTime: value);
          if (picked != null) onPick(picked);
        },
        child: Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              '${value.hour.toString().padLeft(2, '0')}:'
              '${value.minute.toString().padLeft(2, '0')}',
              style: AppTheme.numeric(context, size: 16),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.access_time_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Pipe types
// =============================================================================

class PipeTypesScreen extends ConsumerWidget {
  const PipeTypesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final materials = ref.watch(rawMaterialsProvider).value ?? const [];

    return MasterScaffold<PipeType>(
      title: 'Pipe types',
      items: ref.watch(pipeTypesProvider),
      addLabel: 'Type',
      emptyMessage: 'No pipe types defined.',
      emptyIcon: Icons.line_style_outlined,
      onRefresh: () => ref.invalidate(pipeTypesProvider),
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, type) {
        final pool = materials
            .where((m) => m.id == type.recycledMaterialId)
            .map((m) => m.name)
            .firstOrNull;

        return ListTile(
          title: Text(type.name),
          subtitle: Text(
            '${type.code}'
            '${type.description == null ? '' : ' · ${type.description}'}'
            '\nRegrind pool: ${pool ?? 'not set'}',
          ),
          isThreeLine: true,
          trailing: type.active ? null : const StatusChip(status: 'INACTIVE'),
          onTap: () => _edit(context, ref, type),
        );
      },
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, PipeType? existing) async {
    final materials = ref.read(rawMaterialsProvider).value ?? const [];
    final recycled = materials.where((m) => m.isRecycled).toList();

    final code = TextEditingController(text: existing?.code ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final description =
        TextEditingController(text: existing?.description ?? '');
    var poolId = existing?.recycledMaterialId;
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add pipe type' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
            controller: code, label: 'Code', hint: 'TC', required: true),
        SheetField(
            controller: name, label: 'Name', hint: 'Type C', required: true),
        SheetField(
            controller: description, label: 'Description', maxLines: 2),
        SheetDropdown<String>(
          label: 'Regrind pool',
          value: poolId,
          helper: 'Where shredded pipe of this type returns to. Keeping a pool '
              'per grade stops black regrind ending up in a white pipe.',
          items: [
            const DropdownMenuItem(value: null, child: Text('Not set')),
            for (final m in recycled)
              DropdownMenuItem(value: m.id, child: Text(m.name)),
          ],
          onChanged: (value) {
            poolId = value;
            rebuild();
          },
        ),
        SwitchListTile(
          value: active,
          onChanged: (value) {
            active = value;
            rebuild();
          },
          title: const Text('In use'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).savePipeType(
            id: existing?.id,
            code: code.text,
            name: name.text,
            active: active,
            description: description.text,
            recycledMaterialId: poolId,
          ),
    );

    if (saved) {
      ref.invalidate(pipeTypesProvider);
      if (context.mounted) showMessage(context, 'Saved');
    }
  }
}

// =============================================================================
// Pipe sizes
// =============================================================================

class PipeSizesScreen extends ConsumerWidget {
  const PipeSizesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MasterScaffold<PipeSize>(
      title: 'Pipe sizes',
      items: ref.watch(pipeSizesProvider),
      addLabel: 'Size',
      emptyMessage: 'No sizes defined.',
      emptyIcon: Icons.straighten_outlined,
      onRefresh: () => ref.invalidate(pipeSizesProvider),
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, size) => ListTile(
        title: Text(size.name),
        subtitle: Text([
          size.code,
          if (size.diameterMm != null) '⌀ ${Fmt.quantity(size.diameterMm)} mm',
          if (size.lengthM != null) '${Fmt.quantity(size.lengthM)} m',
          if (size.description != null) size.description!,
        ].join(' · ')),
        trailing: size.active ? null : const StatusChip(status: 'INACTIVE'),
        onTap: () => _edit(context, ref, size),
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, PipeSize? existing) async {
    final code = TextEditingController(text: existing?.code ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final description =
        TextEditingController(text: existing?.description ?? '');
    final diameter = TextEditingController(
      text: existing?.diameterMm == null
          ? ''
          : Fmt.quantity(existing!.diameterMm),
    );
    final length = TextEditingController(
      text: existing?.lengthM == null ? '' : Fmt.quantity(existing!.lengthM),
    );
    final order =
        TextEditingController(text: (existing?.sortOrder ?? 0).toString());
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add size' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
            controller: code, label: 'Code', hint: 'S5', required: true),
        SheetField(
            controller: name, label: 'Name', hint: 'Size 5', required: true),
        SheetField(
          controller: diameter,
          label: 'Diameter (mm)',
          hint: '19.05',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          validator: _optionalPositive,
        ),
        SheetField(
          controller: length,
          label: 'Length (m)',
          hint: '100',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          validator: _optionalPositive,
        ),
        SheetField(
          controller: description,
          label: 'Description',
          hint: '3/4 inch',
        ),
        SheetField(
          controller: order,
          label: 'Sort order',
          keyboardType: TextInputType.number,
          helper: 'Lists are ordered by this, smallest first.',
        ),
        SwitchListTile(
          value: active,
          onChanged: (value) {
            active = value;
            rebuild();
          },
          title: const Text('In use'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).savePipeSize(
            id: existing?.id,
            code: code.text,
            name: name.text,
            sortOrder: int.tryParse(order.text.trim()) ?? 0,
            active: active,
            description: description.text,
            diameterMm: double.tryParse(diameter.text.trim()),
            lengthM: double.tryParse(length.text.trim()),
          ),
    );

    if (saved) {
      ref.invalidate(pipeSizesProvider);
      if (context.mounted) showMessage(context, 'Saved');
    }
  }

  static String? _optionalPositive(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed == null) return 'Enter a number';
    if (parsed <= 0) return 'Must be greater than zero';
    return null;
  }
}

// =============================================================================
// Raw materials
// =============================================================================

class RawMaterialsScreen extends ConsumerWidget {
  const RawMaterialsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MasterScaffold<RawMaterial>(
      title: 'Raw materials',
      subtitle: 'Including regrind pools',
      items: ref.watch(rawMaterialsProvider),
      addLabel: 'Material',
      emptyMessage: 'No materials defined.',
      emptyIcon: Icons.science_outlined,
      onRefresh: () => ref.invalidate(rawMaterialsProvider),
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, material) => ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Row(
          children: [
            Expanded(child: Text(material.name)),
            StatusChip(status: material.status),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${material.code} · ${material.categoryName}'
            '${material.isRecycled ? ' · regrind' : ''}\n'
            'In stock ${Fmt.qtyWithUnit(material.quantity, material.unit)}'
            '${material.minimumStock == 0 ? '' : '  ·  reorder at ${Fmt.qtyWithUnit(material.minimumStock, material.unit)}'}',
          ),
        ),
        isThreeLine: true,
        onTap: () => _edit(context, ref, material),
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, RawMaterial? existing) async {
    final categories =
        await ref.read(mastersRepositoryProvider).rawMaterialCategories();
    if (!context.mounted) return;

    final code = TextEditingController(text: existing?.code ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final unit = TextEditingController(text: existing?.unit ?? 'kg');
    final minimum = TextEditingController(
      text: existing == null ? '0' : Fmt.quantity(existing.minimumStock),
    );
    var category = existing?.category ??
        (categories.isEmpty ? null : categories.first['code'] as String);
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add material' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
            controller: code, label: 'Code', hint: 'RM-X', required: true),
        SheetField(controller: name, label: 'Name', required: true),
        SheetDropdown<String>(
          label: 'Category',
          value: category,
          required: true,
          helper: 'RECYCLED marks a regrind pool. Shredded pipe can only be '
              'returned to a recycled material.',
          items: [
            for (final c in categories)
              DropdownMenuItem(
                value: c['code'] as String,
                child: Text(c['name'] as String? ?? c['code'] as String),
              ),
          ],
          onChanged: (value) {
            category = value;
            rebuild();
          },
        ),
        SheetField(controller: unit, label: 'Unit', required: true),
        SheetField(
          controller: minimum,
          label: 'Low-stock threshold',
          required: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          helper: 'Zero disables the alert — normal for regrind, which is '
              'expected to run out.',
          validator: (value) {
            final parsed = double.tryParse((value ?? '').trim());
            if (parsed == null) return 'Enter a number';
            if (parsed < 0) return 'Cannot be negative';
            return null;
          },
        ),
        SwitchListTile(
          value: active,
          onChanged: (value) {
            active = value;
            rebuild();
          },
          title: const Text('In use'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveRawMaterial(
            id: existing?.id,
            code: code.text,
            name: name.text,
            category: category!,
            unit: unit.text,
            minimumStock: double.parse(minimum.text.trim()),
            active: active,
            // The flag and the category have to agree, or a pool would be
            // invisible to shred_pipe() while looking correct on this screen.
            isRecycled: category == 'RECYCLED',
          ),
    );

    if (saved) {
      ref.invalidate(rawMaterialsProvider);
      if (context.mounted) showMessage(context, 'Saved');
    }
  }
}
