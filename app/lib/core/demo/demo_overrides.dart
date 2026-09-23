import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

import '../../features/auth/data/auth_repository.dart';
import '../../features/dashboard/data/dashboard_repository.dart';
import '../../features/dispatch/data/dispatch_repository.dart';
import '../../features/inventory/data/inventory_repository.dart';
import '../../features/masters/data/masters_repository.dart';
import '../../features/mixture/data/mixture_repository.dart';
import '../../features/notifications/data/notification_repository.dart';
import '../../features/production/data/production_repository.dart';
import '../../features/staff/data/staff_repository.dart';
import '../../features/wastage/data/wastage_repository.dart';
import '../supabase/supabase_providers.dart';
import 'demo_operations.dart';
import 'demo_repositories.dart';
import 'demo_store.dart';

/// A [ProviderScope] with every repository swapped for its offline twin.
///
/// The seam is the repository layer, which is the whole reason the app has one
/// (§3): no screen, controller or router changes for demo mode, because none of
/// them ever knew where the data came from.
///
/// `authStateChangesProvider` is overridden too — it is the one provider outside
/// a repository that reaches for the Supabase client, and it would throw before
/// the first frame without a real one.
ProviderScope demoScope({required Widget child}) {
  final store = DemoStore();

  return ProviderScope(
    overrides: [
      authStateChangesProvider.overrideWith(
        (ref) => const Stream<AuthState>.empty(),
      ),
      authRepositoryProvider.overrideWith(
        (ref) => DemoAuthRepository(store),
      ),
      dashboardRepositoryProvider.overrideWith(
        (ref) => DemoDashboardRepository(store),
      ),
      inventoryRepositoryProvider.overrideWith(
        (ref) => DemoInventoryRepository(store),
      ),
      mastersRepositoryProvider.overrideWith(
        (ref) => DemoMastersRepository(store),
      ),
      mixtureRepositoryProvider.overrideWith(
        (ref) => DemoMixtureRepository(store),
      ),
      notificationRepositoryProvider.overrideWith(
        (ref) => DemoNotificationRepository(store),
      ),
      productionRepositoryProvider.overrideWith(
        (ref) => DemoProductionRepository(store),
      ),
      dispatchRepositoryProvider.overrideWith(
        (ref) => DemoDispatchRepository(store),
      ),
      wastageRepositoryProvider.overrideWith(
        (ref) => DemoWastageRepository(store),
      ),
      staffRepositoryProvider.overrideWith(
        (ref) => DemoStaffRepository(store),
      ),
    ],
    child: child,
  );
}
