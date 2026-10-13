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

  /// Pay is yours or nobody's, exactly as the policies have it.
  ///
  /// The database enforces this and the demo has no row level security, so it
  /// has to be said here instead. Without it the operator's own pay screen
  /// would list the whole factory's wages in demo mode — the precise leak those
  /// policies exist to prevent, in the build that gets shown to people.
  bool _maySee(Object? profileId) =>
      _store.signedInIsAdmin || profileId == _store.signedInProfileId;

  @override
  Future<List<Payslip>> payslips({DateTime? month}) async {
    return _latency(() {
      final rows = _store.payslipRows.where((r) =>
          _maySee(r['profile_id']) &&
          (month == null || r['period_month'] == _month(month)));
      return rows.map(Payslip.from).toList(growable: false);
    });
  }

  @override
  Future<List<PayrollPeriod>> payrollPeriods({int limit = 24}) async {
    return _latency(() => _store.payrollPeriodRows
        .take(limit)
        .map(PayrollPeriod.from)
        .toList(growable: false));
  }

  @override
  Future<List<StaffPay>> staffPay() async {
    return _latency(() => _store.staffPayRows
        .where((r) => _maySee(r['profile_id']))
        .map(StaffPay.from)
        .toList(growable: false));
  }

  @override
  Future<List<StaffDeduction>> deductions(DateTime month) async {
    return _latency(() => _store.deductionRows
        .where((r) => r['period_month'] == _month(month))
        .map(StaffDeduction.from)
        .toList(growable: false));
  }

  @override
  Future<List<StaffAdvance>> advances() async {
    return _latency(() => _store.advanceRows
        .where((r) => _maySee(r['profile_id']))
        .map(StaffAdvance.from)
        .toList(growable: false));
  }

  @override
  Future<List<SalaryPayment>> paymentsFor(String payslipId) async {
    return _latency(() => _store.paymentRows
        .where((r) => r['payslip_id'] == payslipId && _maySee(r['profile_id']))
        .map(SalaryPayment.from)
        .toList(growable: false));
  }

  @override
  Future<List<AdvanceTaken>> advancesTaken({
    required String profileId,
    required DateTime month,
  }) async {
    return _latency(() => _store.advanceTakenRows
        .where((r) =>
            r['profile_id'] == profileId &&
            r['period_month'] == _month(month) &&
            _maySee(r['profile_id']))
        .map(AdvanceTaken.from)
        .toList(growable: false));
  }

  @override
  Future<Map<String, dynamic>> recordPayment({
    required String payslipId,
    required double amount,
    required String clientRef,
    DateTime? paidOn,
    String? method,
    String? remarks,
  }) async {
    return _latency(() {
      // Idempotency before validation, so retrying a payment that already
      // landed answers rather than complains.
      final already = _store.paymentRows
          .firstWhere((r) => r['client_ref'] == clientRef, orElse: () => {});
      if (already.isNotEmpty) {
        return {
          'id': already['id'],
          'duplicate': true,
          'paid': _paid(payslipId),
        };
      }

      if (amount <= 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'The payment must be greater than zero.',
        );
      }

      final slip = _store.payslipRows
          .firstWhere((r) => r['id'] == payslipId, orElse: () => {});
      if (slip.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That payslip does not exist.',
        );
      }

      if (slip['period_status'] != 'FINALISED') {
        throw AppException(
          kind: AppErrorKind.validation,
          message: 'Payroll for '
              '${Fmt.monthYear(DateTime.parse(slip['period_month'] as String))} '
              'has not been finalised yet, so there is nothing agreed to pay '
              'against. Finalise the month first.',
        );
      }

      final net = slip['net_payable'] as double;
      final paid = _paid(payslipId);
      final left = net - paid;

      if (amount > left) {
        throw AppException(
          kind: AppErrorKind.insufficientStock,
          message: '${slip['staff_name']} (${slip['employee_code']}) has '
              '${Fmt.money(left)} left on '
              '${Fmt.monthYear(DateTime.parse(slip['period_month'] as String))}, '
              'and this payment is ${Fmt.money(amount)}. Pay the remainder or '
              'less.',
        );
      }

      final id = _store.nextId('spay');
      _store.paymentRows.add({
        'id': id,
        'payslip_id': payslipId,
        'profile_id': slip['profile_id'],
        'employee_code': slip['employee_code'],
        'staff_name': slip['staff_name'],
        'period_month': slip['period_month'],
        'amount': amount,
        'paid_on': Fmt.isoDate(paidOn ?? DateTime.now()),
        'method': method,
        'reverses': null,
        'is_reversal': false,
        'is_reversed': false,
        'client_ref': clientRef,
        'remarks': remarks,
        'created_at': DateTime.now().toIso8601String(),
      });

      _resettle(payslipId);

      return {
        'id': id,
        'duplicate': false,
        'profile_id': slip['profile_id'],
        'net_payable': net,
        'paid': paid + amount,
        'outstanding': net - paid - amount,
        'settled': net - paid - amount <= 0,
      };
    });
  }

  @override
  Future<Map<String, dynamic>> reversePayment({
    required String paymentId,
    required String clientRef,
    String? remarks,
  }) async {
    return _latency(() {
      final already = _store.paymentRows
          .firstWhere((r) => r['client_ref'] == clientRef, orElse: () => {});
      if (already.isNotEmpty) {
        return {'id': already['id'], 'duplicate': true};
      }

      final row = _store.paymentRows
          .firstWhere((r) => r['id'] == paymentId, orElse: () => {});
      if (row.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That payment does not exist.',
        );
      }
      if ((row['amount'] as double) < 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That row is itself a reversal and cannot be reversed again.',
        );
      }
      if (_store.paymentRows.any((r) => r['reverses'] == paymentId)) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That payment has already been reversed.',
        );
      }

      final id = _store.nextId('spay');
      _store.paymentRows.add({
        ...row,
        'id': id,
        'amount': -(row['amount'] as double),
        'paid_on': Fmt.isoDate(DateTime.now()),
        'reverses': paymentId,
        'is_reversal': true,
        'is_reversed': false,
        'client_ref': clientRef,
        'remarks': remarks ??
            'Reverses payment of ${Fmt.money(row['amount'] as double)} on '
                '${Fmt.date(DateTime.parse(row['paid_on'] as String))}',
        'created_at': DateTime.now().toIso8601String(),
      });
      row['is_reversed'] = true;

      _resettle(row['payslip_id'] as String);

      return {
        'id': id,
        'duplicate': false,
        'reversed': paymentId,
        'amount': -(row['amount'] as double),
        'paid': _paid(row['payslip_id'] as String),
      };
    });
  }

  double _paid(String payslipId) => _store.paymentRows
      .where((r) => r['payslip_id'] == payslipId)
      .fold<double>(0, (sum, r) => sum + (r['amount'] as double));

  /// Recomputes a payslip's paid, outstanding and status, and its month's
  /// summary. The live app gets these from a view; the demo has to keep them in
  /// step by hand, and doing it in one place is what stops them drifting.
  void _resettle(String payslipId) {
    final slip = _store.payslipRows
        .firstWhere((r) => r['id'] == payslipId, orElse: () => {});
    if (slip.isEmpty) return;

    final net = slip['net_payable'] as double;
    final paid = _paid(payslipId);
    slip['paid_amount'] = paid;
    slip['outstanding'] = net - paid;
    slip['payment_status'] = DemoStore.paymentStatus(
      periodStatus: slip['period_status'] as String,
      netPayable: net,
      paid: paid,
    );

    final month = DateTime.parse(slip['period_month'] as String);
    _store.rollUpPeriod(month, slip['period_status'] as String);
  }

  // ---------------------------------------------------------------------------
  // Writes
  //
  // These recompute the same way run_payroll does, so the demo shows the real
  // arithmetic rather than a plausible-looking number (A38).
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> setSalary({
    required String profileId,
    required double monthlySalary,
    DateTime? effectiveFrom,
    String? remarks,
  }) async {
    return _latency(() {
      final from = effectiveFrom ?? DateTime.now();
      final row = _store.staffPayRows
          .firstWhere((r) => r['profile_id'] == profileId, orElse: () => {});
      if (row.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That staff member does not exist or is inactive.',
        );
      }

      // A raise dated ahead of today is what they will be on, not what they
      // are on — the same split the view makes.
      if (from.isAfter(DateTime.now())) {
        row['upcoming_salary'] = monthlySalary;
        row['upcoming_from'] = Fmt.isoDate(from);
      } else {
        row['monthly_salary'] = monthlySalary;
        row['effective_from'] = Fmt.isoDate(from);
        row['upcoming_salary'] = null;
        row['upcoming_from'] = null;
      }

      return {'id': _store.nextId('sal'), 'profile_id': profileId};
    });
  }

  @override
  Future<Map<String, dynamic>> issueAdvance({
    required String profileId,
    required double amount,
    required String clientRef,
    DateTime? entryDate,
    String? remarks,
  }) async {
    return _latency(() {
      if (amount <= 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'The amount must be greater than zero.',
        );
      }

      final pay = _store.staffPayRows
          .firstWhere((r) => r['profile_id'] == profileId, orElse: () => {});

      final existing = _store.advanceRows
          .firstWhere((r) => r['profile_id'] == profileId, orElse: () => {});

      if (existing.isEmpty) {
        _store.advanceRows.add({
          'profile_id': profileId,
          'staff_name': pay['staff_name'] ?? '—',
          'employee_code': pay['employee_code'] ?? '',
          'total_issued': amount,
          'total_recovered': 0.0,
          'outstanding': amount,
          'updated_at': DateTime.now().toIso8601String(),
        });
      } else {
        existing['total_issued'] =
            (existing['total_issued'] as double) + amount;
        existing['outstanding'] = (existing['outstanding'] as double) + amount;
      }

      if (pay.isNotEmpty) {
        pay['outstanding_advance'] =
            (pay['outstanding_advance'] as double) + amount;
      }

      return {'duplicate': false, 'outstanding': pay['outstanding_advance']};
    });
  }

  @override
  Future<Map<String, dynamic>> addDeduction({
    required String profileId,
    required DateTime periodMonth,
    required String label,
    required double amount,
    required String clientRef,
    String? remarks,
  }) async {
    return _latency(() {
      _requireDraft(periodMonth);

      final pay = _store.staffPayRows
          .firstWhere((r) => r['profile_id'] == profileId, orElse: () => {});
      final id = _store.nextId('ded');

      _store.deductionRows.add({
        'id': id,
        'profile_id': profileId,
        'employee_code': pay['employee_code'] ?? '',
        'staff_name': pay['staff_name'] ?? '—',
        'period_month': _month(periodMonth),
        'label': label,
        'amount': amount,
        'remarks': remarks,
        'created_at': DateTime.now().toIso8601String(),
      });

      return {'id': id, 'duplicate': false};
    });
  }

  @override
  Future<Map<String, dynamic>> removeDeduction(String id) async {
    return _latency(() {
      final row = _store.deductionRows
          .firstWhere((r) => r['id'] == id, orElse: () => {});
      if (row.isEmpty) return {'id': id, 'removed': false};

      _requireDraft(DateTime.parse(row['period_month'] as String));
      _store.deductionRows.removeWhere((r) => r['id'] == id);
      return {'id': id, 'removed': true};
    });
  }

  @override
  Future<Map<String, dynamic>> runPayroll(DateTime month,
      {String? remarks}) async {
    return _latency(() {
      final iso = _month(month);
      _requireDraft(month);

      // A draft is rebuilt from scratch. Its payslips cannot carry payments —
      // paying needs a finalised month — so nothing is lost with them.
      final rebuilt = _store.payslipRows
          .where((r) => r['period_month'] == iso)
          .map((r) => r['id'])
          .toSet();
      _store.payslipRows.removeWhere((r) => r['period_month'] == iso);
      _store.paymentRows.removeWhere((r) => rebuilt.contains(r['payslip_id']));

      var count = 0;
      var net = 0.0;

      for (final person in _store.staffPayRows) {
        final salary = person['monthly_salary'] as double?;
        if (salary == null) continue;
        if (person['active'] == false) continue;

        final deductions = _store.deductionRows
            .where((d) =>
                d['profile_id'] == person['profile_id'] &&
                d['period_month'] == iso)
            .fold<double>(0, (sum, d) => sum + (d['amount'] as double));

        if (deductions > salary) {
          throw AppException(
            kind: AppErrorKind.validation,
            message: 'Deductions for ${person['staff_name']} '
                '(${person['employee_code']}) come to '
                '${Fmt.money(deductions)}, more than the monthly salary of '
                '${Fmt.money(salary)}. Reduce them before calculating the '
                'payroll.',
          );
        }

        final outstanding = person['outstanding_advance'] as double;
        final recovery =
            outstanding < salary - deductions ? outstanding : salary - deductions;
        final payable = salary - deductions - recovery;

        _store.addPayslip(
          month: month,
          person: person,
          salary: salary,
          deductions: deductions,
          advance: recovery,
          periodStatus: 'DRAFT',
        );

        count++;
        net += payable;
      }

      _store.rollUpPeriod(DateTime(month.year, month.month, 1), 'DRAFT');

      return {'payslips': count, 'net_total': net, 'status': 'DRAFT'};
    });
  }

  @override
  Future<Map<String, dynamic>> finalisePayroll(DateTime month) async {
    return _latency(() {
      final iso = _month(month);
      final period = _store.payrollPeriodRows
          .firstWhere((r) => r['period_month'] == iso, orElse: () => {});

      if (period.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Payroll has not been calculated for that month yet.',
        );
      }
      if (period['status'] != 'DRAFT') {
        return {'duplicate': true, 'status': period['status']};
      }

      // The point at which the advances actually come off the ledger.
      var posted = 0;
      for (final slip
          in _store.payslipRows.where((r) => r['period_month'] == iso)) {
        final recovered = slip['advance_recovered'] as double;
        slip['period_status'] = 'FINALISED';
        if (recovered <= 0) continue;

        final pay = _store.staffPayRows.firstWhere(
            (r) => r['profile_id'] == slip['profile_id'],
            orElse: () => {});
        if (pay.isNotEmpty) {
          pay['outstanding_advance'] =
              (pay['outstanding_advance'] as double) - recovered;
        }

        final ledger = _store.advanceRows.firstWhere(
            (r) => r['profile_id'] == slip['profile_id'],
            orElse: () => {});
        if (ledger.isNotEmpty) {
          ledger['total_recovered'] =
              (ledger['total_recovered'] as double) + recovered;
          ledger['outstanding'] =
              (ledger['outstanding'] as double) - recovered;
        }
        posted++;
      }

      period['status'] = 'FINALISED';
      period['finalised_at'] = DateTime.now().toIso8601String();

      // Finalising is what makes a payslip payable, so every status on the
      // month moves from DRAFT to where it actually stands.
      for (final slip
          in _store.payslipRows.where((r) => r['period_month'] == iso)) {
        _resettle(slip['id'] as String);
      }

      return {'duplicate': false, 'status': 'FINALISED',
              'recoveries_posted': posted};
    });
  }

  String _month(DateTime value) =>
      Fmt.isoDate(DateTime(value.year, value.month, 1));

  /// A finalised month is closed to every kind of change, here as in the
  /// database.
  void _requireDraft(DateTime month) {
    final period = _store.payrollPeriodRows
        .firstWhere((r) => r['period_month'] == _month(month), orElse: () => {});
    if (period.isNotEmpty && period['status'] != 'DRAFT') {
      throw AppException(
        kind: AppErrorKind.conflict,
        message: 'Payroll for ${Fmt.monthYear(month)} is already finalised.',
      );
    }
  }
}
