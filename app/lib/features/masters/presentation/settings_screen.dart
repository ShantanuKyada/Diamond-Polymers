import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routing/routes.dart';
import '../../../core/widgets/state_views.dart';
import '../data/masters_repository.dart';
import '../domain/masters.dart';
import '../domain/setting_spec.dart';
import '../../../core/widgets/responsive.dart';
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
      body: PageBody(child: RefreshIndicator(
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
      )),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    AppSetting setting,
  ) async {
    final spec = SettingSpec.forKey(setting.key);
    final value = TextEditingController(text: setting.value);
    // Held apart from the controller: a switch and a dropdown have no text to
    // edit, and threading them through one would mean parsing it back out.
    var picked = setting.value;

    final saved = await showEditSheet(
      context: context,
      title: titleFor(setting.key),
      fields: (rebuild) => [
        // The database's own description first. It is the authoritative one,
        // written beside the code that reads the value.
        if (setting.description != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              setting.description!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),

        switch (spec.kind) {
          // A switch, not a text box: "true" is one of several things somebody
          // might type, and every other spelling silently falls back to the
          // default the next time the database reads it.
          SettingKind.toggle => _ToggleField(
              spec: spec,
              value: picked,
              onChanged: (v) {
                picked = v;
                rebuild();
              },
            ),
          SettingKind.choice => SheetDropdown<String>(
              label: 'Value',
              value: spec.options.any((o) => o.value == picked) ? picked : null,
              required: true,
              helper: spec.hint,
              items: [
                for (final option in spec.options)
                  DropdownMenuItem(
                      value: option.value, child: Text(option.label)),
              ],
              onChanged: (v) {
                picked = v ?? picked;
                rebuild();
              },
            ),
          SettingKind.number => SheetField(
              controller: value,
              label: spec.suffix == null ? 'Value' : 'Value (${spec.suffix})',
              required: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              helper: spec.hint,
              validator: (raw) {
                final n = num.tryParse((raw ?? '').trim());
                if (n == null) return 'Enter a number.';
                if (spec.min != null && n < spec.min!) {
                  return 'Cannot be below ${spec.min}.';
                }
                if (spec.max != null && n > spec.max!) {
                  return 'Cannot be above ${spec.max}.';
                }
                return null;
              },
            ),
          SettingKind.multiline => SheetField(
              controller: value,
              label: 'Value',
              maxLines: 3,
              helper: spec.hint,
            ),
          SettingKind.text => SheetField(
              controller: value,
              label: 'Value',
              helper: spec.hint,
            ),
        },
      ],
      onSave: () => ref.read(mastersRepositoryProvider).setSetting(
            setting.key,
            switch (spec.kind) {
              SettingKind.toggle || SettingKind.choice => picked,
              _ => value.text,
            },
          ),
    );

    if (saved) {
      ref.invalidate(settingsProvider);
      if (context.mounted) showMessage(context, 'Setting updated');
    }
  }

  /// The name a setting is shown under: the one its spec gives, or one
  /// derived from the key.
  static String titleFor(String key) =>
      SettingSpec.forKey(key).label ?? _humanise(key);

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
      title: Text(SettingsScreen.titleFor(setting.key)),
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
          // What the value means, where that is known — "Refuse" rather than
          // "true". An unrecognised value still shows itself, so a setting
          // holding something unexpected is visible rather than disguised.
          SettingSpec.forKey(setting.key).labelFor(setting.value),
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

/// A true/false setting, shown as the two things it actually means.
///
/// Not a bare switch: "Refuse" and "Allow" say what happens, where "on" and
/// "off" leave the reader to work out which way round the rule runs. The note
/// under each is the consequence of choosing it.
class _ToggleField extends StatelessWidget {
  const _ToggleField({
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final SettingSpec spec;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final option in spec.options)
            RadioListTile<String>(
              value: option.value,
              // ignore: deprecated_member_use
              groupValue: value,
              // ignore: deprecated_member_use
              onChanged: (v) => onChanged(v ?? value),
              title: Text(option.label),
              subtitle: option.note == null ? null : Text(option.note!),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          if (spec.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                spec.hint!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
