import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every screen caps its content width (A40).
///
/// This is a source check, not a widget test, because the failure it guards
/// against is *absence*: a screen that nobody wrapped reads fine on a phone and
/// stretches across a tablet, and no test of that screen would notice. One
/// screen was already missed this way — `body: const TabBarView(...)`, where
/// the `const` defeated the pass that wrapped the others.
///
/// A Scaffold is exempt only when it is already centred and constrained, or
/// when it is the frame around other screens rather than a screen itself. Each
/// exemption is named, so adding one is a decision rather than an oversight.
void main() {
  const exempt = <String, String>{
    'lib/features/shell/app_shell.dart':
        'the frame itself — it holds the rail and the screens inside it',
    'lib/core/routing/app_router.dart':
        'the route-not-found screen: Center with a min-size Column',
    'lib/app.dart':
        'the configuration-error screen: Center with a ConstrainedBox',
    'lib/features/auth/presentation/login_screen.dart':
        'already Center + ConstrainedBox, which is the same thing by hand',
  };

  test('every screen with a Scaffold constrains its body', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final source = entity.readAsStringSync();

      if (!source.contains('Scaffold(')) continue;
      if (exempt.containsKey(path)) continue;
      if (source.contains('PageBody')) continue;

      offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These screens have a Scaffold but no PageBody, so their content '
          'stretches the full width of a tablet. Wrap the body in PageBody, or '
          'add the file to `exempt` above with the reason why it does not need '
          'it.\n  ${offenders.join('\n  ')}',
    );
  });
}
