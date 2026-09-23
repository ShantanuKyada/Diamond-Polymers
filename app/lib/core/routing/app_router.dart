import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/profile_screen.dart';
import '../../features/auth/presentation/session_controller.dart';
import '../../features/dashboard/presentation/admin_dashboard_screen.dart';
import '../../features/dashboard/presentation/operator_home_screen.dart';
import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/masters/presentation/catalog_screens.dart';
import '../../features/masters/presentation/machines_screen.dart';
import '../../features/masters/presentation/operators_screen.dart';
import '../../features/masters/presentation/products_screen.dart';
import '../../features/masters/presentation/settings_screen.dart';
import '../../features/mixture/presentation/mixture_entry_screen.dart';
import '../../features/dispatch/presentation/dispatch_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/production/presentation/production_entry_screen.dart';
import '../../features/production/presentation/production_history_screens.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/staff/presentation/staff_screens.dart';
import '../../features/wastage/presentation/wastage_screen.dart';
import '../../features/shell/admin_more_screen.dart';
import '../../features/shell/app_shell.dart';
import 'route_guard.dart';
import 'routes.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// The application router, including role-based route protection.
///
/// §5 requires that an operator cannot reach admin functionality by navigating
/// to it manually. [_guard] enforces that here; RLS enforces it again in the
/// database, so bypassing the client gains nothing (§38).
final routerProvider = Provider<GoRouter>((ref) {
  // Re-evaluates redirects whenever the session changes: sign-in, sign-out and
  // an expired refresh token all land here.
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: AppRoute.splash.path,
    refreshListenable: refresh,
    redirect: (context, state) => _guard(ref, state),
    routes: [
      GoRoute(
        path: AppRoute.splash.path,
        name: AppRoute.splash.name,
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: AppRoute.login.path,
        name: AppRoute.login.name,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoute.profile.path,
        name: AppRoute.profile.name,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: AppRoute.notifications.path,
        name: AppRoute.notifications.name,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const NotificationsScreen(),
      ),

      // ---- Admin application (§34) ------------------------------------------
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(
          navigationShell: navigationShell,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard_rounded),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.inventory_outlined),
              selectedIcon: Icon(Icons.inventory_rounded),
              label: 'Inventory',
            ),
            NavigationDestination(
              icon: Icon(Icons.factory_outlined),
              selectedIcon: Icon(Icons.factory_rounded),
              label: 'Production',
            ),
            NavigationDestination(
              icon: Icon(Icons.local_shipping_outlined),
              selectedIcon: Icon(Icons.local_shipping_rounded),
              label: 'Dispatch',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz_rounded),
              label: 'More',
            ),
          ],
        ),
        branches: [
          _branch(
            AppRoute.adminDashboard,
            (context, state) => const AdminDashboardScreen(),
          ),
          _branch(
            AppRoute.adminInventory,
            (context, state) => const InventoryScreen(),
          ),
          _branch(
            AppRoute.adminProduction,
            (context, state) => const ProductionRecordsScreen(),
          ),
          _branch(
            AppRoute.adminDispatch,
            (context, state) => const DispatchScreen(),
          ),
          _branch(AppRoute.adminMore, (context, state) => const AdminMoreScreen()),
        ],
      ),

      // ---- Operator application (§35) ---------------------------------------
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(
          navigationShell: navigationShell,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.add_box_outlined),
              label: 'Production',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              label: 'My Entries',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              label: 'Profile',
            ),
          ],
        ),
        branches: [
          _branch(
            AppRoute.operatorHome,
            (context, state) => const OperatorHomeScreen(),
          ),
          _branch(
            AppRoute.productionEntry,
            (context, state) => const ProductionEntryScreen(),
          ),
          _branch(
            AppRoute.myEntries,
            (context, state) => const MyEntriesScreen(),
          ),
          _branch(AppRoute.profile, (context, state) => const ProfileScreen(),
              path: '/op/profile'),
        ],
      ),

      // ---- Admin overflow destinations --------------------------------------
      ..._adminScreens({
        AppRoute.mixtureEntry: (context, state) => const MixtureEntryScreen(),
        AppRoute.adminWastage: (context, state) => const WastageScreen(),
        AppRoute.adminReports: (context, state) => const ReportsScreen(),
        AppRoute.adminStaffPunches: (context, state) => const PunchesScreen(),
        AppRoute.adminStaffSalary: (context, state) => const SalaryScreen(),
      }),

      // ---- Master data --------------------------------------------------------
      ..._adminScreens({
        AppRoute.adminMachines: (context, state) => const MachinesScreen(),
        AppRoute.adminOperators: (context, state) => const OperatorsScreen(),
        AppRoute.adminSettings: (context, state) => const SettingsScreen(),
        AppRoute.adminProducts: (context, state) => const ProductsScreen(),
        AppRoute.adminPipeTypes: (context, state) => const PipeTypesScreen(),
        AppRoute.adminPipeSizes: (context, state) => const PipeSizesScreen(),
        AppRoute.adminRawMaterials: (context, state) =>
            const RawMaterialsScreen(),
        AppRoute.adminShifts: (context, state) => const ShiftsScreen(),
      }),
    ],
  );
});

/// Real admin screens, pushed over the shell on the root navigator so they get
/// a full-height page rather than sitting inside a bottom-bar tab.
List<GoRoute> _adminScreens(
  Map<AppRoute, Widget Function(BuildContext, GoRouterState)> screens,
) {
  return [
    for (final entry in screens.entries)
      GoRoute(
        path: entry.key.path,
        name: entry.key.name,
        parentNavigatorKey: _rootNavigatorKey,
        builder: entry.value,
      ),
  ];
}

/// Builds a shell branch. Each branch gets its own navigator so pushing a detail
/// screen inside a tab does not cover the bottom bar.
StatefulShellBranch _branch(
  AppRoute route,
  Widget Function(BuildContext, GoRouterState) builder, {
  String? path,
}) {
  return StatefulShellBranch(
    routes: [
      GoRoute(
        path: path ?? route.path,
        name: path == null ? route.name : '${route.name}Operator',
        builder: builder,
      ),
    ],
  );
}

/// Bridges the session provider to the pure guard in `route_guard.dart`.
String? _guard(Ref ref, GoRouterState state) {
  final session = ref.read(sessionControllerProvider);
  final user = session.value;

  final guardSession = session.isLoading
      ? GuardSession.restoring
      : user == null
          ? GuardSession.signedOut
          : user.isAdmin
              ? GuardSession.admin
              : GuardSession.operator;

  return resolveRedirect(
    session: guardSession,
    location: state.matchedLocation,
  );
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 72,
              width: 72,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                Icons.precision_manufacturing_outlined,
                color: scheme.onPrimary,
                size: 38,
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
