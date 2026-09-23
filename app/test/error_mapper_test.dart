import 'package:diamond_polymers/core/error/app_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// §45: a factory worker must never see "PostgrestException: 23505...".
///
/// The database raises documented SQLSTATEs, so these tests pin the contract
/// between 0002_helpers.sql and the UI.
void main() {
  group('business errors raised by our own functions', () {
    test('DP001 becomes an insufficient-stock error, message passed through',
        () {
      const raised = PostgrestException(
        message: 'Insufficient Raizin stock. Available: 10 kg.',
        code: 'DP001',
        details: '{"name":"Raizin","available":10,"requested":15,"unit":"kg"}',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.insufficientStock);
      // §16 requires this exact sentence reach the operator.
      expect(mapped.message, 'Insufficient Raizin stock. Available: 10 kg.');
      expect(mapped.data['available'], 10);
      expect(mapped.data['requested'], 15);
      expect(mapped.isRetryable, isFalse,
          reason: 'retrying the same oversized draw cannot succeed');
    });

    test('DP002 carries the remaining bundle count for the dispatch screen', () {
      const raised = PostgrestException(
        message: 'Insufficient finished-goods stock. Available: 50 bundles.',
        code: 'DP002',
        details: '{"available":50,"requested":60,"label":"Type A — Size 2"}',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.insufficientStock);
      expect(mapped.data['available'], 50);
      expect(mapped.data['label'], 'Type A — Size 2');
    });

    test('DP004 is an authorisation failure', () {
      const raised = PostgrestException(
        message: 'This action requires an administrator account.',
        code: 'DP004',
      );

      expect(ErrorMapper.map(raised).kind, AppErrorKind.authorization);
    });

    test('DP006 (unassigned machine) is an authorisation failure', () {
      const raised = PostgrestException(
        message: 'You are not currently assigned to that machine.',
        code: 'DP006',
      );

      expect(ErrorMapper.map(raised).kind, AppErrorKind.authorization);
    });

    test('DP005 is a validation failure', () {
      const raised = PostgrestException(
        message: 'Bundles produced must be greater than zero.',
        code: 'DP005',
        details: '{"field":"bundle_quantity"}',
      );

      final mapped = ErrorMapper.map(raised);
      expect(mapped.kind, AppErrorKind.validation);
      expect(mapped.data['field'], 'bundle_quantity');
    });

    test('DP007 reports a deliberately unconfigured feature', () {
      const raised = PostgrestException(
        message: 'Reusable-wastage substitution is not configured yet.',
        code: 'DP007',
      );

      expect(ErrorMapper.map(raised).kind, AppErrorKind.notConfigured);
    });

    test('DP008 (no bundle weight) is a configuration gap, not bad input', () {
      const raised = PostgrestException(
        message: 'No bundle weight is configured for Type A — Size 1. An '
            'administrator must add it under Products before this can be '
            'recorded.',
        code: 'DP008',
        details: '{"label":"Type A — Size 1"}',
      );

      final mapped = ErrorMapper.map(raised);

      // The operator cannot fix this by retyping, so the UI must point at an
      // administrator rather than highlighting a field.
      expect(mapped.kind, AppErrorKind.notConfigured);
      expect(mapped.data['label'], 'Type A — Size 1');
      expect(mapped.isRetryable, isFalse);
    });

    test('DP009 (machine cannot run that product) is validation', () {
      const raised = PostgrestException(
        message: 'Machine 1 is not set up to run Type B — Size 3.',
        code: 'DP009',
        details: '{"machine_id":"m","pipe_product_id":"p"}',
      );

      final mapped = ErrorMapper.map(raised);

      // Recoverable at the form: the operator picks a product the line runs.
      expect(mapped.kind, AppErrorKind.validation);
      expect(mapped.message, 'Machine 1 is not set up to run Type B — Size 3.');
    });

    test('DP010 (advance over-recovery) reads as insufficient balance', () {
      const raised = PostgrestException(
        message: 'Ravi Kumar has only 1200.00 outstanding in advances.',
        code: 'DP010',
        details: '{"outstanding":1200,"requested":5000}',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.insufficientStock);
      expect(mapped.data['outstanding'], 1200);
      expect(mapped.isRetryable, isFalse);
    });

    test('DP011 (finalised payroll) is a conflict, not bad input', () {
      const raised = PostgrestException(
        message: 'Payroll for Jun 2026 is already finalised and cannot be '
            'recalculated.',
        code: 'DP011',
        details: '{"status":"FINALISED"}',
      );

      final mapped = ErrorMapper.map(raised);

      // Nothing is wrong with the request — it arrived too late. The UI should
      // say the month is closed, not highlight a field.
      expect(mapped.kind, AppErrorKind.conflict);
      expect(mapped.data['status'], 'FINALISED');
    });
  });

  group('database errors the user should never read verbatim', () {
    test('an RLS denial becomes a plain permission sentence', () {
      const raised = PostgrestException(
        message: 'new row violates row-level security policy for table "x"',
        code: '42501',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.authorization);
      expect(mapped.message, "You don't have permission to do that.");
      expect(mapped.message, isNot(contains('row-level security')));
    });

    test('a unique violation does not leak the constraint name', () {
      const raised = PostgrestException(
        message:
            'duplicate key value violates unique constraint "production_entries_client_ref_key"',
        code: '23505',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.validation);
      expect(mapped.message, isNot(contains('23505')));
      expect(mapped.message, isNot(contains('constraint')));
      // The raw text is preserved for the log, just not for the screen.
      expect(mapped.technicalDetail, isNotNull);
    });

    test('an unrecognised Postgres error yields a generic sentence', () {
      const raised = PostgrestException(
        message: 'deadlock detected',
        code: '40P01',
      );

      final mapped = ErrorMapper.map(raised);

      expect(mapped.kind, AppErrorKind.unexpected);
      expect(mapped.message, isNot(contains('deadlock')));
      expect(mapped.technicalDetail, contains('40P01'));
    });
  });

  group('authentication', () {
    test('bad credentials produce a specific, non-technical message', () {
      final mapped = ErrorMapper.map(
        const AuthException('Invalid login credentials'),
      );

      expect(mapped.kind, AppErrorKind.authentication);
      expect(mapped.message, 'Incorrect email or password.');
    });
  });

  group('connectivity (§46)', () {
    test('a socket failure is reported as a connection problem and is retryable',
        () {
      final mapped = ErrorMapper.map(
        Exception('SocketException: Failed host lookup'),
      );

      expect(mapped.kind, AppErrorKind.network);
      expect(mapped.isRetryable, isTrue);
    });
  });

  test('an AppException passes through unchanged', () {
    const original = AppException(
      kind: AppErrorKind.validation,
      message: 'Enter a customer or destination.',
    );

    expect(identical(ErrorMapper.map(original), original), isTrue);
  });
}
