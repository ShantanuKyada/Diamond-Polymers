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
