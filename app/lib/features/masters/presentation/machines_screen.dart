import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/widgets/panels.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// Machine master data (§9, §32).
///
/// Each row shows the line, its status, who is on it right now, and how many
/// products it is configured to run — the four things an administrator actually
/// wants to know before touching anything.
class MachinesScreen extends ConsumerWidget {
  const MachinesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final assignments = ref.watch(assignmentsProvider).value ?? const [];

    return MasterScaffold<Machine>(
      title: 'Machines',
      subtitle: 'Production lines',
      items: machines,
      addLabel: 'Machine',
      emptyMessage: 'No machines yet. Add the first production line.',
      emptyIcon: Icons.precision_manufacturing_outlined,
      onRefresh: () {
        ref.invalidate(machinesProvider);
        ref.invalidate(assignmentsProvider);
      },
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, machine) {
        final operator = assignments
            .where((a) => a.machineId == machine.id)
            .map((a) => a.operatorName)
            .toList();

        return _MachineTile(
          machine: machine,
          operators: operator,
          onEdit: () => _edit(context, ref, machine),
          onProducts: () => _editProducts(context, ref, machine),
        );
      },
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Machine? existing,
  ) async {
    final code = TextEditingController(text: existing?.code ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final description =
        TextEditingController(text: existing?.description ?? '');
    var status = existing?.status ?? MachineStatus.active;
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add machine' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
          controller: code,
          label: 'Code',
          hint: 'M5',
          required: true,
          helper: 'Short identifier painted on the machine.',
        ),
        SheetField(
          controller: name,
          label: 'Name',
          hint: 'Machine 5',
          required: true,
        ),
        SheetField(
          controller: description,
          label: 'Description',
          hint: 'Braiding line 5',
          maxLines: 2,
        ),
        SheetDropdown<MachineStatus>(
          label: 'Status',
          value: status,
          required: true,
          helper: 'Maintenance keeps the machine visible but flags it as down.',
          items: [
            for (final s in MachineStatus.values)
              DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (value) {
            status = value ?? status;
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
          subtitle: const Text(
            'Turning this off hides the machine from entry forms. Its '
            'production history is kept.',
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveMachine(
            id: existing?.id,
            code: code.text,
            name: name.text,
            status: status,
            active: active,
            description: description.text,
          ),
    );

    if (saved) {
      ref.invalidate(machinesProvider);
      if (context.mounted) {
        showMessage(context, existing == null ? 'Machine added' : 'Saved');
      }
    }
  }

  /// Which products this line can run (A23).
  Future<void> _editProducts(
    BuildContext context,
    WidgetRef ref,
    Machine machine,
  ) async {
    final repository = ref.read(mastersRepositoryProvider);

    final Set<String> selected;
    final List<PipeProduct> products;
    try {
      products = await repository.products();
      selected = {...await repository.machineProductIds(machine.id)};
    } on AppException catch (error) {
      if (context.mounted) showMessage(context, error.message, error: true);
      return;
    }

    if (!context.mounted) return;

    if (products.isEmpty) {
      showMessage(
        context,
        'No products are configured yet. Add them under Settings → Products.',
        error: true,
      );
      return;
    }

    final saved = await showEditSheet(
      context: context,
      title: '${machine.name} — products',
      saveLabel: 'Save capability',
      fields: (rebuild) => [
        Text(
          selected.isEmpty
              ? 'Nothing selected. A machine with no products configured is '
                  'unconstrained — it may run anything.'
              : '${selected.length} of ${products.length} products selected. '
                  'Production of anything else will be refused on this line.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final product in products)
          CheckboxListTile(
            value: selected.contains(product.id),
            onChanged: (checked) {
              if (checked ?? false) {
                selected.add(product.id);
              } else {
                selected.remove(product.id);
              }
              rebuild();
            },
            title: Text(product.label),
            subtitle: Text(
              '${product.sku} · ${product.bundleWeightKg} kg per bundle',
            ),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
      ],
      onSave: () =>
          repository.setMachineProducts(machine.id, selected.toList()),
    );

    if (saved) {
      ref.invalidate(machineProductIdsProvider(machine.id));
      if (context.mounted) showMessage(context, 'Capability updated');
    }
  }
}

class _MachineTile extends ConsumerWidget {
  const _MachineTile({
    required this.machine,
    required this.operators,
    required this.onEdit,
    required this.onProducts,
  });

  final Machine machine;
  final List<String> operators;
  final VoidCallback onEdit;
  final VoidCallback onProducts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final capability = ref.watch(machineProductIdsProvider(machine.id));

    final capabilityLabel = capability.when(
      data: (ids) => ids.isEmpty ? 'Any product' : '${ids.length} products',
      loading: () => '…',
      error: (_, _) => '—',
    );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: machine.status.color.withValues(alpha: 0.15),
        child: Text(
          machine.code,
          style: TextStyle(
            color: machine.status.color,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(machine.name)),
          if (!machine.active)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: StatusChip(status: 'INACTIVE'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: StatusChip(status: machine.status.wire),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (machine.description != null)
              Text(
                machine.description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Meta(
                  icon: Icons.person_outline_rounded,
                  text: operators.isEmpty ? 'Unassigned' : operators.join(', '),
                  tone: operators.isEmpty ? scheme.onSurfaceVariant : null,
                ),
                _Meta(
                  icon: Icons.category_outlined,
                  text: capabilityLabel,
                ),
              ],
            ),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => value == 'edit' ? onEdit() : onProducts(),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit machine')),
          PopupMenuItem(value: 'products', child: Text('Products it can run')),
        ],
      ),
      onTap: onEdit,
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.tone});

  final IconData icon;
  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
