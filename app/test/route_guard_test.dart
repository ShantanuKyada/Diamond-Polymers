import 'package:diamond_polymers/core/routing/route_guard.dart';
import 'package:diamond_polymers/core/routing/routes.dart';
import 'package:flutter_test/flutter_test.dart';

/// §63 SECURITY: "User cannot access Admin".
///
/// These assert the client-side half of route protection. The database half is
/// RLS, which is what actually stops a determined caller — but a UI that lets
/// someone walk into an admin screen and then fails on every query is a bad
/// experience, so both halves matter.
void main() {
  group('while a stored session is being restored', () {
    test('every location is held on the splash screen', () {
      expect(
        resolveRedirect(
          session: GuardSession.restoring,
          location: AppRoute.adminDashboard.path,
        ),
        AppRoute.splash.path,
      );
    });

    test('the splash screen itself is allowed', () {
      expect(
        resolveRedirect(
          session: GuardSession.restoring,
          location: AppRoute.splash.path,
        ),
        isNull,
      );
    });
  });

  group('signed out', () {
    test('any screen redirects to login', () {
      for (final location in [
        AppRoute.adminDashboard.path,
        AppRoute.operatorHome.path,
        AppRoute.notifications.path,
        AppRoute.profile.path,
      ]) {
        expect(
          resolveRedirect(
            session: GuardSession.signedOut,
            location: location,
          ),
          AppRoute.login.path,
          reason: '$location must not be reachable while signed out',
        );
      }
    });

    test('login is allowed', () {
      expect(
        resolveRedirect(
          session: GuardSession.signedOut,
          location: AppRoute.login.path,
        ),
        isNull,
      );
    });
  });

  group('signed in as an operator', () {
    test('every admin route is refused and sent home', () {
      final adminRoutes = AppRoute.values
          .where((r) => r.path.startsWith('/admin'))
          .toList();

      // Guards against someone adding an admin screen and forgetting to
      // protect it: the check is prefix-based, so this covers future routes.
      expect(adminRoutes, isNotEmpty);

      for (final route in adminRoutes) {
        expect(
          resolveRedirect(
            session: GuardSession.operator,
            location: route.path,
          ),
          AppRoute.operatorHome.path,
          reason: '${route.path} must be refused to an operator',
        );
      }
    });

    test('operator routes are allowed', () {
      expect(
        resolveRedirect(
          session: GuardSession.operator,
          location: AppRoute.productionEntry.path,
        ),
        isNull,
      );
    });

    test('Material Entry is refused to an operator (A30)', () {
      expect(AppRoute.mixtureEntry.path, startsWith('/admin'));
      expect(
        resolveRedirect(
          session: GuardSession.operator,
          location: AppRoute.mixtureEntry.path,
        ),
        AppRoute.operatorHome.path,
      );
    });

    test('and allowed to an admin', () {
      expect(
        resolveRedirect(
          session: GuardSession.admin,
          location: AppRoute.mixtureEntry.path,
        ),
        isNull,
      );
    });

    test('shared routes are allowed', () {
      expect(
        resolveRedirect(
          session: GuardSession.operator,
          location: AppRoute.notifications.path,
        ),
        isNull,
      );
    });

    test('landing on login redirects to the operator home', () {
      expect(
        resolveRedirect(
          session: GuardSession.operator,
          location: AppRoute.login.path,
        ),
        AppRoute.operatorHome.path,
      );
    });
  });

  group('signed in as an admin', () {
    test('admin routes are allowed', () {
      expect(
        resolveRedirect(
          session: GuardSession.admin,
          location: AppRoute.adminInventory.path,
        ),
        isNull,
      );
    });

    test('operator entry screens redirect to the admin dashboard', () {
      expect(
        resolveRedirect(
          session: GuardSession.admin,
          location: AppRoute.productionEntry.path,
        ),
        AppRoute.adminDashboard.path,
      );
    });

    test('landing on splash redirects to the dashboard', () {
      expect(
        resolveRedirect(
          session: GuardSession.admin,
          location: AppRoute.splash.path,
        ),
        AppRoute.adminDashboard.path,
      );
    });
  });
}
