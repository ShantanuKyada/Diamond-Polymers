import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/panels.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// The roles the factory puts people on (A41).
///
/// Operator, Labourer and Office come with the app; everything else is the
/// factory's own — a supervisor, a helper, a fitter. The one thing a role has
/// to answer is whether it runs machines, because that decides whether its
/// people get the Material and Production screens, whether they can be put on
/// a machine, and whether the database will accept a run from them.
///
/// Roles are retired, never deleted: the people who held one still have a
/// history, and deleting it would orphan them.
class EmployeeRolesScreen extends ConsumerWidget {
  const EmployeeRolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MasterScaffold<EmployeeType>(
      title: 'Employee roles',
      subtitle: 'What kinds of people work here',
      items: ref.watch(employeeTypesProvider),
      addLabel: 'Role',
      emptyMessage: 'No roles defined.',
      emptyIcon: Icons.badge_outlined,
      onRefresh: () => ref.invalidate(employeeTypesProvider),
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, role) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          role.runsMachines
              ? Icons.precision_manufacturing_outlined
              : Icons.engineering_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Row(
          children: [
            Expanded(child: Text(role.name)),
            if (role.isSystem)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'built in',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            [
              role.runsMachines ? 'Runs machines' : 'No machine work',
              role.activeStaff == 1
                  ? '1 person'
                  : '${role.activeStaff} people',
              if (role.description != null) role.description!,
            ].join(' · '),
          ),
        ),
        isThreeLine: role.description != null,
        trailing: role.active ? null : const StatusChip(status: 'INACTIVE'),
        onTap: () => _edit(context, ref, role),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    EmployeeType? existing,
  ) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final description =
        TextEditingController(text: existing?.description ?? '');
    var runsMachines = existing?.runsMachines ?? false;
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add role' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
          controller: name,
          label: 'Role name',
          hint: 'Supervisor',
          required: true,
          helper: existing == null
              ? 'A short code is made from this automatically.'
              : 'Renaming is safe — everything refers to the code '
                  '${existing.code}, which does not change.',
        ),
        SheetField(
          controller: description,
          label: 'Description',
          maxLines: 2,
          helper: 'Shown to whoever is filling in an employee\'s details.',
        ),
        SwitchListTile(
          value: runsMachines,
          // The built-in Operator role cannot stop running machines: with no
          // such role, nobody in the factory could record production at all.
          onChanged: existing?.isSystem == true
              ? null
              : (value) {
                  runsMachines = value;
                  rebuild();
                },
          title: const Text('Runs machines'),
          subtitle: Text(
            existing?.isSystem == true
                ? 'The built-in Operator role always runs machines.'
                : runsMachines
                    ? 'Gets Material and Production, and can be put on a '
                        'machine.'
                    : 'On the payroll only — no machine screens, and cannot be '
                        'put on a machine.',
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (existing != null)
          SwitchListTile(
            value: active,
            onChanged: existing.isSystem
                ? null
                : (value) {
                    active = value;
                    rebuild();
                  },
            title: const Text('In use'),
            subtitle: Text(
              existing.isSystem
                  ? 'The built-in Operator role cannot be switched off.'
                  : existing.activeStaff > 0
                      ? '${existing.activeStaff} people are on this role. Move '
                          'them to another one before switching it off.'
                      : 'Switching it off keeps the role and its history, and '
                          'stops anybody new being put on it.',
            ),
            contentPadding: EdgeInsets.zero,
          ),
        if (existing != null && existing.totalStaff > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InlineBanner(
              message: '${existing.totalStaff} '
                  '${existing.totalStaff == 1 ? 'person has' : 'people have'} '
                  'held this role. It is never deleted, only retired, so their '
                  'records keep making sense.',
              icon: Icons.history_rounded,
              color: AppTheme.neutral,
            ),
          ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveEmployeeType(
            id: existing?.id,
            name: name.text,
            description: description.text,
            runsMachines: runsMachines,
            active: active,
          ),
    );

    if (saved) {
      ref.invalidate(employeeTypesProvider);
      // A role that stopped running machines takes its people's assignments
      // with it, so the roster and the assignment list both move.
      ref.invalidate(staffProvider);
      ref.invalidate(assignmentsProvider);
      if (context.mounted) {
        showMessage(context, existing == null ? 'Role added' : 'Saved');
      }
    }
  }
}
