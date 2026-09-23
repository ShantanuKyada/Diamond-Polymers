import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/panels.dart';
import '../../auth/domain/app_user.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// Staff master data and machine assignment (§10, §32).
///
/// An operator *is* a profile row (A2), and it may exist with no login at all
/// (A3) — common where one shared device sits on the floor. The tile therefore
/// distinguishes "has no login" from "is inactive"; they are different problems
/// with different fixes.
class OperatorsScreen extends ConsumerWidget {
  const OperatorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(staffProvider);
    final assignments = ref.watch(assignmentsProvider).value ?? const [];

    return MasterScaffold<StaffMember>(
      title: 'Operators',
      subtitle: 'Staff and machine assignment',
      items: staff,
      addLabel: 'Person',
      emptyMessage: 'Nobody on the roll yet.',
      emptyIcon: Icons.badge_outlined,
      onRefresh: () {
        ref.invalidate(staffProvider);
        ref.invalidate(assignmentsProvider);
      },
      onAdd: () => _edit(context, ref, null),
      itemBuilder: (context, person) {
        MachineAssignment? assignment;
        for (final a in assignments) {
          if (a.operatorId == person.id) {
            assignment = a;
            break;
          }
        }

        return _StaffTile(
          person: person,
          assignment: assignment,
          onEdit: () => _edit(context, ref, person),
          onAssign: () => _assign(context, ref, person, assignment),
          onLink: () => _link(context, ref, person),
          onEndAssignment: assignment == null
              ? null
              : () => _endAssignment(context, ref, person),
        );
      },
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    StaffMember? existing,
  ) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final code = TextEditingController(text: existing?.employeeCode ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    var role = existing?.role ?? UserRole.operator.wire;
    var active = existing?.active ?? true;

    final saved = await showEditSheet(
      context: context,
      title: existing == null ? 'Add person' : 'Edit ${existing.name}',
      fields: (rebuild) => [
        SheetField(
          controller: name,
          label: 'Name',
          hint: 'Ravi Kumar',
          required: true,
        ),
        SheetField(
          controller: code,
          label: 'Employee code',
          hint: 'EMP-105',
          required: true,
          helper: 'Must be unique. Used to attach a login later.',
        ),
        SheetField(
          controller: phone,
          label: 'Phone',
          keyboardType: TextInputType.phone,
        ),
        SheetDropdown<String>(
          label: 'Role',
          value: role,
          required: true,
          helper: 'Administrators see the whole factory. Operators see their '
              'own machine and their own entries.',
          items: [
            DropdownMenuItem(
              value: UserRole.operator.wire,
              child: Text('Operator'),
            ),
            DropdownMenuItem(
              value: UserRole.admin.wire,
              child: Text('Administrator'),
            ),
          ],
          onChanged: (value) {
            role = value ?? role;
            rebuild();
          },
        ),
        SwitchListTile(
          value: active,
          onChanged: (value) {
            active = value;
            rebuild();
          },
          title: const Text('On the roll'),
          subtitle: const Text(
            'Turning this off removes them from entry forms and payroll. Their '
            'history is kept.',
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).saveStaff(
            id: existing?.id,
            name: name.text,
            employeeCode: code.text,
            role: role,
            active: active,
            phone: phone.text,
          ),
    );

    if (saved) {
      ref.invalidate(staffProvider);
      if (context.mounted) {
        showMessage(context, existing == null ? 'Person added' : 'Saved');
      }
    }
  }

  Future<void> _assign(
    BuildContext context,
    WidgetRef ref,
    StaffMember person,
    MachineAssignment? current,
  ) async {
    final machines = ref.read(machinesProvider).value ?? const <Machine>[];
    final shifts = ref.read(shiftsProvider).value ?? const <Shift>[];

    final runnable = machines.where((m) => m.active).toList();
    if (runnable.isEmpty) {
      showMessage(context, 'No active machines to assign.', error: true);
      return;
    }

    String? machineId = current?.machineId;
    String? shiftId = current?.shiftId;

    final saved = await showEditSheet(
      context: context,
      title: 'Assign ${person.name}',
      saveLabel: 'Assign',
      fields: (rebuild) => [
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'Currently on ${current.machineName} since '
              '${Fmt.date(current.effectiveFrom)}. Reassigning closes that '
              'record with an end date — it is never deleted, because past '
              'production points at it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        SheetDropdown<String>(
          label: 'Machine',
          value: machineId,
          required: true,
          items: [
            for (final m in runnable)
              DropdownMenuItem(value: m.id, child: Text('${m.code} — ${m.name}')),
          ],
          onChanged: (value) {
            machineId = value;
            rebuild();
          },
        ),
        SheetDropdown<String>(
          label: 'Shift',
          value: shiftId,
          helper: 'Optional. Leave empty if the person moves between shifts.',
          items: [
            const DropdownMenuItem(value: null, child: Text('No fixed shift')),
            for (final s in shifts.where((s) => s.active))
              DropdownMenuItem(value: s.id, child: Text('${s.name} · ${s.range}')),
          ],
          onChanged: (value) {
            shiftId = value;
            rebuild();
          },
        ),
      ],
      onSave: () => ref.read(mastersRepositoryProvider).assignOperator(
            operatorId: person.id,
            machineId: machineId!,
            shiftId: shiftId,
          ),
    );

    if (saved) {
      ref.invalidate(assignmentsProvider);
      if (context.mounted) showMessage(context, 'Assignment updated');
    }
  }

  Future<void> _endAssignment(
    BuildContext context,
    WidgetRef ref,
    StaffMember person,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End assignment?'),
        content: Text(
          '${person.name} will no longer be able to record entries against '
          'their machine. The record is closed with today\'s date, not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End assignment'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(mastersRepositoryProvider).endAssignment(person.id);
      ref.invalidate(assignmentsProvider);
      if (context.mounted) showMessage(context, 'Assignment ended');
    } on Object catch (error) {
      if (context.mounted) {
        showMessage(context, _messageOf(error), error: true);
      }
    }
  }

  /// Attaching a login to a profile (A3). The login itself is created in the
  /// Supabase dashboard: doing it from the app needs a service-role key, which
  /// must never ship inside an APK (§56).
  Future<void> _link(
    BuildContext context,
    WidgetRef ref,
    StaffMember person,
  ) async {
    final email = TextEditingController();

    final saved = await showEditSheet(
      context: context,
      title: 'Attach login — ${person.name}',
      saveLabel: 'Attach',
      fields: (rebuild) => [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Create the user first in Supabase → Authentication → Users, with '
            '"Auto Confirm User" ticked. Then enter that email here to attach '
            'it to ${person.employeeCode}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SheetField(
          controller: email,
          label: 'Login email',
          hint: 'ravi@diamondpolymers.local',
          keyboardType: TextInputType.emailAddress,
          required: true,
        ),
      ],
      onSave: () async {
        await ref.read(mastersRepositoryProvider).linkLogin(
              employeeCode: person.employeeCode,
              email: email.text,
            );
      },
    );

    if (saved) {
      ref.invalidate(staffProvider);
      if (context.mounted) showMessage(context, 'Login attached');
    }
  }

  static String _messageOf(Object error) {
    final message = error.toString();
    return message.startsWith('AppException') ? 'That could not be saved.' : message;
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({
    required this.person,
    required this.assignment,
    required this.onEdit,
    required this.onAssign,
    required this.onLink,
    required this.onEndAssignment,
  });

  final StaffMember person;
  final MachineAssignment? assignment;
  final VoidCallback onEdit;
  final VoidCallback onAssign;
  final VoidCallback onLink;
  final VoidCallback? onEndAssignment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: person.active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        child: Text(
          person.initials,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: person.active ? scheme.onPrimaryContainer : scheme.outline,
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(person.name)),
          if (person.isAdmin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Admin',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(person.employeeCode,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      assignment == null
                          ? Icons.link_off_rounded
                          : Icons.precision_manufacturing_outlined,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      assignment == null
                          ? 'No machine'
                          : '${assignment!.machineCode}'
                              '${assignment!.shiftName == null ? '' : ' · ${assignment!.shiftName}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                // A person with no login is a normal, supported state — not an
                // error — so it reads as information, not a warning.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      person.hasLogin
                          ? Icons.lock_outline_rounded
                          : Icons.no_accounts_outlined,
                      size: 14,
                      color: person.hasLogin
                          ? AppTheme.good
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      person.hasLogin ? 'Can sign in' : 'No login',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                if (!person.active) const StatusChip(status: 'INACTIVE'),
              ],
            ),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => switch (value) {
          'edit' => onEdit(),
          'assign' => onAssign(),
          'link' => onLink(),
          'end' => onEndAssignment?.call(),
          _ => null,
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit details')),
          const PopupMenuItem(value: 'assign', child: Text('Assign to machine')),
          if (onEndAssignment != null)
            const PopupMenuItem(value: 'end', child: Text('End assignment')),
          if (!person.hasLogin)
            const PopupMenuItem(value: 'link', child: Text('Attach a login')),
        ],
      ),
      onTap: onEdit,
    );
  }
}
