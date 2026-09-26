import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/routing/routes.dart';
import '../../core/widgets/panels.dart';
import '../auth/presentation/session_controller.dart';

/// The overflow section of the admin navigation (§34). A bottom bar holds five
/// destinations comfortably; everything else lives here.
class AdminMoreScreen extends ConsumerWidget {
  const AdminMoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  user?.initials ?? '?',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(user?.name ?? 'Administrator'),
              subtitle: Text(user?.employeeCode ?? ''),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.pushNamed(AppRoute.profile.name),
            ),
          ),

          const SectionHeader(title: 'Operations'),
          _LinkCard(
            items: [
              _Link(
                icon: Icons.science_outlined,
                label: 'Material Entry',
                route: AppRoute.mixtureEntry,
              ),
              _Link(
                icon: Icons.delete_outline_rounded,
                label: 'Wastage',
                route: AppRoute.adminWastage,
              ),
              _Link(
                icon: Icons.precision_manufacturing_outlined,
                label: 'Machines',
                route: AppRoute.adminMachines,
              ),
              _Link(
                icon: Icons.badge_outlined,
                label: 'Operators',
                route: AppRoute.adminOperators,
              ),
              _Link(
                icon: Icons.assessment_outlined,
                label: 'Reports',
                route: AppRoute.adminReports,
              ),
            ],
          ),

          // §33: Staff must be visible in the navigation from day one, even
          // though attendance and payroll are a later phase.
          const SectionHeader(title: 'Staff'),
          _LinkCard(
            items: [
              _Link(
                icon: Icons.how_to_reg_outlined,
                label: 'Punches',
                route: AppRoute.adminStaffPunches,
              ),
              _Link(
                icon: Icons.payments_outlined,
                label: 'Salary',
                route: AppRoute.adminStaffSalary,
              ),
            ],
          ),

          const SectionHeader(title: 'System'),
          _LinkCard(
            items: [
              _Link(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                route: AppRoute.notifications,
              ),
              // "Settings" undersold it: the screen is the factory's
              // catalogues — products, pipe types, sizes, materials, shifts —
              // plus the rules the database calculates by. None of that is a
              // preference, and calling it Settings sent people looking for
              // something else.
              _Link(
                icon: Icons.tune_rounded,
                label: 'Configuration',
                route: AppRoute.adminSettings,
              ),
            ],
          ),

          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, ref),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You will need to sign in again to continue.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );

  if (confirmed ?? false) {
    await ref.read(sessionControllerProvider.notifier).signOut();
  }
}

class _Link {
  const _Link({
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final AppRoute route;
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.items});

  final List<_Link> items;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ListTile(
              leading: Icon(item.icon),
              title: Text(item.label),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.pushNamed(item.route.name),
            ),
          ],
        ],
      ),
    );
  }
}
