import 'dart:convert';
import 'dart:developer' as developer;

import 'package:supabase_flutter/supabase_flutter.dart';

/// What went wrong, in terms the UI can branch on.
enum AppErrorKind {
  /// No usable connection, or the request timed out.
  network,

  /// Signed out, wrong password, or expired session.
  authentication,

  /// Signed in, but not allowed to do this (DP004, DP006, an RLS denial).
  authorization,

  /// The user's input was rejected (DP005).
  validation,

  /// Not enough stock to complete the movement (DP001, DP002, DP003).
  insufficientStock,

  /// Master data an administrator has to fill in before the operator can
  /// proceed (DP007, DP008). Distinct from [validation]: the operator did
  /// nothing wrong and cannot fix it by retyping.
  notConfigured,

  /// The record is closed to further change (DP011 — a finalised payroll
  /// month). Nothing is wrong with the request; it simply arrived too late.
  conflict,

  /// Anything else, including genuine server faults.
  unexpected,
}

/// A failure that is safe to show a factory worker.
///
/// §45: the operator sees [message]; the raw driver error is kept in
/// [technicalDetail] for the log and never rendered.
class AppException implements Exception {
  const AppException({
    required this.kind,
    required this.message,
    this.technicalDetail,
    this.data = const {},
  });

  final AppErrorKind kind;

  /// A complete, plain sentence. Shown directly to the user.
  final String message;

  /// Driver-level text for diagnostics. Never rendered.
  final String? technicalDetail;

  /// Structured payload from the database `DETAIL` field — available stock,
  /// the offending field name, and so on.
  final Map<String, dynamic> data;

  /// True when retrying the identical request could plausibly succeed.
  bool get isRetryable =>
      kind == AppErrorKind.network || kind == AppErrorKind.unexpected;

  @override
  String toString() =>
      'AppException(${kind.name}: $message${technicalDetail == null ? '' : ' | $technicalDetail'})';
}

/// Translates driver exceptions into [AppException].
///
/// The database raises documented SQLSTATEs (see 0002_helpers.sql), so the
/// mapping is a table lookup rather than string-matching Postgres internals.
class ErrorMapper {
  const ErrorMapper._();

  static const Map<String, AppErrorKind> _sqlStateKinds = {
    'DP001': AppErrorKind.insufficientStock,
    'DP002': AppErrorKind.insufficientStock,
    'DP003': AppErrorKind.insufficientStock,
    'DP004': AppErrorKind.authorization,
    'DP005': AppErrorKind.validation,
    'DP006': AppErrorKind.authorization,
    'DP007': AppErrorKind.notConfigured,
    // No bundle weight set for this product. Only an admin can resolve it, so
    // it is a configuration gap rather than bad input.
    'DP008': AppErrorKind.notConfigured,
    // The machine is not set up to run the chosen product. The operator can fix
    // this by picking a different product, so it is validation.
    'DP009': AppErrorKind.validation,
    // Recovering more advance than is outstanding. Same shape as running out of
    // stock: the request is valid, there simply is not enough of it.
    'DP010': AppErrorKind.insufficientStock,
    // The payroll month is finalised and will not accept changes.
    'DP011': AppErrorKind.conflict,
    // Production recorded without the material batch it came out of (A37).
    // Validation rather than notConfigured: the operator can fix it here and
    // now by picking a batch, or by recording the material first.
    'DP012': AppErrorKind.validation,
  };

  static AppException map(Object error, [StackTrace? stackTrace]) {
    developer.log(
      'Mapping error',
      name: 'diamond_polymers',
      error: error,
      stackTrace: stackTrace,
    );

    if (error is AppException) return error;

    if (error is AuthException) {
      return AppException(
        kind: AppErrorKind.authentication,
        message: _authMessage(error),
        technicalDetail: error.message,
      );
    }

    if (error is PostgrestException) {
      final kind = _sqlStateKinds[error.code];

      if (kind != null) {
        // Messages raised by our own functions are already written for the
        // factory floor, so they are passed through verbatim.
        return AppException(
          kind: kind,
          message: error.message,
          technicalDetail: 'SQLSTATE ${error.code}',
          data: _parseDetail(error.details),
        );
      }

      // A row-level-security denial. The user is signed in but the policy said
      // no — usually an operator reaching for an admin screen.
      if (error.code == '42501' || error.message.contains('row-level security')) {
        return const AppException(
          kind: AppErrorKind.authorization,
          message: "You don't have permission to do that.",
          technicalDetail: 'RLS denial',
        );
      }

      if (error.code == '23505') {
        return const AppException(
          kind: AppErrorKind.validation,
          message: 'That record already exists.',
          technicalDetail: 'unique_violation',
        );
      }

      return AppException(
        kind: AppErrorKind.unexpected,
        message: 'This could not be saved. Please check the details and '
            'try again.',
        technicalDetail: '${error.code}: ${error.message}',
      );
    }

    final text = error.toString();
    if (_looksLikeNetworkFailure(text)) {
      return AppException(
        kind: AppErrorKind.network,
        message: 'No connection. Check the network and try again.',
        technicalDetail: text,
      );
    }

    return AppException(
      kind: AppErrorKind.unexpected,
      message: 'Something went wrong. Please try again.',
      technicalDetail: text,
    );
  }

  static String _authMessage(AuthException error) {
    final raw = error.message.toLowerCase();
    if (raw.contains('invalid login') || raw.contains('invalid credentials')) {
      return 'Incorrect email or password.';
    }
    if (raw.contains('email not confirmed')) {
      return 'This account has not been confirmed yet.';
    }
    return 'Sign-in failed. Please try again.';
  }

  static bool _looksLikeNetworkFailure(String text) {
    final lower = text.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection closed') ||
        lower.contains('connection refused') ||
        lower.contains('timeoutexception') ||
        lower.contains('clientexception');
  }

  /// The database packs structured context into `DETAIL` as a JSON string.
  static Map<String, dynamic> _parseDetail(Object? details) {
    if (details is Map<String, dynamic>) return details;
    if (details is String && details.trimLeft().startsWith('{')) {
      try {
        final Object? decoded = jsonDecode(details);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        // Diagnostics only — never worth failing a user-facing flow over.
      }
    }
    return const {};
  }
}
