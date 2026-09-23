import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';
import '../domain/dashboard_models.dart';

/// Reads the two dashboard documents (§27, §28).
///
/// Both figures come from the database — nothing here is hard-coded (§51).
class DashboardRepository {
  const DashboardRepository(this._client);

  final SupabaseClient _client;

  Future<AdminDashboard> loadAdmin(DateTime date) async {
    try {
      final response = await _client.rpc<Map<String, dynamic>>(
        'admin_dashboard',
        params: {'p_date': Fmt.isoDate(date)},
      );
      return AdminDashboard.from(response);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<OperatorDashboard> loadOperator(DateTime date) async {
    try {
      final response = await _client.rpc<Map<String, dynamic>>(
        'operator_dashboard',
        params: {'p_date': Fmt.isoDate(date)},
      );
      return OperatorDashboard.from(response);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(ref.watch(supabaseClientProvider));
});

/// The business date the dashboards are showing. Kept as a provider so a date
/// picker can be added later without touching the screens.
final dashboardDateProvider = Provider<DateTime>((ref) => DateTime.now());

final adminDashboardProvider = FutureProvider<AdminDashboard>((ref) async {
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository.loadAdmin(ref.watch(dashboardDateProvider));
});

final operatorDashboardProvider =
    FutureProvider<OperatorDashboard>((ref) async {
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository.loadOperator(ref.watch(dashboardDateProvider));
});
