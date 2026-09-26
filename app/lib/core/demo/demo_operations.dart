import '../../features/dispatch/data/dispatch_repository.dart';
import '../../features/production/data/production_repository.dart';
import '../../features/production/domain/production.dart';
import '../../features/staff/data/staff_repository.dart';
import '../../features/wastage/data/wastage_repository.dart';
import '../error/app_exception.dart';
import '../utils/formatters.dart';
import 'demo_store.dart';

/// Offline twins for the operational repositories (production, dispatch,
/// wastage, staff). See `demo_repositories.dart` for the reasoning behind
/// implementing the real classes rather than subclassing them.

Future<T> _latency<T>(T Function() body) async {
  await Future<void>.delayed(DemoStore.latency);
  return body();
}

AppException _invalid(String message) =>
    AppException(kind: AppErrorKind.validation, message: message);

// =============================================================================
// Production
// =============================================================================

class DemoProductionRepository implements ProductionRepository {
  DemoProductionRepository(this._store);

  final DemoStore _store;

  @override
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
    String? mixtureEntryId,
  }) async {
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return const ProductionResult(
          id: 'demo-duplicate',
          duplicate: true,
          bundleQuantity: 0,
          resultingStock: 0,
        );
      }

      // The same checks record_production() makes, in the same order — which
      // now starts with the batch (A37), so the demo refuses an unlinked run
      // exactly where the database does.
      final batch = mixtureEntryId == null
          ? null
          : _store.mixtures
              .where((m) => m['mixture_entry_id'] == mixtureEntryId)
              .firstOrNull;

      if (mixtureEntryId == null) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Record the material that went into the machine first, '
              'then link this production to it.',
          data: {'field': 'mixture_entry_id'},
        );
      }
      if (batch == null) {
        throw _invalid('That material batch does not exist.');
      }
      if (batch['machine_id'] != machineId) {
        throw _invalid(
            'That material batch was charged into a different machine.');
      }
      batch['runs'] = (batch['runs'] as int) + 1;

      if (bundleQuantity < 0 || bagQuantity < 0) {
        throw _invalid('Quantities cannot be negative.');
      }
      if (bundleQuantity + bagQuantity == 0) {
        throw _invalid('Enter the bundles or bags produced.');
      }
      if (wastageUsed && (wastageUsedKg == null || wastageUsedKg <= 0)) {
        throw _invalid(
            'Enter how many kilograms of wastage material were used.');
      }
      if (!wastageUsed && (wastageUsedKg ?? 0) != 0) {
        throw _invalid(
            'Wastage material used is set to No, so no quantity can be entered.');
      }

      final shift = _store.shifts.firstWhere(
        (s) => s['id'] == shiftId,
        orElse: () => const {},
      );
      if (shift.isEmpty || shift['active'] != true) {
        throw _invalid('Choose the Morning or Night shift.');
      }

      final product = _store.productFor(pipeTypeId, pipeSizeId);
      if (product == null) {
        throw _invalid('That product is no longer available.');
      }
      if (bagQuantity > 0 &&
          (product['pipes_per_bag'] == null ||
              product['pipes_per_bundle'] == null)) {
        throw _invalid('Bag packing is not set up for ${product['sku']}. Set '
            'pipes per bag and pipes per bundle for this product first.');
      }

      final date = entryDate ?? DateTime.now();
      final id = _store.nextId('pe');

      _store.productionEntries.add({
        'id': id,
        'entry_date': Fmt.isoDate(date),
        'machine_id': machineId,
        'operator_id': _store.signedInProfileId ?? DemoStore.raviId,
        'shift_id': shiftId,
        'pipe_type_id': pipeTypeId,
        'pipe_size_id': pipeSizeId,
        'bundle_quantity': bundleQuantity,
        'bag_quantity': bagQuantity,
        'wastage_quantity': wastageQuantity,
        'wastage_used': wastageUsed,
        'wastage_used_kg': wastageUsed ? wastageUsedKg : null,
        'remarks': remarks,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Production raises finished-goods stock, exactly as record_production()
      // does inside its transaction.
      product['quantity_bundles'] =
          (product['quantity_bundles'] as int) + bundleQuantity;
      product['quantity_bags'] =
          (product['quantity_bags'] as int? ?? 0) + bagQuantity;
      _store.refreshStatuses();

      return ProductionResult(
        id: id,
        duplicate: false,
        bundleQuantity: bundleQuantity,
        resultingStock: product['quantity_bundles'] as int,
        bagQuantity: bagQuantity,
        resultingBags: product['quantity_bags'] as int,
      );
    });
  }

  @override
  Future<List<ProductionEntry>> list({
    ProductionFilter filter = const ProductionFilter(),
    int limit = 100,
    bool oldestFirst = false,
  }) async {
    return _latency(() {
      final rows = <Map<String, dynamic>>[];

      for (final entry in _store.productionEntries) {
        final date = DateTime.tryParse(entry['entry_date'] as String? ?? '');

        if (filter.from != null &&
            date != null &&
            date.isBefore(DateTime(filter.from!.year, filter.from!.month,
                filter.from!.day))) {
          continue;
        }
        if (filter.machineId != null &&
            entry['machine_id'] != filter.machineId) {
          continue;
        }
        if (filter.operatorId != null &&
            entry['operator_id'] != filter.operatorId) {
          continue;
        }
        if (filter.pipeTypeId != null &&
            entry['pipe_type_id'] != filter.pipeTypeId) {
          continue;
        }

        // The store holds ids; the view the app reads carries names too.
        rows.add({
          ...entry,
          'machine_name': _store.nameOf(
              _store.machines, 'id', entry['machine_id'] as String),
          'operator_name': _store.nameOf(
              _store.staff, 'id', entry['operator_id'] as String),
          'shift_name':
              _store.nameOf(_store.shifts, 'id', entry['shift_id'] as String),
          'pipe_type_name': _store.nameOf(
              _store.pipeTypes, 'id', entry['pipe_type_id'] as String),
          'pipe_size_name': _store.nameOf(
              _store.pipeSizes, 'id', entry['pipe_size_id'] as String),
        });
      }

      rows.sort((a, b) {
        final byTime =
            (a['created_at'] as String).compareTo(b['created_at'] as String);
        return oldestFirst ? byTime : -byTime;
      });

      return rows
          .take(limit)
          .map(ProductionEntry.from)
          .toList(growable: false);
    });
  }
}

// =============================================================================
// Dispatch
// =============================================================================

class DemoDispatchRepository implements DispatchRepository {
  DemoDispatchRepository(this._store);

  final DemoStore _store;

  @override
  Future<DispatchResult> create({
    required String customerName,
    required List<DispatchLine> lines,
    required String clientRef,
    DateTime? date,
    String? reference,
    String? vehicleNumber,
    String? remarks,
  }) async {
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return const DispatchResult(
            id: 'demo-duplicate', duplicate: true, totalBundles: 0);
      }

      if (!_store.signedInIsAdmin) {
        throw const AppException(
          kind: AppErrorKind.authorization,
          message: 'This action requires an administrator account.',
        );
      }

      if (customerName.trim().isEmpty) {
        throw _invalid('Enter the buyer name.');
      }

      // Normalised and checked exactly as create_dispatch() does.
      final vehicle = normaliseVehicle(vehicleNumber);
      if (vehicle.isEmpty) throw _invalid('Enter the vehicle number.');
      if (!RegExp(r'^[A-Z0-9]{4,15}$').hasMatch(vehicle)) {
        throw _invalid('Enter a valid vehicle number, for example GJ01AB1234.');
      }
      if (lines.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Add at least one product to dispatch.',
        );
      }

      // Check every line before deducting any of them. A lorry loaded against
      // a half-applied dispatch is the failure this prevents.
      for (final line in lines) {
        if (line.bundleQuantity < 0 || line.bagQuantity < 0) {
          throw _invalid('Dispatch quantities cannot be negative.');
        }
        if (line.bundleQuantity + line.bagQuantity == 0) {
          throw _invalid('Every product on a dispatch needs bundles or bags.');
        }

        final product = _store.productFor(line.pipeTypeId, line.pipeSizeId);
        final bundlesHeld = (product?['quantity_bundles'] as int?) ?? 0;
        final bagsHeld = (product?['quantity_bags'] as int?) ?? 0;

        if (line.bagQuantity > 0 &&
            (product == null ||
                product['pipes_per_bag'] == null ||
                product['pipes_per_bundle'] == null)) {
          throw _invalid('Bag packing is not set up for that product. Set '
              'pipes per bag and pipes per bundle first.');
        }

        if (bundlesHeld < line.bundleQuantity) {
          throw AppException(
            kind: AppErrorKind.insufficientStock,
            message: 'Insufficient finished-goods stock. '
                'Available: $bundlesHeld bundles.',
            data: {
              'available': bundlesHeld,
              'requested': line.bundleQuantity,
              'label': line.product,
            },
          );
        }

        if (bagsHeld < line.bagQuantity) {
          throw AppException(
            kind: AppErrorKind.insufficientStock,
            message: 'Insufficient bag stock for ${line.product}. '
                'Available: $bagsHeld bags.',
            data: {
              'available': bagsHeld,
              'requested': line.bagQuantity,
              'label': line.product,
              'packaging': 'BAG',
            },
          );
        }
      }

      final id = _store.nextId('dsp');
      final when = date ?? DateTime.now();
      var total = 0;
      var totalBags = 0;

      for (final line in lines) {
        final product = _store.productFor(line.pipeTypeId, line.pipeSizeId)!;
        product['quantity_bundles'] =
            (product['quantity_bundles'] as int) - line.bundleQuantity;
        product['quantity_bags'] =
            (product['quantity_bags'] as int? ?? 0) - line.bagQuantity;
        total += line.bundleQuantity;
        totalBags += line.bagQuantity;

        _store.dispatchRows.add({
          'dispatch_id': id,
          'dispatch_date': Fmt.isoDate(when),
          'customer_name': customerName.trim(),
          'reference': reference,
          'vehicle_number': vehicle,
          'remarks': remarks,
          'created_at': DateTime.now().toIso8601String(),
          'line_id': _store.nextId('dl'),
          'pipe_type_id': line.pipeTypeId,
          'pipe_type_name': product['pipe_type_name'],
          'pipe_size_id': line.pipeSizeId,
          'pipe_size_name': product['pipe_size_name'],
          'bundle_quantity': line.bundleQuantity,
          'bag_quantity': line.bagQuantity,
        });

        // §23: the remaining-stock notification the admin relies on.
        final sent = [
          if (line.bundleQuantity > 0) '${line.bundleQuantity} bundles',
          if (line.bagQuantity > 0) '${line.bagQuantity} bags',
        ].join(' and ');
        _store.notifications.insert(0, {
          'id': _store.nextId('ntf'),
          'title': 'Dispatch completed',
          'message': '${product['pipe_type_name']} '
              '${product['pipe_size_name']} — dispatched $sent to '
              '${customerName.trim()}. Remaining stock: '
              '${product['quantity_bundles']} bundles, '
              '${product['quantity_bags']} bags.',
          'type': 'DISPATCH',
          'metadata': <String, dynamic>{},
          'created_at': DateTime.now().toIso8601String(),
          'is_read': false,
        });
      }

      _store.refreshStatuses();
      return DispatchResult(
        id: id,
        duplicate: false,
        totalBundles: total,
        totalBags: totalBags,
      );
    });
  }

  @override
  Future<List<Dispatch>> list({int limit = 200}) async {
    return _latency(() => Dispatch.fromRows([..._store.dispatchRows]));
  }
}

// =============================================================================
// Wastage
// =============================================================================

class DemoWastageRepository implements WastageRepository {
  DemoWastageRepository(this._store);

  final DemoStore _store;

  @override
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
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return {'duplicate': true};
      }

      if (quantity <= 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Wastage quantity must be greater than zero.',
        );
      }

      final material = _store.materialById(rawMaterialId);
      if (material == null) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That material is no longer available.',
        );
      }

      final date = entryDate ?? DateTime.now();

      _store.wastageRows.insert(0, {
        'id': _store.nextId('wst'),
        'entry_date': Fmt.isoDate(date),
        'machine_id': machineId,
        'machine_name': machineId == null
            ? null
            : _store.nameOf(_store.machines, 'id', machineId),
        'operator_id': null,
        'operator_name': null,
        'shift_id': shiftId,
        'shift_name': shiftId == null
            ? null
            : _store.nameOf(_store.shifts, 'id', shiftId),
        'raw_material_id': rawMaterialId,
        'raw_material_name': material['name'],
        'source': source.wire,
        'quantity': quantity,
        'unit': material['unit'],
        'reusable': reusable,
        'remarks': remarks,
        'created_at': DateTime.now().toIso8601String(),
      });

      // Only material that never reached a mixture comes off raw stock.
      // Production scrap was already counted out when it was consumed.
      if (source == WastageSource.rawMaterialLoss) {
        final remaining = (material['quantity'] as num) - quantity;
        if (remaining < 0) {
          throw AppException(
            kind: AppErrorKind.insufficientStock,
            message: 'Insufficient ${material['name']} stock. Available: '
                '${Fmt.quantity(material['quantity'] as num)} '
                '${material['unit']}.',
            data: {'available': material['quantity']},
          );
        }
        material['quantity'] = remaining;
      }

      if (reusable) {
        for (final row in _store.recycled) {
          if (row['raw_material_id'] == DemoStore.regrindId) {
            row['quantity'] = (row['quantity'] as num) + quantity;
            row['total_recovered_kg'] =
                (row['total_recovered_kg'] as num) + quantity;
          }
        }
        final regrind = _store.materialById(DemoStore.regrindId);
        if (regrind != null) {
          regrind['quantity'] = (regrind['quantity'] as num) + quantity;
        }
      }

      _store.refreshStatuses();
      return {'duplicate': false};
    });
  }

  @override
  Future<List<WastageEntry>> list({int limit = 100}) async {
    return _latency(() => _store.wastageRows
        .take(limit)
        .map(WastageEntry.from)
        .toList(growable: false));
  }
}

// =============================================================================
// Staff
// =============================================================================

class DemoStaffRepository implements StaffRepository {
  DemoStaffRepository(this._store);

  final DemoStore _store;

  @override
  Future<List<AttendanceDay>> attendanceOn(DateTime date) async {
    return _latency(() {
      final iso = Fmt.isoDate(date);
      return _store.attendanceRows
          .where((row) => row['work_date'] == iso)
          .map(AttendanceDay.from)
          .toList(growable: false);
    });
  }

  @override
  Future<List<AttendanceDay>> recentAttendance({
    required String profileId,
    int days = 7,
  }) async {
    return _latency(() {
      final today = DateTime.now();
      final since = DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: days - 1));
      final rows = _store.attendanceRows.where((row) {
        final date = DateTime.parse(row['work_date'] as String);
        return row['profile_id'] == profileId && !date.isBefore(since);
      }).toList()
        ..sort((a, b) =>
            (b['work_date'] as String).compareTo(a['work_date'] as String));
      return rows.map(AttendanceDay.from).toList(growable: false);
    });
  }

  @override
  Future<List<MonthlyAttendance>> monthlyAttendance(DateTime month) async {
    return _latency(() => _store.monthlyAttendanceRows
        .map(MonthlyAttendance.from)
        .toList(growable: false));
  }

  @override
  Future<List<Payslip>> payslips() async {
    return _latency(
        () => _store.payslipRows.map(Payslip.from).toList(growable: false));
  }

  @override
  Future<List<StaffAdvance>> advances() async {
    return _latency(
        () => _store.advanceRows.map(StaffAdvance.from).toList(growable: false));
  }
}
