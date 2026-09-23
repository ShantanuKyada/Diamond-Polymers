/// Typed views over the `admin_dashboard()` and `operator_dashboard()` payloads.
///
/// The RPCs return one jsonb document each so a dashboard is a single round
/// trip (§51, §53). These models keep the parsing in one place rather than
/// letting `snapshot['production']['total_bundles']` spread through widgets.
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

List<Map<String, dynamic>> _rows(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList(growable: false);
}

/// A name paired with a bundle count — "Machine 2: 95".
class NamedCount {
  const NamedCount({required this.id, required this.name, required this.value});

  final String id;
  final String name;
  final int value;

  factory NamedCount.from(
    Map<String, dynamic> row, {
    required String idKey,
    required String nameKey,
    String valueKey = 'bundles',
  }) {
    return NamedCount(
      id: row[idKey] as String? ?? '',
      name: row[nameKey] as String? ?? '—',
      value: _toInt(row[valueKey]),
    );
  }
}

class RawMaterialStock {
  const RawMaterialStock({
    required this.id,
    required this.name,
    required this.categoryName,
    required this.unit,
    required this.quantity,
    required this.minimumStock,
    required this.status,
  });

  final String id;
  final String name;
  final String categoryName;
  final String unit;
  final double quantity;
  final double minimumStock;
  final String status;

  bool get needsAttention => status == 'LOW' || status == 'OUT';

  factory RawMaterialStock.from(Map<String, dynamic> row) {
    return RawMaterialStock(
      id: row['raw_material_id'] as String? ?? '',
      name: row['name'] as String? ?? '—',
      categoryName: row['category_name'] as String? ?? '',
      unit: row['unit'] as String? ?? 'kg',
      quantity: _toDouble(row['quantity']),
      minimumStock: _toDouble(row['minimum_stock']),
      status: row['status'] as String? ?? 'GOOD',
    );
  }
}

class FinishedGoodsStock {
  const FinishedGoodsStock({
    required this.pipeTypeId,
    required this.pipeTypeName,
    required this.pipeSizeId,
    required this.pipeSizeName,
    required this.bundles,
    required this.minimumStock,
    required this.status,
    this.bags = 0,
  });

  final String pipeTypeId;
  final String pipeTypeName;
  final String pipeSizeId;
  final String pipeSizeName;
  final int bundles;

  /// Packed in bags. A separate balance, never a conversion of [bundles] (A25).
  final int bags;
  final int minimumStock;
  final String status;

  String get label => '$pipeTypeName · $pipeSizeName';
  bool get needsAttention => status == 'LOW' || status == 'OUT';

  factory FinishedGoodsStock.from(Map<String, dynamic> row) {
    return FinishedGoodsStock(
      pipeTypeId: row['pipe_type_id'] as String? ?? '',
      pipeTypeName: row['pipe_type_name'] as String? ?? '—',
      pipeSizeId: row['pipe_size_id'] as String? ?? '',
      pipeSizeName: row['pipe_size_name'] as String? ?? '—',
      bundles: _toInt(row['quantity_bundles']),
      minimumStock: _toInt(row['minimum_stock']),
      status: row['status'] as String? ?? 'GOOD',
      bags: _toInt(row['quantity_bags']),
    );
  }
}

class ConsumptionLine {
  const ConsumptionLine({
    required this.name,
    required this.unit,
    required this.consumed,
  });

  final String name;
  final String unit;
  final double consumed;

  factory ConsumptionLine.from(Map<String, dynamic> row) {
    return ConsumptionLine(
      name: row['name'] as String? ?? '—',
      unit: row['unit'] as String? ?? 'kg',
      consumed: _toDouble(row['consumed']),
    );
  }
}

class MachineSummary {
  const MachineSummary({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.operators,
    required this.bundlesToday,
  });

  final String id;
  final String code;
  final String name;
  final String status;
  final List<String> operators;
  final int bundlesToday;

  factory MachineSummary.from(Map<String, dynamic> row) {
    return MachineSummary(
      id: row['machine_id'] as String? ?? '',
      code: row['code'] as String? ?? '',
      name: row['name'] as String? ?? '—',
      status: row['status'] as String? ?? 'ACTIVE',
      operators: (row['operators'] as List?)?.whereType<String>().toList() ??
          const [],
      bundlesToday: _toInt(row['bundles_today']),
    );
  }
}

class AdminDashboard {
  const AdminDashboard({
    required this.date,
    required this.bundlesToday,
    required this.wastageToday,
    required this.entryCount,
    required this.productionByMachine,
    required this.productionByType,
    required this.productionBySize,
    required this.rawMaterials,
    required this.consumptionToday,
    required this.finishedGoods,
    required this.finishedGoodsTotal,
    required this.dispatchBundlesToday,
    required this.dispatchCountToday,
    required this.rawWastageToday,
    required this.productionScrapToday,
    required this.reusableCollectedToday,
    required this.machines,
    required this.unreadNotifications,
  });

  final DateTime date;
  final int bundlesToday;
  final double wastageToday;
  final int entryCount;
  final List<NamedCount> productionByMachine;
  final List<NamedCount> productionByType;
  final List<NamedCount> productionBySize;
  final List<RawMaterialStock> rawMaterials;
  final List<ConsumptionLine> consumptionToday;
  final List<FinishedGoodsStock> finishedGoods;
  final int finishedGoodsTotal;
  final int dispatchBundlesToday;
  final int dispatchCountToday;
  final double rawWastageToday;
  final double productionScrapToday;
  final double reusableCollectedToday;
  final List<MachineSummary> machines;
  final int unreadNotifications;

  /// Everything the alerts section needs, in one list.
  List<String> get alerts {
    final messages = <String>[
      for (final m in rawMaterials.where((m) => m.needsAttention))
        '${m.name} is ${m.status == 'OUT' ? 'out of stock' : 'low'} '
            '(${m.quantity.toStringAsFixed(m.quantity % 1 == 0 ? 0 : 2)} ${m.unit})',
      for (final g in finishedGoods.where((g) => g.needsAttention))
        '${g.label} is ${g.status == 'OUT' ? 'out of stock' : 'low'} '
            '(${g.bundles} bundles)',
    ];
    return messages;
  }

  factory AdminDashboard.from(Map<String, dynamic> json) {
    final production = json['production'] as Map<String, dynamic>? ?? const {};
    final dispatch = json['dispatch_today'] as Map<String, dynamic>? ?? const {};
    final wastage = json['wastage_today'] as Map<String, dynamic>? ?? const {};

    return AdminDashboard(
      date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      bundlesToday: _toInt(production['total_bundles']),
      wastageToday: _toDouble(production['total_wastage']),
      entryCount: _toInt(production['entry_count']),
      productionByMachine: _rows(json['production_by_machine'])
          .map((r) => NamedCount.from(r,
              idKey: 'machine_id', nameKey: 'machine_name'))
          .toList(),
      productionByType: _rows(json['production_by_type'])
          .map((r) => NamedCount.from(r,
              idKey: 'pipe_type_id', nameKey: 'pipe_type_name'))
          .toList(),
      productionBySize: _rows(json['production_by_size'])
          .map((r) => NamedCount.from(r,
              idKey: 'pipe_size_id', nameKey: 'pipe_size_name'))
          .toList(),
      rawMaterials:
          _rows(json['raw_materials']).map(RawMaterialStock.from).toList(),
      consumptionToday: _rows(json['raw_consumption_today'])
          .map(ConsumptionLine.from)
          .toList(),
      finishedGoods:
          _rows(json['finished_goods']).map(FinishedGoodsStock.from).toList(),
      finishedGoodsTotal: _toInt(json['finished_goods_total']),
      dispatchBundlesToday: _toInt(dispatch['total_bundles']),
      dispatchCountToday: _toInt(dispatch['dispatch_count']),
      rawWastageToday: _toDouble(wastage['raw_wastage']),
      productionScrapToday: _toDouble(wastage['production_scrap']),
      reusableCollectedToday: _toDouble(wastage['reusable']),
      machines: _rows(json['machines']).map(MachineSummary.from).toList(),
      unreadNotifications: _toInt(json['unread_notifications']),
    );
  }
}

/// The operator's current machine and shift, when one is assigned (§19).
class OperatorAssignment {
  const OperatorAssignment({
    required this.machineId,
    required this.machineName,
    required this.machineCode,
    required this.machineStatus,
    this.shiftId,
    this.shiftName,
    this.startTime,
    this.endTime,
  });

  final String machineId;
  final String machineName;
  final String machineCode;
  final String machineStatus;
  final String? shiftId;
  final String? shiftName;
  final String? startTime;
  final String? endTime;

  factory OperatorAssignment.from(Map<String, dynamic> row) {
    return OperatorAssignment(
      machineId: row['machine_id'] as String? ?? '',
      machineName: row['machine_name'] as String? ?? '—',
      machineCode: row['machine_code'] as String? ?? '',
      machineStatus: row['machine_status'] as String? ?? 'ACTIVE',
      shiftId: row['shift_id'] as String?,
      shiftName: row['shift_name'] as String?,
      startTime: row['start_time'] as String?,
      endTime: row['end_time'] as String?,
    );
  }
}

class RecentProduction {
  const RecentProduction({
    required this.id,
    required this.pipeTypeName,
    required this.pipeSizeName,
    required this.bundles,
    required this.shiftName,
    required this.createdAt,
  });

  final String id;
  final String pipeTypeName;
  final String pipeSizeName;
  final int bundles;
  final String shiftName;
  final DateTime createdAt;

  factory RecentProduction.from(Map<String, dynamic> row) {
    return RecentProduction(
      id: row['id'] as String? ?? '',
      pipeTypeName: row['pipe_type_name'] as String? ?? '—',
      pipeSizeName: row['pipe_size_name'] as String? ?? '—',
      bundles: _toInt(row['bundle_quantity']),
      shiftName: row['shift_name'] as String? ?? '',
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class OperatorDashboard {
  const OperatorDashboard({
    required this.date,
    required this.assignment,
    required this.bundlesToday,
    required this.wastageToday,
    required this.entryCount,
    required this.consumptionToday,
    required this.recentProduction,
  });

  final DateTime date;

  /// Null when no machine is assigned — the operator dashboard says so plainly
  /// instead of showing a blank machine card (A3, §19).
  final OperatorAssignment? assignment;

  final int bundlesToday;
  final double wastageToday;
  final int entryCount;
  final List<ConsumptionLine> consumptionToday;
  final List<RecentProduction> recentProduction;

  factory OperatorDashboard.from(Map<String, dynamic> json) {
    final production =
        json['production_today'] as Map<String, dynamic>? ?? const {};
    final assignment = json['assignment'] as Map<String, dynamic>?;

    return OperatorDashboard(
      date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      assignment:
          assignment == null ? null : OperatorAssignment.from(assignment),
      bundlesToday: _toInt(production['total_bundles']),
      wastageToday: _toDouble(production['total_wastage']),
      entryCount: _toInt(production['entry_count']),
      consumptionToday: _rows(json['consumption_today'])
          .map(ConsumptionLine.from)
          .toList(),
      recentProduction: _rows(json['recent_production'])
          .map(RecentProduction.from)
          .toList(),
    );
  }
}
