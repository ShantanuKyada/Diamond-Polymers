import 'routes.dart';

/// The signed-in state the guard reasons about, independent of Riverpod and
/// go_router so it can be exercised directly in tests.
enum GuardSession { restoring, signedOut, operator, admin }

/// Decides where a navigation should actually land.
///
/// Returns the path to redirect to, or null to allow the navigation as-is.
///
/// This is the client half of §5's requirement that an operator cannot reach
/// admin functionality by navigating to it manually. The database half is RLS
/// (§38), which is what makes the rule real — this only keeps the UI honest.
String? resolveRedirect({
  required GuardSession session,
  required String location,
}) {
  // Hold on the splash while a stored session is being restored, rather than
  // flashing the login form at somebody who is already signed in.
  if (session == GuardSession.restoring) {
    return location == AppRoute.splash.path ? null : AppRoute.splash.path;
  }

  if (session == GuardSession.signedOut) {
    return location == AppRoute.login.path ? null : AppRoute.login.path;
  }

  final isAdmin = session == GuardSession.admin;
  final home =
      isAdmin ? AppRoute.adminDashboard.path : AppRoute.operatorHome.path;

  // Signed in but sitting on a pre-auth screen.
  if (location == AppRoute.login.path || location == AppRoute.splash.path) {
    return home;
  }

  // The guard proper. Note this is prefix-based, so any admin screen added
  // under /admin is protected without anyone remembering to add a check.
  if (!isAdmin && location.startsWith('/admin')) return home;
  if (isAdmin && location.startsWith('/op')) return home;

  return null;
}
