import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';

/// Wastage (§24, §25).
///
/// The source matters more than the quantity. Material that never reached a
/// mixture is a genuine loss and comes off raw stock; scrap generated from
/// material already consumed does not, because that material has been counted
/// out once already. `record_wastage()` applies that rule; this layer only has
/// to make the operator's choice between the two unambiguous.
enum WastageSource {
  rawMaterialLoss('RAW_MATERIAL_LOSS', 'Material loss',
      'Spilled or contaminated before it reached a machine. Comes off raw stock.'),
  productionScrap('PRODUCTION_SCRAP', 'Production scrap',
      'Offcuts and purge from a run. Already counted out of raw stock.');

  const WastageSource(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;

  static WastageSource fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => productionScrap);
}

double _toDouble(Object? value) => switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? 0,
      _ => 0,
    };

class WastageEntry {
  const WastageEntry({
    required this.id,
    required this.entryDate,
    required this.materialName,
    required this.source,
    required this.quantity,
    required this.unit,
    required this.reusable,
    required this.createdAt,
    this.machineName,
    this.operatorName,
    this.shiftName,
    this.remarks,
  });

  final String id;
  final DateTime entryDate;
  final String materialName;
  final WastageSource source;
  final double quantity;
  final String unit;
  final bool reusable;
  final DateTime createdAt;
  final String? machineName;
  final String? operatorName;
  final String? shiftName;
  final String? remarks;

  factory WastageEntry.from(Map<String, dynamic> row) => WastageEntry(
        id: row['id'] as String? ?? '',
        entryDate: DateTime.tryParse(row['entry_date'] as String? ?? '') ??
            DateTime.now(),
        materialName: row['raw_material_name'] as String? ?? '—',
        source: WastageSource.fromWire(row['source'] as String?),
        quantity: _toDouble(row['quantity']),
        unit: row['unit'] as String? ?? 'kg',
        reusable: row['reusable'] as bool? ?? false,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        machineName: row['machine_name'] as String?,
        operatorName: row['operator_name'] as String?,
        shiftName: row['shift_name'] as String?,
        remarks: row['remarks'] as String?,
      );
}

class WastageRepository {
  const WastageRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> record({
    required String rawMaterialId,
    required WastageSource source,
    required double quantity,
    required String clientRef,
    bool reusable = false,
    String? machineId,
    String? shiftId,
    DateTime? entryDate,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'record_wastage',
        params: {
          'p_raw_material_id': rawMaterialId,
          'p_source': source.wire,
          'p_quantity': quantity,
          'p_client_ref': clientRef,
          'p_reusable': reusable,
          'p_machine_id': machineId,
          'p_shift_id': shiftId,
          'p_entry_date': Fmt.isoDate(entryDate ?? DateTime.now()),
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<WastageEntry>> list({int limit = 100}) async {
    try {
      final rows = await _client
          .from('v_wastage_entries')
          .select()
          .order('created_at', ascending: false)
          .limit(limit);
      return rows.map(WastageEntry.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final wastageRepositoryProvider = Provider<WastageRepository>((ref) {
  return WastageRepository(ref.watch(supabaseClientProvider));
});

final wastageEntriesProvider = FutureProvider<List<WastageEntry>>((ref) async {
  return ref.watch(wastageRepositoryProvider).list();
});
