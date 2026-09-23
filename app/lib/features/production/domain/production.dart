/// Production read models (§18, §20).
library;

double _toDouble(Object? value) => switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? 0,
      _ => 0,
    };

int _toInt(Object? value) => switch (value) {
      final num n => n.toInt(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };

/// One row of `v_production_entries`.
class ProductionEntry {
  const ProductionEntry({
    required this.id,
    required this.entryDate,
    required this.machineId,
    required this.machineName,
    required this.operatorId,
    required this.operatorName,
    required this.shiftName,
    required this.pipeTypeId,
    required this.pipeTypeName,
    required this.pipeSizeId,
    required this.pipeSizeName,
    required this.bundleQuantity,
    required this.wastageQuantity,
    required this.createdAt,
    this.remarks,
    this.bagQuantity = 0,
    this.wastageUsed = false,
    this.wastageUsedKg,
  });

  final String id;
  final DateTime entryDate;
  final String machineId;
  final String machineName;
  final String operatorId;
  final String operatorName;
  final String shiftName;
  final String pipeTypeId;
  final String pipeTypeName;
  final String pipeSizeId;
  final String pipeSizeName;
  final int bundleQuantity;
  final double wastageQuantity;
  final DateTime createdAt;
  final String? remarks;
  final int bagQuantity;

  /// Whether recycled material went into this run, and how much (A28).
  final bool wastageUsed;
  final double? wastageUsedKg;

  String get product => '$pipeTypeName · $pipeSizeName';

  factory ProductionEntry.from(Map<String, dynamic> row) => ProductionEntry(
        id: row['id'] as String? ?? '',
        entryDate:
            DateTime.tryParse(row['entry_date'] as String? ?? '') ?? DateTime.now(),
        machineId: row['machine_id'] as String? ?? '',
        machineName: row['machine_name'] as String? ?? '—',
        operatorId: row['operator_id'] as String? ?? '',
        operatorName: row['operator_name'] as String? ?? '—',
        shiftName: row['shift_name'] as String? ?? '—',
        pipeTypeId: row['pipe_type_id'] as String? ?? '',
        pipeTypeName: row['pipe_type_name'] as String? ?? '—',
        pipeSizeId: row['pipe_size_id'] as String? ?? '',
        pipeSizeName: row['pipe_size_name'] as String? ?? '—',
        bundleQuantity: _toInt(row['bundle_quantity']),
        wastageQuantity: _toDouble(row['wastage_quantity']),
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
        remarks: row['remarks'] as String?,
        bagQuantity: _toInt(row['bag_quantity']),
        wastageUsed: row['wastage_used'] as bool? ?? false,
        wastageUsedKg: row['wastage_used_kg'] == null
            ? null
            : _toDouble(row['wastage_used_kg']),
      );
}

/// What `record_production()` returns.
class ProductionResult {
  const ProductionResult({
    required this.id,
    required this.duplicate,
    required this.bundleQuantity,
    required this.resultingStock,
    this.bagQuantity = 0,
    this.resultingBags = 0,
  });

  final String id;

  /// True when this reference had already been used, so the entry was recorded
  /// by an earlier attempt and this one changed nothing (§47).
  final bool duplicate;
  final int bundleQuantity;
  final int resultingStock;
  final int bagQuantity;
  final int resultingBags;

  factory ProductionResult.from(Map<String, dynamic> row) => ProductionResult(
        id: row['id'] as String? ?? '',
        duplicate: row['duplicate'] as bool? ?? false,
        bundleQuantity: _toInt(row['bundle_quantity']),
        resultingStock: _toInt(row['resulting_stock']),
        bagQuantity: _toInt(row['bag_quantity']),
        resultingBags: _toInt(row['resulting_bags']),
      );
}

/// Filters for the admin production list (§50). Value equality matters: it is
/// the cache key for the query provider.
class ProductionFilter {
  const ProductionFilter({
    this.from,
    this.to,
    this.machineId,
    this.operatorId,
    this.pipeTypeId,
  });

  final DateTime? from;
  final DateTime? to;
  final String? machineId;
  final String? operatorId;
  final String? pipeTypeId;

  bool get isEmpty =>
      from == null &&
      to == null &&
      machineId == null &&
      operatorId == null &&
      pipeTypeId == null;

  int get activeCount => [
        from,
        machineId,
        operatorId,
        pipeTypeId,
      ].where((v) => v != null).length;

  ProductionFilter copyWith({
    DateTime? from,
    DateTime? to,
    String? machineId,
    String? operatorId,
    String? pipeTypeId,
    bool clearDates = false,
    bool clearMachine = false,
    bool clearOperator = false,
    bool clearType = false,
  }) {
    return ProductionFilter(
      from: clearDates ? null : (from ?? this.from),
      to: clearDates ? null : (to ?? this.to),
      machineId: clearMachine ? null : (machineId ?? this.machineId),
      operatorId: clearOperator ? null : (operatorId ?? this.operatorId),
      pipeTypeId: clearType ? null : (pipeTypeId ?? this.pipeTypeId),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProductionFilter &&
      other.from == from &&
      other.to == to &&
      other.machineId == machineId &&
      other.operatorId == operatorId &&
      other.pipeTypeId == pipeTypeId;

  @override
  int get hashCode => Object.hash(from, to, machineId, operatorId, pipeTypeId);
}
