import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../dashboard/domain/dashboard_models.dart';
import '../../masters/data/masters_repository.dart';
import '../domain/inventory.dart';

/// Stock reads, and the two admin movements that change it (§13, §14).
///
/// Reads come from views; writes go through `SECURITY DEFINER` RPCs, because a
/// stock movement is a balance update *and* a ledger row and the two must land
/// together. There is no INSERT policy on any of the tables underneath, so this
/// is not a convention — it is the only way in.
///
/// Both write RPCs take a `client_ref`. A retry carrying the same ref returns
/// the movement that already happened instead of posting it twice, which is
/// what makes a flaky connection on a factory floor safe (§47).
class InventoryRepository {
  const InventoryRepository(this._client);

  final SupabaseClient _client;

  Future<List<FinishedGoodsStock>> finishedGoods() async {
    return _guard(() async {
      final rows = await _client
          .from('v_finished_goods_stock')
          .select()
          .order('pipe_type_name')
          .order('sort_order');
      return rows.map(FinishedGoodsStock.from).toList(growable: false);
    });
  }

  Future<List<RecycledStock>> recycled() async {
    return _guard(() async {
      final rows =
          await _client.from('v_recycled_material_stock').select().order('name');
      return rows.map(RecycledStock.from).toList(growable: false);
    });
  }

  /// Goods received. Always a positive quantity — a correction is an
  /// adjustment, and keeping them apart keeps the ledger readable.
  Future<Map<String, dynamic>> stockIn({
    required String rawMaterialId,
    required double quantity,
    required String clientRef,
    String? remarks,
  }) async {
    return _guard(() async {
      return await _client.rpc<Map<String, dynamic>>(
        'add_raw_material_stock',
        params: {
          'p_raw_material_id': rawMaterialId,
          'p_quantity': quantity,
          'p_client_ref': clientRef,
          'p_remarks': remarks,
        },
      );
    });
  }

  /// A signed correction. Negative is allowed; the balance still cannot go
  /// below zero, and the attempt is refused rather than clamped.
  Future<Map<String, dynamic>> adjust({
    required String rawMaterialId,
    required double delta,
    required String clientRef,
    String? remarks,
  }) async {
    return _guard(() async {
      return await _client.rpc<Map<String, dynamic>>(
        'adjust_raw_material_stock',
        params: {
          'p_raw_material_id': rawMaterialId,
          'p_delta': delta,
          'p_client_ref': clientRef,
          'p_remarks': remarks,
        },
      );
    });
  }

  Future<Map<String, dynamic>> adjustFinishedGoods({
    required String pipeTypeId,
    required String pipeSizeId,
    required int delta,
    required String clientRef,
    String? remarks,
  }) async {
    return _guard(() async {
      return await _client.rpc<Map<String, dynamic>>(
        'adjust_finished_goods_stock',
        params: {
          'p_pipe_type_id': pipeTypeId,
          'p_pipe_size_id': pipeSizeId,
          'p_delta': delta,
          'p_client_ref': clientRef,
          'p_remarks': remarks,
        },
      );
    });
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  return InventoryRepository(ref.watch(supabaseClientProvider));
});

final finishedGoodsProvider = FutureProvider<List<FinishedGoodsStock>>((ref) {
  return ref.watch(inventoryRepositoryProvider).finishedGoods();
});

final recycledStockProvider = FutureProvider<List<RecycledStock>>((ref) {
  return ref.watch(inventoryRepositoryProvider).recycled();
});

/// Refreshes every stock view at once. A movement can change more than one of
/// them — shredding moves bundles out and regrind in — so refreshing only the
/// list that was on screen would leave the others quietly stale.
void invalidateStock(WidgetRef ref) {
  ref
    ..invalidate(rawMaterialsProvider)
    ..invalidate(finishedGoodsProvider)
    ..invalidate(recycledStockProvider)
    ..invalidate(productsProvider);
}
