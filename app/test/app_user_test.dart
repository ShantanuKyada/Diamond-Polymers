import 'package:diamond_polymers/features/auth/domain/app_user.dart';
import 'package:flutter_test/flutter_test.dart';

/// Role resolution — the value every guard, screen and RLS policy keys off (§6).
void main() {
  group('UserRole', () {
    test('maps the wire values used by the user_role enum', () {
      expect(UserRole.fromWire('ADMIN'), UserRole.admin);
      expect(UserRole.fromWire('OPERATOR'), UserRole.operator);
    });

    test('fails closed for anything unexpected', () {
      // A null, unknown or wrongly cased role must never resolve to admin.
      expect(UserRole.fromWire(null), UserRole.operator);
      expect(UserRole.fromWire('SUPERUSER'), UserRole.operator);
      expect(UserRole.fromWire('admin'), UserRole.operator);
      expect(UserRole.fromWire(''), UserRole.operator);
    });
  });

  group('AppUser.fromProfileRow', () {
    test('reads a complete profile row', () {
      final user = AppUser.fromProfileRow(const {
        'id': 'p-1',
        'auth_user_id': 'auth-1',
        'name': 'Ravi Kumar',
        'employee_code': 'EMP-101',
        'role': 'OPERATOR',
        'active': true,
        'phone': '9876543210',
      });

      expect(user.profileId, 'p-1');
      expect(user.name, 'Ravi Kumar');
      expect(user.employeeCode, 'EMP-101');
      expect(user.role, UserRole.operator);
      expect(user.isAdmin, isFalse);
      expect(user.active, isTrue);
    });

    test('an admin row resolves to admin', () {
      final user = AppUser.fromProfileRow(const {
        'id': 'p-0',
        'auth_user_id': 'auth-0',
        'name': 'Factory Admin',
        'employee_code': 'EMP-001',
        'role': 'ADMIN',
        'active': true,
      });

      expect(user.isAdmin, isTrue);
      expect(user.phone, isNull);
    });

    test('a row missing active defaults to inactive rather than active', () {
      // Failing closed again: a malformed row must not yield a usable account.
      final user = AppUser.fromProfileRow(const {
        'id': 'p-2',
        'name': 'Someone',
        'employee_code': 'EMP-999',
        'role': 'OPERATOR',
      });

      expect(user.active, isFalse);
    });
  });

  group('initials', () {
    test('uses first and last name', () {
      expect(_named('Ravi Kumar').initials, 'RK');
      expect(_named('Imran Ahmed Shaikh').initials, 'IS');
    });

    test('handles a single name and stray whitespace', () {
      expect(_named('Ganesh').initials, 'G');
      expect(_named('  Suresh   Patel  ').initials, 'SP');
    });

    test('never throws on an empty name', () {
      expect(_named('').initials, '?');
      expect(_named('   ').initials, '?');
    });
  });
}

AppUser _named(String name) => AppUser(
      profileId: 'p',
      authUserId: 'a',
      name: name,
      employeeCode: 'EMP-000',
      role: UserRole.operator,
      active: true,
    );
