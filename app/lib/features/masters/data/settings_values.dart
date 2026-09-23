import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import 'masters_repository.dart';

/// Values the factory configures for itself, read from `app_settings`.
///
/// Nothing that an owner might want to change belongs in a string literal in a
/// widget. These providers give every screen one place to ask, with a sensible
/// fallback so a setting that has never been saved cannot blank out a label.
///
/// Row level security lets any signed-in user read `app_settings`, so operator
/// screens can use these too; only an administrator can change them.

/// Every setting as a map, loaded once and shared.
final settingsMapProvider = Provider<Map<String, String>>((ref) {
  final rows = ref.watch(settingsProvider).value;
  if (rows == null) return const {};
  return {for (final row in rows) row.key: row.value};
});

/// A setting by key, or [fallback] when it is missing or blank.
String settingOr(Ref ref, String key, String fallback) {
  final value = ref.watch(settingsMapProvider)[key]?.trim();
  return (value == null || value.isEmpty) ? fallback : value;
}

/// The factory's name, shown in the app bar and on reports.
///
/// Falls back to the build-time value, which is what the sign-in screen uses —
/// settings cannot be read until somebody is signed in.
final factoryNameProvider = Provider<String>(
  (ref) => settingOr(ref, 'factory_name', AppConfig.factoryName),
);

/// The unit production wastage is measured in (A7).
final wastageUnitProvider = Provider<String>(
  (ref) => settingOr(ref, 'production_wastage_unit', 'kg'),
);

/// The currency payroll figures are shown in.
final currencySymbolProvider = Provider<String>(
  (ref) => settingOr(ref, 'currency_symbol', '₹'),
);
