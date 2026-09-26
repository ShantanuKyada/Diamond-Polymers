import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';
import '../../auth/presentation/session_controller.dart';
import '../domain/production.dart';

/// Production entries and history (§18, §29, §49).
///
/// Writes go through `record_production()`, which creates the entry and raises
/// finished-goods stock in one transaction. Reads come from
/// `v_production_entries`; row level security already narrows that to the
/// signed-in operator's own rows, so the operator history needs no extra filter
/// to be safe — the filter below is for the admin screen.
class ProductionRepository {
  const ProductionRepository(this._client);

  final SupabaseClient _client;

  Future<ProductionResult> record({
    required String machineId,
    required String shiftId,
    required String pipeTypeId,
    required String pipeSizeId,
    required int bundleQuantity,
    required String clientRef,
    DateTime? entryDate,
    double wastageQuantity = 0,
    String? remarks,
    int bagQuantity = 0,
    bool wastageUsed = false,
    double? wastageUsedKg,
    // A37: the batch this run came out of. Required by the database unless
    // `production_requires_batch` is turned off, so the screen must supply it.
    String? mixtureEntryId,
  }) async {
    try {
      final response = await _client.rpc<Map<String, dynamic>>(
        'record_production',
        params: {
          'p_machine_id': machineId,
          'p_shift_id': shiftId,
          'p_pipe_type_id': pipeTypeId,
          'p_pipe_size_id': pipeSizeId,
          'p_bundle_quantity': bundleQuantity,
          'p_client_ref': clientRef,
          'p_entry_date': Fmt.isoDate(entryDate ?? DateTime.now()),
          'p_wastage_quantity': wastageQuantity,
          'p_remarks': remarks,
          'p_bag_quantity': bagQuantity,
          'p_wastage_used': wastageUsed,
          'p_wastage_used_kg': wastageUsed ? wastageUsedKg : null,
          'p_mixture_entry_id': mixtureEntryId,
        },
      );
      return ProductionResult.from(response);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<ProductionEntry>> list({
    ProductionFilter filter = const ProductionFilter(),
    int limit = 100,
    bool oldestFirst = false,
  }) async {
    try {
      var query = _client.from('v_production_entries').select();

      if (filter.from != null) {
        query = query.gte('entry_date', Fmt.isoDate(filter.from!));
      }
      if (filter.to != null) {
        query = query.lte('entry_date', Fmt.isoDate(filter.to!));
      }
      if (filter.machineId != null) {
        query = query.eq('machine_id', filter.machineId!);
      }
      if (filter.operatorId != null) {
        query = query.eq('operator_id', filter.operatorId!);
      }
      if (filter.pipeTypeId != null) {
        query = query.eq('pipe_type_id', filter.pipeTypeId!);
      }

      final rows = await query
          .order('entry_date', ascending: oldestFirst)
          .order('created_at', ascending: oldestFirst)
          .limit(limit);
      return rows.map(ProductionEntry.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  return ProductionRepository(ref.watch(supabaseClientProvider));
});

/// The admin list, keyed by its filter so each combination is cached separately.
final productionRecordsProvider =
    FutureProvider.family<List<ProductionEntry>, ProductionFilter>(
        (ref, filter) async {
  return ref.watch(productionRepositoryProvider).list(filter: filter);
});

/// How far back My Entries looks: today and the six days before it (A32).
const myEntriesDays = 7;

/// The first day My Entries shows. Date-only, so the provider key is stable
/// for the whole day rather than changing on every rebuild.
DateTime myEntriesSince([DateTime? now]) {
  final today = now ?? DateTime.now();
  return DateTime(today.year, today.month, today.day)
      .subtract(const Duration(days: myEntriesDays - 1));
}

/// The signed-in operator's own entries for the last week, oldest first (§29,
/// A32). Row level security already limits the rows to this operator; the
/// filter says so explicitly as well.
final myProductionProvider = FutureProvider<List<ProductionEntry>>((ref) async {
  final me = ref.watch(currentUserProvider);
  if (me == null) return const [];

  return ref.watch(productionRepositoryProvider).list(
        filter: ProductionFilter(
          operatorId: me.profileId,
          from: myEntriesSince(),
        ),
        limit: 200,
        oldestFirst: true,
      );
});
