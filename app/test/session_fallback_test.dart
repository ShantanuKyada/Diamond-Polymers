import 'package:diamond_polymers/features/auth/domain/app_user.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session must survive a database that is older than the app (A41).
///
/// This is the failure that actually happened: the app asked for the
/// `employee_types` relationship, which arrives in migration 0022, against a
/// database still at 0021. PostgREST could not resolve it, the profile load
/// threw, and nobody could sign in — including the administrator who would have
/// gone and applied the migration.
///
/// The repository now retries without the role. These pin what the session
/// makes of each shape of row, which is the part that decides whether somebody
/// gets in.
void main() {
  const base = {
    'id': 'p1',
    'auth_user_id': 'a1',
    'name': 'Factory Admin',
    'employee_code': 'EMP-001',
    'role': 'ADMIN',
    'active': true,
    'phone': null,
  };

  test('a row with its role embedded reads the role', () {
    final user = AppUser.fromProfileRow({
      ...base,
      'employee_types': {
        'code': 'OFFICE',
        'name': 'Office',
        'runs_machines': false,
      },
    });

    expect(user.name, 'Factory Admin');
    expect(user.employeeTypeName, 'Office');
    expect(user.runsMachines, isFalse);
  });

  test('a row without one still signs in', () {
    // The fallback shape: only the columns profiles has had since 0001.
    final user = AppUser.fromProfileRow(base);

    expect(user.name, 'Factory Admin');
    expect(user.isAdmin, isTrue);
    expect(user.active, isTrue);
  });

  test('and reads as running machines, which is what everybody was before '
      'roles existed', () {
    final user = AppUser.fromProfileRow(base);

    // Two tabs somebody may not be able to use is a far smaller problem than
    // nobody being able to sign in. The database still refuses a run from a
    // role that does not run machines, and says why.
    expect(user.runsMachines, isTrue);
    expect(user.employeeTypeName, 'Operator');
  });

  test('a null embed is treated as absent, not as an error', () {
    // PostgREST returns null for an embed when the related row is missing.
    final user = AppUser.fromProfileRow({...base, 'employee_types': null});

    expect(user.runsMachines, isTrue);
    expect(user.employeeTypeName, 'Operator');
  });

  test('a deactivated person is still recognisable, so the message can say so',
      () {
    final user = AppUser.fromProfileRow({...base, 'active': false});

    expect(user.active, isFalse);
    expect(user.name, 'Factory Admin');
  });
}
