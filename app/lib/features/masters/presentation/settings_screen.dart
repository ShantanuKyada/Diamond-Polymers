import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routing/routes.dart';
import '../../../core/widgets/state_views.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import 'widgets/master_scaffold.dart';

/// Settings hub (§32).
///
/// Two halves. The catalogues are the factory's nouns — shifts, types, sizes,
/// products, materials — and each gets its own screen. Below them sit the
/// `app_settings` rows, which are the rules the database reads when it
/// calculates: the payroll assumptions, the shred tolerance, the factory
/// timezone.
///
/// Those rules are shown with the description the database itself carries,
/// rather than a copy written here, so the explanation cannot drift away from
/// what the function actually does.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Configuration')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(settingsProvider),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const _GroupHeader('Catalogues'),
            _Entry(
              icon: Icons.category_outlined,
              title: 'Products',
              subtitle: 'Bundle weights and reorder levels',
              onTap: () => context.pushNamed(AppRoute.adminProducts.name),
            ),
            _Entry(
              icon: Icons.line_style_outlined,
              title: 'Pipe types',
              subtitle: 'Grades, and the regrind pool each returns to',
              onTap: () => context.pushNamed(AppRoute.adminPipeTypes.name),
            ),
            _Entry(
              icon: Icons.straighten_outlined,
              title: 'Pipe sizes',
              subtitle: 'Diameters and lengths',
              onTap: () => context.pushNamed(AppRoute.adminPipeSizes.name),
            ),
            _Entry(
              icon: Icons.science_outlined,
              title: 'Raw materials',
              subtitle: 'Inputs, thresholds and regrind pools',
              onTap: () => context.pushNamed(AppRoute.adminRawMaterials.name),
            ),
            _Entry(
              icon: Icons.schedule_outlined,
              title: 'Shifts',
              subtitle: 'Working hours',
              onTap: () => context.pushNamed(AppRoute.adminShifts.name),
            ),

            const _GroupHeader('Rules the system calculates by'),
            AsyncView<List<AppSetting>>(
              value: settings,
              onRetry: () => ref.invalidate(settingsProvider),
              builder: (context, rows) {
                if (rows.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: EmptyView(message: 'No settings found.'),
                  );
                }
                return Column(
                  children: [
                    for (final setting in rows)
                      _SettingTile(
                        setting: setting,
                        onEdit: () => _edit(context, ref, setting),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    AppSetting setting,
  ) async {
    final value = TextEditingController(text: setting.value);

    final saved = await showEditSheet(
      context: context,
      title: _humanise(setting.key),
      fields: (rebuild) => [
        if (setting.description != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              setting.description!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        SheetField(
          controller: value,
          label: 'Value',
          required: true,
          helper: 'Stored as text. The database reads and interprets it — an '
              'invalid value is rejected when it is next used, not here.',
        ),
      ],
      onSave: () =>
          ref.read(mastersRepositoryProvider).setSetting(setting.key, value.text),
    );

    if (saved) {
      ref.invalidate(settingsProvider);
      if (context.mounted) showMessage(context, 'Setting updated');
    }
  }

  static String _humanise(String key) {
    final words = key.split('_');
    if (words.isEmpty) return key;
    final first = words.first;
    return [
      first.isEmpty ? first : first[0].toUpperCase() + first.substring(1),
      ...words.skip(1),
    ].join(' ');
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.setting, required this.onEdit});

  final AppSetting setting;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      title: Text(SettingsScreen._humanise(setting.key)),
      subtitle: setting.description == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                setting.description!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          setting.value,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      onTap: onEdit,
      isThreeLine: setting.description != null,
    );
  }
}
