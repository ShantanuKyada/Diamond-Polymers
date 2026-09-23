import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

class DiamondPolymersApp extends ConsumerWidget {
  const DiamondPolymersApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: AppConfig.factoryName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.light,
      routerConfig: router,
      // A permanent, unmissable marker on every screen. Demo figures look
      // exactly like real ones, so the app has to say which it is showing
      // (§65) — otherwise a screenshot of demo data ends up in a meeting.
      builder: (context, child) => AppConfig.demoMode
          ? _DemoBadge(child: child ?? const SizedBox.shrink())
          : child ?? const SizedBox.shrink(),
    );
  }
}

/// Shown when the Supabase credentials were not supplied at build time.
///
/// §65 forbids pretending a feature works. Without a backend nothing in this
/// app can function, so it says exactly that and exactly how to fix it, rather
/// than opening a login form that could never succeed.
class ConfigurationRequiredApp extends StatelessWidget {
  const ConfigurationRequiredApp({super.key});

  static const _command = 'flutter run \\\n'
      '  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \\\n'
      '  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY';

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.light();

    return MaterialApp(
      title: AppConfig.factoryName,
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.settings_ethernet_rounded,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Backend not configured',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'This build has no Supabase credentials, so it cannot '
                      'sign in or read any factory data. Supply them at build '
                      'time:',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectableText(
                        _command,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Only the publishable anon key belongs in the app. Never '
                      'build with a service-role key.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// A corner ribbon marking a build that is running on in-memory data.
class _DemoBadge extends StatelessWidget {
  const _DemoBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: Material(
              color: const Color(0xFFB26A00),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 5),
                child: Text(
                  'DEMO DATA',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
