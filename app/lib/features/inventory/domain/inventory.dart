/// Stock read models (§13, Phase 3).
///
/// Two models that already existed elsewhere are deliberately NOT redefined
/// here:
///
///   * raw-material stock is `RawMaterial` in the masters feature, because the
///     threshold and the quantity come out of the same view and splitting them
///     would mean two shapes for one row;
///   * finished-goods stock is `FinishedGoodsStock` in the dashboard feature,
///     which parses the same `v_finished_goods_stock` rows. One view, one
///     model — a second copy would drift the moment either changed.
///
/// What is left is the one stock view with no existing model.
library;

import '../../dashboard/domain/dashboard_models.dart';

/// The (type, size) pair as a key, for joining a bundle weight onto a stock row.
extension FinishedGoodsKey on FinishedGoodsStock {
  String get productKey => '$pipeTypeId|$pipeSizeId';
}

/// Regrind, from `v_recycled_material_stock` (A20).
///
/// Reported apart from virgin material because the ratio of one to the other is
/// the thing worth watching, and because "recovered" and "consumed" are the two
/// halves of the shredding loop closing.
class RecycledStock {
  const RecycledStock({
    required this.rawMaterialId,
    required this.code,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.totalRecovered,
    required this.totalConsumed,
  });

  final String rawMaterialId;
  final String code;
  final String name;
  final String unit;
  final double quantity;
  final double totalRecovered;
  final double totalConsumed;

  factory RecycledStock.from(Map<String, dynamic> row) => RecycledStock(
        rawMaterialId: row['raw_material_id'] as String,
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? '',
        unit: row['unit'] as String? ?? 'kg',
        quantity: _double(row['quantity']),
        totalRecovered: _double(row['total_recovered_kg']),
        totalConsumed: _double(row['total_consumed_kg']),
      );
}

// Postgres numerics arrive as Strings over PostgREST. Parsed as `num` they
// would silently become zero, which on a stock screen is the worst possible
// failure: it looks like an answer.
double _double(Object? value) => switch (value) {
      null => 0,
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? 0,
      _ => 0,
    };

