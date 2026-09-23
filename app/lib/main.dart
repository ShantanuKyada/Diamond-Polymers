import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/demo/demo_overrides.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConfig.isConfigured) {
    // Nothing in this application works without a backend, so it says so
    // instead of failing later with an opaque error (§65).
    runApp(const ConfigurationRequiredApp());
    return;
  }

  if (AppConfig.demoMode) {
    // No Supabase client is created at all, so a misconfigured demo build
    // cannot accidentally talk to a real project.
    runApp(demoScope(child: const DiamondPolymersApp()));
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(
      // Persists the session to secure storage and refreshes it on launch,
      // which is what keeps an operator signed in between shifts (§5).
      autoRefreshToken: true,
    ),
  );

  runApp(const ProviderScope(child: DiamondPolymersApp()));
}
