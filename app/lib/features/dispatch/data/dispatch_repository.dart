import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';

/// Dispatch (§22, §23).
///
/// `create_dispatch()` validates every line against available stock before it
/// deducts any of them, then raises the remaining-stock notification. A
/// dispatch that is short on one product therefore ships nothing at all, which
/// is the only sane behaviour when a lorry is being loaded against it.

/// "gj 01-ab 1234" and "GJ01AB1234" are the same vehicle. Matches the
/// normalisation create_dispatch() applies before storing it.
String normaliseVehicle(String? value) =>
    (value ?? '').replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

int _toInt(Object? value) => switch (value) {
      final num n => n.toInt(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };

class DispatchLine {
  const DispatchLine({
    required this.pipeTypeId,
    required this.pipeSizeId,
    required this.bundleQuantity,
    this.bagQuantity = 0,
    this.pipeTypeName = '',
    this.pipeSizeName = '',
  });

  final String pipeTypeId;
  final String pipeSizeId;
  final int bundleQuantity;
  final int bagQuantity;
  final String pipeTypeName;
  final String pipeSizeName;

  String get product => '$pipeTypeName · $pipeSizeName';

  Map<String, dynamic> toJson() => {
        'pipe_type_id': pipeTypeId,
        'pipe_size_id': pipeSizeId,
        'bundle_quantity': bundleQuantity,
        'bag_quantity': bagQuantity,
      };
}

/// A dispatch with its lines, rebuilt from the flat `v_dispatch_lines` rows.
class Dispatch {
  const Dispatch({
    required this.id,
    required this.date,
    required this.customerName,
    required this.lines,
    required this.createdAt,
    this.reference,
    this.vehicleNumber,
    this.remarks,
  });

  final String id;
  final DateTime date;
  final String customerName;
  final List<DispatchLine> lines;
  final DateTime createdAt;
  final String? reference;
  final String? vehicleNumber;
  final String? remarks;

  int get totalBundles =>
      lines.fold<int>(0, (sum, line) => sum + line.bundleQuantity);

  int get totalBags =>
      lines.fold<int>(0, (sum, line) => sum + line.bagQuantity);

  /// Groups the flat view into one entry per dispatch.
  static List<Dispatch> fromRows(List<Map<String, dynamic>> rows) {
    final byId = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      byId.putIfAbsent(row['dispatch_id'] as String, () => []).add(row);
    }

    final dispatches = <Dispatch>[];
    for (final entry in byId.entries) {
      final head = entry.value.first;
      dispatches.add(Dispatch(
        id: entry.key,
        date: DateTime.tryParse(head['dispatch_date'] as String? ?? '') ??
            DateTime.now(),
        customerName: head['customer_name'] as String? ?? '—',
        reference: head['reference'] as String?,
        vehicleNumber: head['vehicle_number'] as String?,
        remarks: head['remarks'] as String?,
        createdAt: DateTime.tryParse(head['created_at'] as String? ?? '') ??
            DateTime.now(),
        lines: [
          for (final line in entry.value)
            DispatchLine(
              pipeTypeId: line['pipe_type_id'] as String? ?? '',
              pipeSizeId: line['pipe_size_id'] as String? ?? '',
              pipeTypeName: line['pipe_type_name'] as String? ?? '—',
              pipeSizeName: line['pipe_size_name'] as String? ?? '—',
              bundleQuantity: _toInt(line['bundle_quantity']),
              bagQuantity: _toInt(line['bag_quantity']),
            ),
        ],
      ));
    }

    dispatches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return dispatches;
  }
}

class DispatchResult {
  const DispatchResult({
    required this.id,
    required this.duplicate,
    required this.totalBundles,
    this.totalBags = 0,
  });

  final String id;
  final bool duplicate;
  final int totalBundles;
  final int totalBags;

  factory DispatchResult.from(Map<String, dynamic> row) => DispatchResult(
        id: row['id'] as String? ?? '',
        duplicate: row['duplicate'] as bool? ?? false,
        totalBundles: _toInt(row['total_bundles']),
        totalBags: _toInt(row['total_bags']),
      );
}

class DispatchRepository {
  const DispatchRepository(this._client);

  final SupabaseClient _client;

  Future<DispatchResult> create({
    required String customerName,
    required List<DispatchLine> lines,
    required String clientRef,
    DateTime? date,
    String? reference,
    String? vehicleNumber,
    String? remarks,
  }) async {
    try {
      final response = await _client.rpc<Map<String, dynamic>>(
        'create_dispatch',
        params: {
          'p_customer_name': customerName,
          'p_lines': [for (final line in lines) line.toJson()],
          'p_client_ref': clientRef,
          'p_dispatch_date': Fmt.isoDate(date ?? DateTime.now()),
          'p_reference': reference,
          'p_vehicle_number': vehicleNumber,
          'p_remarks': remarks,
        },
      );
      return DispatchResult.from(response);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<Dispatch>> list({int limit = 200}) async {
    try {
      final rows = await _client
          .from('v_dispatch_lines')
          .select()
          .order('created_at', ascending: false)
          .limit(limit);
      return Dispatch.fromRows(rows);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final dispatchRepositoryProvider = Provider<DispatchRepository>((ref) {
  return DispatchRepository(ref.watch(supabaseClientProvider));
});

final dispatchesProvider = FutureProvider<List<Dispatch>>((ref) async {
  return ref.watch(dispatchRepositoryProvider).list();
});
