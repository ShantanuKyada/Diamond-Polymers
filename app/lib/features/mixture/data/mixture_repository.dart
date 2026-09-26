import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';

/// Recording a mixture batch (§15, §16, Phase 3).
///
/// One call, one transaction. `consume_raw_materials()` validates the entire
/// basket before deducting any of it, so a batch short on one material deducts
/// none of the others — which is what §16 actually demands and what a
/// line-by-line client loop could never guarantee.
///
/// `clientRef` is the idempotency key. The same reference returns the entry that
/// already exists rather than creating a second one, so a double tap, or a
/// timeout followed by a retry, cannot post the batch twice. The caller must
/// keep the reference across retries and only mint a new one for a genuinely
/// new batch.
class MixtureRepository {
  const MixtureRepository(this._client);

  final SupabaseClient _client;

  Future<MixtureResult> consume({
    required String machineId,
    required String shiftId,
    required List<MixtureLine> lines,
    required String clientRef,
    DateTime? entryDate,
    String? remarks,
  }) async {
    try {
      final response = await _client.rpc<Map<String, dynamic>>(
        'consume_raw_materials',
        params: {
          'p_machine_id': machineId,
          'p_shift_id': shiftId,
          'p_lines': [
            for (final line in lines)
              {
                'raw_material_id': line.rawMaterialId,
                'quantity': line.quantity,
              },
          ],
          'p_client_ref': clientRef,
          'p_entry_date': Fmt.isoDate(entryDate ?? DateTime.now()),
          'p_remarks': remarks,
        },
      );
      return MixtureResult.from(response);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Recent batches on a machine, newest first (A37).
  ///
  /// Only the machine is filtered on, deliberately: a machine charged near the
  /// end of a shift is often run out in the next, and the Night shift crosses
  /// midnight every time. Narrowing to today or to one shift would hide the
  /// batch the operator is actually standing in front of.
  Future<List<MixtureBatch>> recentBatches({
    required String machineId,
    int limit = 15,
  }) async {
    try {
      final rows = await _client
          .from('v_batch_yield')
          .select()
          .eq('machine_id', machineId)
          .order('created_at', ascending: false)
          .limit(limit);
      return rows.map(MixtureBatch.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

class MixtureLine {
  const MixtureLine({required this.rawMaterialId, required this.quantity});

  final String rawMaterialId;
  final double quantity;
}

class MixtureResult {
  const MixtureResult({
    required this.id,
    required this.duplicate,
    required this.totalQuantity,
  });

  final String id;

  /// True when the reference had already been used — the batch was recorded by
  /// an earlier attempt, so this one changed nothing.
  final bool duplicate;
  final double totalQuantity;

  factory MixtureResult.from(Map<String, dynamic> row) => MixtureResult(
        id: row['id'] as String? ?? '',
        duplicate: row['duplicate'] as bool? ?? false,
        totalQuantity: switch (row['total_quantity']) {
          final num n => n.toDouble(),
          final String s => double.tryParse(s) ?? 0,
          _ => 0,
        },
      );
}

final mixtureRepositoryProvider = Provider<MixtureRepository>((ref) {
  return MixtureRepository(ref.watch(supabaseClientProvider));
});

/// A material batch an operator can attribute production to (A37).
///
/// Read from `v_batch_yield`, which already knows what was charged and how many
/// runs have come off it. `runs` is what lets the screen say "this batch has
/// already produced once" rather than silently allowing a double-count the
/// operator did not intend.
class MixtureBatch {
  const MixtureBatch({
    required this.id,
    required this.entryDate,
    required this.machineId,
    required this.chargedKg,
    required this.runs,
    required this.createdAt,
    this.shiftName,
    this.operatorName,
  });

  final String id;
  final DateTime entryDate;
  final String machineId;
  final double chargedKg;
  final int runs;
  final DateTime createdAt;
  final String? shiftName;
  final String? operatorName;

  bool get hasProduction => runs > 0;

  factory MixtureBatch.from(Map<String, dynamic> row) => MixtureBatch(
        id: row['mixture_entry_id'] as String,
        entryDate: DateTime.tryParse(row['entry_date'] as String? ?? '') ??
            DateTime.now(),
        machineId: row['machine_id'] as String,
        chargedKg: switch (row['charged_kg']) {
          final num n => n.toDouble(),
          final String s => double.tryParse(s) ?? 0,
          _ => 0,
        },
        runs: switch (row['runs']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s) ?? 0,
          _ => 0,
        },
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        shiftName: row['shift_name'] as String?,
        operatorName: row['operator_name'] as String?,
      );
}

/// The batches offered on the production screen, for one machine.
final machineBatchesProvider =
    FutureProvider.family<List<MixtureBatch>, String>((ref, machineId) {
  return ref.watch(mixtureRepositoryProvider).recentBatches(machineId: machineId);
});
