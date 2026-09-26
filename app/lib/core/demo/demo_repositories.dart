import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/domain/app_user.dart';
import '../../features/dashboard/data/dashboard_repository.dart';
import '../../features/dashboard/domain/dashboard_models.dart';
import '../../features/inventory/data/inventory_repository.dart';
import '../../features/inventory/domain/inventory.dart';
import '../../features/masters/data/masters_repository.dart';
import '../../features/masters/domain/masters.dart';
import '../../features/mixture/data/mixture_repository.dart';
import '../../features/notifications/data/notification_repository.dart';
import '../../features/notifications/domain/app_notification.dart';
import '../error/app_exception.dart';
import '../utils/formatters.dart';
import 'demo_store.dart';

/// Offline implementations of every repository, backed by [DemoStore].
///
/// They `implement` the real repositories rather than subclassing them, so the
/// compiler enforces that demo mode and live mode expose the same API. If a
/// method is added to a repository and not here, this file stops compiling —
/// which is the point.
///
/// Where the database would enforce a rule, these do too: insufficient stock is
/// refused, a repeated client reference is reported as a duplicate, and an
/// operator's writes are scoped to themselves. Demo mode should teach the same
/// lessons the real thing does, not a friendlier version of them.

/// A short pause, so loading states and disabled submit buttons are actually
/// visible rather than flashing past. Real requests are never instant.
Future<T> _latency<T>(T Function() body) async {
  await Future<void>.delayed(DemoStore.latency);
  return body();
}


/// The shift rule the database enforces (A29), applied the same way here.
bool _isAllowedShift(String name) =>
    const {'morning', 'night'}.contains(name.trim().toLowerCase());

const _refused = AppException(
  kind: AppErrorKind.authorization,
  message: 'This action requires an administrator account.',
);

// =============================================================================
// Auth
// =============================================================================

class DemoAuthRepository implements AuthRepository {
  DemoAuthRepository(this._store);

  final DemoStore _store;

  AppUser? _signedIn;

  @override
  Session? get currentSession => null;

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    return _latency(() {
      final address = email.trim().toLowerCase();

      if (password.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.authentication,
          message: 'Incorrect email or password.',
        );
      }

      // Any address containing "admin" opens the admin app; anything else
      // signs in as the operator on Machine 1. Stated on the login screen.
      final wantsAdmin = address.contains('admin');
      final row = _store.staff.firstWhere(
        (p) => p['role'] == (wantsAdmin ? 'ADMIN' : 'OPERATOR'),
      );

      _signedIn = AppUser.fromProfileRow({...row, 'auth_user_id': 'demo'});
      _store.signedInProfileId = _signedIn!.profileId;
      return _signedIn!;
    });
  }

  @override
  Future<void> signOut() async {
    _signedIn = null;
    _store.signedInProfileId = null;
  }

  /// Mirrors update_my_profile(): name and phone only, validated the same way
  /// (A31).
  @override
  Future<AppUser> updateMyProfile({
    required String name,
    String? phone,
  }) async {
    return _latency(() {
      final me = _signedIn;
      if (me == null) {
        throw const AppException(
          kind: AppErrorKind.authentication,
          message: 'Your session has ended. Please sign in again.',
        );
      }

      final cleanName = name.trim();
      if (cleanName.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Enter your name.',
          data: {'field': 'name'},
        );
      }
      if (cleanName.length > 80) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That name is too long — keep it under 80 characters.',
          data: {'field': 'name'},
        );
      }

      var cleanPhone = (phone ?? '').replaceAll(RegExp(r'[\s-]'), '');
      if (cleanPhone.isNotEmpty &&
          !RegExp(r'^\+?[0-9]{10,15}$').hasMatch(cleanPhone)) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Enter a valid phone number — 10 to 15 digits.',
          data: {'field': 'phone'},
        );
      }

      final row = _store.staff.firstWhere((p) => p['id'] == me.profileId);
      row['name'] = cleanName;
      row['phone'] = cleanPhone.isEmpty ? null : cleanPhone;

      _signedIn = AppUser.fromProfileRow({...row, 'auth_user_id': 'demo'});
      return _signedIn!;
    });
  }

  @override
  Future<AppUser?> restore() async => _signedIn;
}

// =============================================================================
// Dashboards
// =============================================================================

class DemoDashboardRepository implements DashboardRepository {
  DemoDashboardRepository(this._store);

  final DemoStore _store;

  @override
  Future<AdminDashboard> loadAdmin(DateTime date) async {
    return _latency(() => AdminDashboard.from(_adminPayload(date)));
  }

  @override
  Future<OperatorDashboard> loadOperator(DateTime date) async {
    return _latency(() => OperatorDashboard.from(_operatorPayload(date)));
  }

  List<Map<String, dynamic>> get _today {
    final iso = Fmt.isoDate(DateTime.now());
    return _store.productionEntries
        .where((e) => e['entry_date'] == iso)
        .toList(growable: false);
  }

  /// Groups today's entries by one of their id columns.
  List<Map<String, dynamic>> _groupBy(
    String idKey,
    String nameKey,
    String? Function(String id) resolveName,
  ) {
    final totals = <String, int>{};
    for (final entry in _today) {
      final id = entry[idKey] as String;
      totals[id] = (totals[id] ?? 0) + (entry['bundle_quantity'] as int);
    }

    final rows = [
      for (final id in totals.keys)
        {
          idKey: id,
          nameKey: resolveName(id) ?? '—',
          'bundles': totals[id],
        },
    ];
    rows.sort((a, b) => (a[nameKey] as String).compareTo(b[nameKey] as String));
    return rows;
  }

  Map<String, dynamic> _adminPayload(DateTime date) {
    _store.refreshStatuses();
    final entries = _today;

    final bundles = entries.fold<int>(
        0, (sum, e) => sum + (e['bundle_quantity'] as int));
    final wastage = entries.fold<double>(
        0, (sum, e) => sum + (e['wastage_quantity'] as num).toDouble());

    // Consumption is derived from what was produced, so the raw-material figure
    // on the dashboard is consistent with the production figure beside it.
    final consumed = <String, double>{
      'Raizin': bundles * 0.82,
      'Chemical': bundles * 0.16,
      'Color': bundles * 0.07,
    };

    return {
      'date': Fmt.isoDate(date),
      'production': {
        'total_bundles': bundles,
        'total_wastage': wastage,
        'entry_count': entries.length,
      },
      'production_by_machine': _groupBy('machine_id', 'machine_name',
          (id) => _store.nameOf(_store.machines, 'id', id)),
      'production_by_type': _groupBy('pipe_type_id', 'pipe_type_name',
          (id) => _store.nameOf(_store.pipeTypes, 'id', id)),
      'production_by_size': _groupBy('pipe_size_id', 'pipe_size_name',
          (id) => _store.nameOf(_store.pipeSizes, 'id', id)),
      'raw_materials': [
        for (final m in _store.rawMaterials)
          if (m['category'] != 'RECYCLED') m,
      ],
      'raw_consumption_today': [
        for (final name in consumed.keys)
          {'name': name, 'unit': 'kg', 'consumed': consumed[name]},
      ],
      'finished_goods': _store.finishedGoodsRows(),
      'finished_goods_total': _store.products.fold<int>(
          0, (sum, p) => sum + (p['quantity_bundles'] as int)),
      'dispatch_today': _dispatchToday(),
      'wastage_today': {
        'raw_wastage': 3.0,
        'production_scrap': wastage,
        'reusable': 12.5,
      },
      'machines': [
        for (final machine in _store.machines)
          {
            'machine_id': machine['id'],
            'code': machine['code'],
            'name': machine['name'],
            'status': machine['status'],
            'operators': [
              for (final a in _store.assignments)
                if (a['machine_id'] == machine['id']) a['operator_name'],
            ],
            'bundles_today': entries
                .where((e) => e['machine_id'] == machine['id'])
                .fold<int>(0, (sum, e) => sum + (e['bundle_quantity'] as int)),
          },
      ],
      'unread_notifications':
          _store.notifications.where((n) => n['is_read'] == false).length,
    };
  }

  Map<String, dynamic> _dispatchToday() {
    final iso = Fmt.isoDate(DateTime.now());
    final rows = _store.dispatchRows.where((r) => r['dispatch_date'] == iso);
    return {
      'total_bundles':
          rows.fold<int>(0, (sum, r) => sum + (r['bundle_quantity'] as int)),
      'dispatch_count': rows.map((r) => r['dispatch_id']).toSet().length,
    };
  }

  Map<String, dynamic> _operatorPayload(DateTime date) {
    final operatorId = _store.signedInProfileId ?? DemoStore.raviId;

    final mine = _today.where((e) => e['operator_id'] == operatorId).toList();
    final bundles =
        mine.fold<int>(0, (sum, e) => sum + (e['bundle_quantity'] as int));

    Map<String, dynamic>? assignment;
    for (final a in _store.assignments) {
      if (a['operator_id'] == operatorId) assignment = a;
    }

    return {
      'date': Fmt.isoDate(date),
      'assignment': assignment,
      'production_today': {
        'total_bundles': bundles,
        'total_wastage': mine.fold<double>(
            0, (sum, e) => sum + (e['wastage_quantity'] as num).toDouble()),
        'entry_count': mine.length,
      },
      'consumption_today': [
        {'name': 'Raizin', 'unit': 'kg', 'consumed': bundles * 0.82},
        {'name': 'Chemical', 'unit': 'kg', 'consumed': bundles * 0.16},
        {'name': 'Color', 'unit': 'kg', 'consumed': bundles * 0.07},
      ],
      'recent_production': [
        for (final entry in mine.reversed)
          {
            'id': entry['id'],
            'pipe_type_name':
                _store.nameOf(_store.pipeTypes, 'id', entry['pipe_type_id'] as String),
            'pipe_size_name':
                _store.nameOf(_store.pipeSizes, 'id', entry['pipe_size_id'] as String),
            'bundle_quantity': entry['bundle_quantity'],
            'shift_name':
                _store.nameOf(_store.shifts, 'id', entry['shift_id'] as String),
            'created_at': entry['created_at'],
          },
      ],
    };
  }
}

// =============================================================================
// Inventory
// =============================================================================

class DemoInventoryRepository implements InventoryRepository {
  DemoInventoryRepository(this._store);

  final DemoStore _store;

  @override
  Future<List<FinishedGoodsStock>> finishedGoods() async {
    return _latency(() => _store
        .finishedGoodsRows()
        .map(FinishedGoodsStock.from)
        .toList(growable: false));
  }

  @override
  Future<List<RecycledStock>> recycled() async {
    return _latency(
        () => _store.recycled.map(RecycledStock.from).toList(growable: false));
  }

  @override
  Future<Map<String, dynamic>> stockIn({
    required String rawMaterialId,
    required double quantity,
    required String clientRef,
    String? remarks,
  }) async {
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return {'duplicate': true};
      }
      if (quantity <= 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Quantity added must be greater than zero.',
        );
      }

      final material = _requireMaterial(rawMaterialId);
      material['quantity'] = (material['quantity'] as num) + quantity;
      _store.refreshStatuses();

      return {'duplicate': false, 'resulting_stock': material['quantity']};
    });
  }

  @override
  Future<Map<String, dynamic>> adjust({
    required String rawMaterialId,
    required double delta,
    required String clientRef,
    String? remarks,
  }) async {
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return {'duplicate': true};
      }
      if (remarks == null || remarks.trim().isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'A reason is required for a manual adjustment.',
        );
      }

      final material = _requireMaterial(rawMaterialId);
      final result = (material['quantity'] as num) + delta;

      // The same rule the database enforces: an adjustment cannot drive a
      // balance below zero (§60 RULE 5).
      if (result < 0) {
        throw AppException(
          kind: AppErrorKind.insufficientStock,
          message: 'Insufficient ${material['name']} stock. '
              'Available: ${Fmt.quantity(material['quantity'] as num)} '
              '${material['unit']}.',
          data: {'available': material['quantity']},
        );
      }

      material['quantity'] = result;
      _store.refreshStatuses();
      return {'duplicate': false, 'resulting_stock': result};
    });
  }

  @override
  Future<Map<String, dynamic>> adjustFinishedGoods({
    required String pipeTypeId,
    required String pipeSizeId,
    required int delta,
    required String clientRef,
    String? remarks,
  }) async {
    return _latency(() {
      if (!_store.usedClientRefs.add(clientRef)) {
        return {'duplicate': true};
      }

      final product = _store.productFor(pipeTypeId, pipeSizeId);
      if (product == null) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'That product is no longer available.',
        );
      }

      final result = (product['quantity_bundles'] as int) + delta;
      if (result < 0) {
        throw AppException(
          kind: AppErrorKind.insufficientStock,
          message: 'Insufficient finished-goods stock. '
              'Available: ${product['quantity_bundles']} bundles.',
          data: {'available': product['quantity_bundles']},
        );
      }

      product['quantity_bundles'] = result;
      _store.refreshStatuses();
      return {'duplicate': false, 'resulting_stock': result};
    });
  }

  Map<String, dynamic> _requireMaterial(String id) {
    final material = _store.materialById(id);
    if (material == null) {
      throw const AppException(
        kind: AppErrorKind.validation,
        message: 'That material is no longer available.',
      );
    }
    return material;
  }
}

// =============================================================================
// Mixture
// =============================================================================

class DemoMixtureRepository implements MixtureRepository {
  DemoMixtureRepository(this._store);

  final DemoStore _store;

  @override
  Future<MixtureResult> consume({
    required String machineId,
    required String shiftId,
    required List<MixtureLine> lines,
    required String clientRef,
    DateTime? entryDate,
    String? remarks,
  }) async {
    return _latency(() {
      // A34: an operator records their own machine; an administrator may record
      // any. The same split consume_raw_materials() makes, and the same codes:
      // DP006 for the wrong machine, which is what assert_can_record() raises.
      if (!_store.signedInIsAdmin && !_store.isAssignedTo(machineId)) {
        throw const AppException(
          kind: AppErrorKind.authorization,
          message: 'You are not currently assigned to that machine.',
        );
      }

      if (!_store.usedClientRefs.add(clientRef)) {
        return const MixtureResult(
            id: 'demo-duplicate', duplicate: true, totalQuantity: 0);
      }

      if (lines.isEmpty) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Enter at least one material quantity.',
        );
      }

      // Validate the whole basket before touching anything, so a batch short on
      // one material leaves the others untouched — the rule §16 is built on.
      for (final line in lines) {
        final material = _store.materialById(line.rawMaterialId);
        if (material == null) continue;

        if ((material['quantity'] as num) < line.quantity) {
          throw AppException(
            kind: AppErrorKind.insufficientStock,
            message: 'Insufficient ${material['name']} stock. '
                'Available: ${Fmt.quantity(material['quantity'] as num)} '
                '${material['unit']}.',
            data: {
              'name': material['name'],
              'available': material['quantity'],
              'requested': line.quantity,
            },
          );
        }
      }

      var total = 0.0;
      for (final line in lines) {
        final material = _store.materialById(line.rawMaterialId);
        if (material == null) continue;
        material['quantity'] = (material['quantity'] as num) - line.quantity;
        total += line.quantity;
      }

      _store.refreshStatuses();

      // The batch is kept, because production now points at it (A37).
      final id = _store.nextId('mix');
      final when = entryDate ?? DateTime.now();
      _store.mixtures.add({
        'mixture_entry_id': id,
        'entry_date': Fmt.isoDate(when),
        'machine_id': machineId,
        'shift_name': _store.nameOf(_store.shifts, 'id', shiftId),
        'operator_name':
            _store.nameOf(_store.staff, 'id', _store.signedInProfileId ?? ''),
        'charged_kg': total,
        'runs': 0,
        'created_at': DateTime.now().toIso8601String(),
      });

      return MixtureResult(id: id, duplicate: false, totalQuantity: total);
    });
  }

  @override
  Future<List<MixtureBatch>> recentBatches({
    required String machineId,
    int limit = 15,
  }) async {
    return _latency(() {
      final rows = _store.mixtures
          .where((m) => m['machine_id'] == machineId)
          .toList()
        ..sort((a, b) =>
            (b['created_at'] as String).compareTo(a['created_at'] as String));
      return rows.take(limit).map(MixtureBatch.from).toList(growable: false);
    });
  }
}

// =============================================================================
// Notifications
// =============================================================================

class DemoNotificationRepository implements NotificationRepository {
  DemoNotificationRepository(this._store);

  final DemoStore _store;

  @override
  Future<List<AppNotification>> list({int limit = 50}) async {
    return _latency(() {
      final rows = [..._store.notifications]..sort((a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String));
      return rows.take(limit).map(AppNotification.from).toList(growable: false);
    });
  }

  @override
  Future<void> markRead(String id) async {
    for (final row in _store.notifications) {
      if (row['id'] == id) row['is_read'] = true;
    }
  }

  @override
  Future<void> markAllRead() async {
    for (final row in _store.notifications) {
      row['is_read'] = true;
    }
  }
}

// =============================================================================
// Masters
// =============================================================================

class DemoMastersRepository implements MastersRepository {
  DemoMastersRepository(this._store);

  final DemoStore _store;

  @override
  Future<List<Machine>> machines({bool includeInactive = true}) async {
    return _latency(() => _store.machines
        .where((m) => includeInactive || m['active'] == true)
        .map(Machine.from)
        .toList(growable: false));
  }

  @override
  Future<void> saveMachine({
    String? id,
    required String code,
    required String name,
    required MachineStatus status,
    required bool active,
    String? description,
  }) async {
    await _latency(() => _upsert(_store.machines, id, {
          'code': code,
          'name': name,
          'status': status.wire,
          'active': active,
          'description': description,
        }));
  }

  @override
  Future<List<Shift>> shifts() async {
    return _latency(
        () => _store.shifts.map(Shift.from).toList(growable: false));
  }

  @override
  Future<void> saveShift({
    String? id,
    required String name,
    required String startTime,
    required String endTime,
    required bool active,
  }) async {
    await _latency(() {
      if (!_store.signedInIsAdmin) throw _refused;

      if (id == null) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Only the Morning and Night shifts are supported.',
        );
      }

      final row = _store.shifts.firstWhere((s) => s['id'] == id);
      if (row['name'] != name) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Shift names cannot be changed.',
        );
      }
      if (!active && _isAllowedShift(name)) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'The Morning and Night shifts cannot be switched off.',
        );
      }

      row
        ..['start_time'] = startTime
        ..['end_time'] = endTime;
    });
  }

  @override
  Future<List<PipeType>> pipeTypes() async {
    return _latency(
        () => _store.pipeTypes.map(PipeType.from).toList(growable: false));
  }

  @override
  Future<void> savePipeType({
    String? id,
    required String code,
    required String name,
    required bool active,
    String? description,
    String? recycledMaterialId,
  }) async {
    await _latency(() => _upsert(_store.pipeTypes, id, {
          'code': code,
          'name': name,
          'active': active,
          'description': description,
          'recycled_material_id': recycledMaterialId,
        }));
  }

  @override
  Future<List<PipeSize>> pipeSizes() async {
    return _latency(
        () => _store.pipeSizes.map(PipeSize.from).toList(growable: false));
  }

  @override
  Future<void> savePipeSize({
    String? id,
    required String code,
    required String name,
    required int sortOrder,
    required bool active,
    String? description,
    double? diameterMm,
    double? lengthM,
  }) async {
    await _latency(() => _upsert(_store.pipeSizes, id, {
          'code': code,
          'name': name,
          'sort_order': sortOrder,
          'active': active,
          'description': description,
          'diameter_mm': diameterMm,
          'length_m': lengthM,
        }));
  }

  @override
  Future<List<PipeProduct>> products() async {
    return _latency(() {
      _store.refreshStatuses();
      final rows = [..._store.products]
        ..sort((a, b) => (a['sku'] as String).compareTo(b['sku'] as String));
      return rows.map(PipeProduct.from).toList(growable: false);
    });
  }

  @override
  Future<void> saveProduct({
    required String pipeTypeId,
    required String pipeSizeId,
    required String sku,
    required double bundleWeightKg,
    int? pipesPerBundle,
    double? coilLengthM,
    bool active = true,
    int? pipesPerBag,
  }) async {
    await _latency(() {
      if (!_store.signedInIsAdmin) throw _refused;

      if (pipesPerBag != null && pipesPerBag <= 0) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message: 'Pipes per bag must be greater than zero.',
        );
      }
      if (pipesPerBag != null && pipesPerBundle == null) {
        throw const AppException(
          kind: AppErrorKind.validation,
          message:
              'Set pipes per bundle as well — bag weight is worked out from it.',
        );
      }

      final existing = _store.productFor(pipeTypeId, pipeSizeId);
      if (existing != null) {
        existing
          ..['sku'] = sku
          ..['bundle_weight_kg'] = bundleWeightKg
          ..['pipes_per_bundle'] = pipesPerBundle
          ..['pipes_per_bag'] = pipesPerBag
          ..['active'] = active;
      } else {
        final size = _store.pipeSizes.firstWhere((s) => s['id'] == pipeSizeId);
        _store.products.add({
          'pipe_product_id': _store.nextId('prod'),
          'sku': sku,
          'pipe_type_id': pipeTypeId,
          'pipe_type_name':
              _store.nameOf(_store.pipeTypes, 'id', pipeTypeId) ?? '—',
          'pipe_size_id': pipeSizeId,
          'pipe_size_name': size['name'],
          'sort_order': size['sort_order'],
          'bundle_weight_kg': bundleWeightKg,
          'pipes_per_bundle': pipesPerBundle,
          'pipes_per_bag': pipesPerBag,
          'bag_weight_kg': null,
          'quantity_bags': 0,
          'diameter_mm': size['diameter_mm'],
          'active': active,
          'quantity_bundles': 0,
          'stock_weight_kg': 0.0,
          'minimum_stock': 0,
          'status': 'OUT',
        });
      }
      _store.refreshStatuses();
    });
  }

  @override
  Future<void> setFinishedGoodsThreshold({
    required String pipeTypeId,
    required String pipeSizeId,
    required int minimumStock,
  }) async {
    await _latency(() {
      _store.productFor(pipeTypeId, pipeSizeId)?['minimum_stock'] = minimumStock;
      _store.refreshStatuses();
    });
  }

  @override
  Future<Set<String>> machineProductIds(String machineId) async {
    return _latency(() => {...?_store.machineProducts[machineId]});
  }

  @override
  Future<void> setMachineProducts(
    String machineId,
    List<String> productIds,
  ) async {
    await _latency(() => _store.machineProducts[machineId] = {...productIds});
  }

  @override
  Future<List<RawMaterial>> rawMaterials() async {
    return _latency(() {
      _store.refreshStatuses();
      return _store.rawMaterials.map(RawMaterial.from).toList(growable: false);
    });
  }

  @override
  Future<List<Map<String, dynamic>>> rawMaterialCategories() async {
    return _latency(() => [..._store.categories]);
  }

  @override
  Future<void> saveRawMaterial({
    String? id,
    required String code,
    required String name,
    required String category,
    required String unit,
    required double minimumStock,
    required bool active,
    bool isRecycled = false,
  }) async {
    await _latency(() {
      final existing =
          id == null ? null : _store.materialById(id);

      if (existing != null) {
        existing
          ..['code'] = code
          ..['name'] = name
          ..['category'] = category
          ..['category_name'] = _categoryName(category)
          ..['unit'] = unit
          ..['minimum_stock'] = minimumStock
          ..['active'] = active;
      } else {
        final newId = _store.nextId('rm');
        _store.rawMaterials.add({
          'raw_material_id': newId,
          'id': newId,
          'code': code,
          'name': name,
          'category': category,
          'category_name': _categoryName(category),
          'unit': unit,
          'minimum_stock': minimumStock,
          'quantity': 0.0,
          'status': 'OUT',
          'active': active,
        });
      }
      _store.refreshStatuses();
    });
  }

  @override
  Future<List<StaffMember>> staff({bool includeInactive = true}) async {
    return _latency(() => _store.staff
        .where((p) => includeInactive || p['active'] == true)
        .map(StaffMember.from)
        .toList(growable: false));
  }

  @override
  Future<void> saveStaff({
    String? id,
    required String name,
    required String employeeCode,
    required String role,
    required bool active,
    String? phone,
  }) async {
    await _latency(() => _upsert(_store.staff, id, {
          'name': name,
          'employee_code': employeeCode,
          'role': role,
          'active': active,
          'phone': phone,
          'auth_user_id': null,
        }));
  }

  @override
  Future<Map<String, dynamic>> linkLogin({
    required String employeeCode,
    required String email,
  }) async {
    return _latency(() {
      // The real implementation needs a service-role key and so runs in an Edge
      // Function (A3). Demo mode says so rather than pretending it worked.
      throw const AppException(
        kind: AppErrorKind.notConfigured,
        message: 'Linking a login needs the live backend. '
            'This is demo mode, so nothing was changed.',
      );
    });
  }

  @override
  Future<List<MachineAssignment>> assignments() async {
    return _latency(() => _store.assignments
        .map(MachineAssignment.from)
        .toList(growable: false));
  }

  @override
  Future<void> assignOperator({
    required String operatorId,
    required String machineId,
    String? shiftId,
  }) async {
    await _latency(() {
      _store.assignments.removeWhere((a) => a['operator_id'] == operatorId);

      final person = _store.staff.firstWhere((p) => p['id'] == operatorId);
      final machine = _store.machines.firstWhere((m) => m['id'] == machineId);
      final shift = shiftId == null
          ? null
          : _store.shifts.firstWhere((s) => s['id'] == shiftId);

      _store.assignments.add({
        'assignment_id': _store.nextId('asg'),
        'operator_id': operatorId,
        'operator_name': person['name'],
        'employee_code': person['employee_code'],
        'machine_id': machineId,
        'machine_name': machine['name'],
        'machine_code': machine['code'],
        'machine_status': machine['status'],
        'shift_id': shiftId,
        'shift_name': shift?['name'],
        'start_time': shift?['start_time'],
        'end_time': shift?['end_time'],
        'effective_from': Fmt.isoDate(DateTime.now()),
      });
    });
  }

  @override
  Future<void> endAssignment(String operatorId) async {
    await _latency(
        () => _store.assignments.removeWhere((a) => a['operator_id'] == operatorId));
  }

  @override
  Future<List<AppSetting>> settings() async {
    return _latency(
        () => _store.settings.map(AppSetting.from).toList(growable: false));
  }

  @override
  Future<void> setSetting(String key, String value) async {
    await _latency(() {
      for (final row in _store.settings) {
        if (row['key'] == key) row['value'] = value;
      }
    });
  }

  String _categoryName(String code) {
    for (final row in _store.categories) {
      if (row['code'] == code) return row['name'] as String;
    }
    return code;
  }

  /// Updates the row with [id], or appends a new one when [id] is null.
  void _upsert(
    List<Map<String, dynamic>> rows,
    String? id,
    Map<String, dynamic> values,
  ) {
    if (id != null) {
      for (final row in rows) {
        if (row['id'] == id) {
          row.addAll(values);
          return;
        }
      }
    }
    rows.add({'id': _store.nextId('row'), ...values});
  }
}
