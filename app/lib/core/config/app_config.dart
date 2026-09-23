/// Environment configuration (§56).
///
/// Credentials are supplied at build time and never committed:
///
/// ```
/// flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///             --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi...
/// ```
///
/// Only the publishable anon key belongs here. A service-role key would hand
/// every user of the APK full database access, so it must never be defined.
class AppConfig {
  const AppConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Shown before anyone signs in, and the fallback for the `factory_name`
  /// setting afterwards. Set it at build time for a different factory:
  /// `--dart-define=FACTORY_NAME=Acme Pipes`.
  static const String factoryName =
      String.fromEnvironment('FACTORY_NAME', defaultValue: 'Diamond Polymers');

  static const String environment =
      String.fromEnvironment('APP_ENV', defaultValue: 'development');

  /// Runs the whole UI against in-memory data, with no backend at all:
  ///
  /// ```
  /// flutter run --dart-define=DEMO_MODE=true
  /// ```
  ///
  /// For showing the app to somebody before a Supabase project exists. Every
  /// screen is labelled so demo figures can never be mistaken for real ones,
  /// and nothing entered in this mode is saved anywhere.
  static const bool demoMode =
      bool.fromEnvironment('DEMO_MODE', defaultValue: false);

  /// False until both values are supplied. The app shows an explicit
  /// configuration screen rather than crashing on a null client (§65: never
  /// pretend something works).
  ///
  /// Demo mode counts as configured because it genuinely has a data source —
  /// just not a remote one.
  static bool get isConfigured =>
      demoMode || (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty);

  static bool get isProduction => environment == 'production';
}
