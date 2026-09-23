import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';
import '../domain/masters.dart';

/// Master data access for Phase 2 (§32).
///
/// Master tables are the one part of the schema a client may write to directly:
/// RLS grants `for all` to administrators and read to everyone, because they
/// describe the factory rather than record what happened in it. Operational
/// tables still have no INSERT policy at all, so nothing here can move stock.
///
/// Three operations do go through RPCs, because they are more than one row:
///   * `upsert_pipe_product` also seeds the finished-goods row, so a new
///     product appears in stock views at zero instead of vanishing;
///   * `set_machine_products` swaps a machine's whole capability list under a
///     lock, so a machine is never briefly able to run nothing;
///   * `link_profile_to_auth_user` refuses to steal a login that already
///     belongs to somebody else, which a raw UPDATE would do silently.
class MastersRepository {
  const MastersRepository(this._client);

  final SupabaseClient _client;

  // ---------------------------------------------------------------------------
  // Machines
  // ---------------------------------------------------------------------------

  Future<List<Machine>> machines({bool includeInactive = true}) async {
    return _guard(() async {
      var query = _client.from('machines').select(
            'id, code, name, description, status, active',
          );
      if (!includeInactive) query = query.eq('active', true);
      final rows = await query.order('code');
      return rows.map(Machine.from).toList(growable: false);
    });
  }

  Future<void> saveMachine({
    String? id,
    required String code,
    required String name,
    required MachineStatus status,
    required bool active,
    String? description,
  }) async {
    return _guard(() async {
      final payload = {
        'code': code.trim(),
        'name': name.trim(),
        'description': _nullIfBlank(description),
        'status': status.wire,
        'active': active,
      };

      if (id == null) {
        await _client.from('machines').insert(payload);
      } else {
        await _client.from('machines').update(payload).eq('id', id);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Shifts
  // ---------------------------------------------------------------------------

  Future<List<Shift>> shifts() async {
    return _guard(() async {
      final rows = await _client
          .from('shifts')
          .select('id, name, start_time, end_time, active')
          .order('start_time');
      return rows.map(Shift.from).toList(growable: false);
    });
  }

  Future<void> saveShift({
    String? id,
    required String name,
    required String startTime,
    required String endTime,
    required bool active,
  }) async {
    return _guard(() async {
      final payload = {
        'name': name.trim(),
        'start_time': startTime,
        'end_time': endTime,
        'active': active,
      };
      if (id == null) {
        await _client.from('shifts').insert(payload);
      } else {
        await _client.from('shifts').update(payload).eq('id', id);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Pipe types and sizes
  // ---------------------------------------------------------------------------

  Future<List<PipeType>> pipeTypes() async {
    return _guard(() async {
      final rows = await _client
          .from('pipe_types')
          .select('id, code, name, description, active, recycled_material_id')
          .order('name');
      return rows.map(PipeType.from).toList(growable: false);
    });
  }

  Future<void> savePipeType({
    String? id,
    required String code,
    required String name,
    required bool active,
    String? description,
    String? recycledMaterialId,
  }) async {
    return _guard(() async {
      final payload = {
        'code': code.trim(),
        'name': name.trim(),
        'description': _nullIfBlank(description),
        'active': active,
        'recycled_material_id': recycledMaterialId,
      };
      if (id == null) {
        await _client.from('pipe_types').insert(payload);
      } else {
        await _client.from('pipe_types').update(payload).eq('id', id);
      }
    });
  }

  Future<List<PipeSize>> pipeSizes() async {
    return _guard(() async {
      final rows = await _client
          .from('pipe_sizes')
          .select(
            'id, code, name, description, sort_order, diameter_mm, length_m, active',
          )
          .order('sort_order');
      return rows.map(PipeSize.from).toList(growable: false);
    });
  }

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
    return _guard(() async {
      final payload = {
        'code': code.trim(),
        'name': name.trim(),
        'description': _nullIfBlank(description),
        'sort_order': sortOrder,
        'diameter_mm': diameterMm,
        'length_m': lengthM,
        'active': active,
      };
      if (id == null) {
        await _client.from('pipe_sizes').insert(payload);
      } else {
        await _client.from('pipe_sizes').update(payload).eq('id', id);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Products and their bundle weights (A21)
  // ---------------------------------------------------------------------------

  Future<List<PipeProduct>> products() async {
    return _guard(() async {
      final rows = await _client.from('v_pipe_products').select().order('sku');
      return rows.map(PipeProduct.from).toList(growable: false);
    });
  }

  /// Creates or retunes a product. Goes through the RPC rather than the table so
  /// the finished-goods row is seeded in the same transaction.
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
    return _guard(() async {
      await _client.rpc<Map<String, dynamic>>(
        'upsert_pipe_product',
        params: {
          'p_pipe_type_id': pipeTypeId,
          'p_pipe_size_id': pipeSizeId,
          'p_sku': sku.trim(),
          'p_bundle_weight_kg': bundleWeightKg,
          'p_pipes_per_bundle': pipesPerBundle,
          'p_coil_length_m': coilLengthM,
          'p_active': active,
          'p_pipes_per_bag': pipesPerBag,
        },
      );
    });
  }

  /// The reorder threshold, not the quantity. A quantity change is refused by
  /// the `fg_stock_guard` trigger no matter who asks.
  Future<void> setFinishedGoodsThreshold({
    required String pipeTypeId,
    required String pipeSizeId,
    required int minimumStock,
  }) async {
    return _guard(() async {
      await _client
          .from('finished_goods_stock')
          .update({'minimum_stock': minimumStock})
          .eq('pipe_type_id', pipeTypeId)
          .eq('pipe_size_id', pipeSizeId);
    });
  }

  // ---------------------------------------------------------------------------
  // Machine capabilities (A23)
  // ---------------------------------------------------------------------------

  Future<Set<String>> machineProductIds(String machineId) async {
    return _guard(() async {
      final rows = await _client
          .from('machine_products')
          .select('pipe_product_id')
          .eq('machine_id', machineId)
          .eq('active', true);
      return rows.map((r) => r['pipe_product_id'] as String).toSet();
    });
  }

  Future<void> setMachineProducts(
    String machineId,
    List<String> productIds,
  ) async {
    return _guard(() async {
      await _client.rpc<Map<String, dynamic>>(
        'set_machine_products',
        params: {
          'p_machine_id': machineId,
          'p_pipe_product_ids': productIds,
        },
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Raw materials
  // ---------------------------------------------------------------------------

  Future<List<RawMaterial>> rawMaterials() async {
    return _guard(() async {
      final rows =
          await _client.from('v_raw_material_stock').select().order('name');
      return rows.map(RawMaterial.from).toList(growable: false);
    });
  }

  Future<List<Map<String, dynamic>>> rawMaterialCategories() async {
    return _guard(() async {
      final rows = await _client
          .from('raw_material_categories')
          .select('code, name')
          .eq('active', true)
          .order('name');
      return rows;
    });
  }

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
    return _guard(() async {
      final payload = {
        'code': code.trim(),
        'name': name.trim(),
        'category': category,
        'unit': unit.trim(),
        'minimum_stock': minimumStock,
        'active': active,
        'is_recycled': isRecycled,
      };
      if (id == null) {
        await _client.from('raw_materials').insert(payload);
      } else {
        await _client.from('raw_materials').update(payload).eq('id', id);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Staff
  // ---------------------------------------------------------------------------

  Future<List<StaffMember>> staff({bool includeInactive = true}) async {
    return _guard(() async {
      var query = _client.from('profiles').select(
            'id, name, employee_code, phone, role, active, auth_user_id',
          );
      if (!includeInactive) query = query.eq('active', true);
      final rows = await query.order('employee_code');
      return rows.map(StaffMember.from).toList(growable: false);
    });
  }

  Future<void> saveStaff({
    String? id,
    required String name,
    required String employeeCode,
    required String role,
    required bool active,
    String? phone,
  }) async {
    return _guard(() async {
      final payload = {
        'name': name.trim(),
        'employee_code': employeeCode.trim(),
        'role': role,
        'active': active,
        'phone': _nullIfBlank(phone),
      };
      if (id == null) {
        await _client.from('profiles').insert(payload);
      } else {
        await _client.from('profiles').update(payload).eq('id', id);
      }
    });
  }

  /// Attaches an existing Supabase login to a profile (A3). The login itself is
  /// created in the Supabase dashboard — doing it from the app would need a
  /// service-role key, which must never ship inside an APK (§56).
  Future<Map<String, dynamic>> linkLogin({
    required String employeeCode,
    required String email,
  }) async {
    return _guard(() async {
      return await _client.rpc<Map<String, dynamic>>(
        'link_profile_to_auth_user',
        params: {
          'p_employee_code': employeeCode.trim(),
          'p_email': email.trim(),
        },
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Machine assignments (§10)
  // ---------------------------------------------------------------------------

  Future<List<MachineAssignment>> assignments() async {
    return _guard(() async {
      final rows = await _client
          .from('v_current_machine_assignments')
          .select()
          .order('machine_code');
      return rows.map(MachineAssignment.from).toList(growable: false);
    });
  }

  /// Moves an operator onto a machine.
  ///
  /// A person has at most one open assignment (enforced by a partial unique
  /// index), so any existing one is closed first — with an end date, never a
  /// delete, so the history behind past production stays intact.
  Future<void> assignOperator({
    required String operatorId,
    required String machineId,
    String? shiftId,
  }) async {
    return _guard(() async {
      await _endOpenAssignment(operatorId);
      await _client.from('machine_assignments').insert({
        'operator_id': operatorId,
        'machine_id': machineId,
        'shift_id': shiftId,
        'effective_from': Fmt.isoDate(DateTime.now()),
      });
    });
  }

  Future<void> endAssignment(String operatorId) async {
    return _guard(() => _endOpenAssignment(operatorId));
  }

  Future<void> _endOpenAssignment(String operatorId) async {
    await _client
        .from('machine_assignments')
        .update({'effective_to': Fmt.isoDate(DateTime.now())})
        .eq('operator_id', operatorId)
        .isFilter('effective_to', null);
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<List<AppSetting>> settings() async {
    return _guard(() async {
      final rows = await _client
          .from('app_settings')
          .select('key, value, description')
          .order('key');
      return rows.map(AppSetting.from).toList(growable: false);
    });
  }

  Future<void> setSetting(String key, String value) async {
    return _guard(() async {
      await _client.from('app_settings').update({'value': value}).eq('key', key);
    });
  }

  /// Every call funnels through here so a `PostgrestException` can never escape
  /// the data layer (§45).
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  static String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}

final mastersRepositoryProvider = Provider<MastersRepository>((ref) {
  return MastersRepository(ref.watch(supabaseClientProvider));
});

// -----------------------------------------------------------------------------
// Read providers. Each screen watches only what it shows, so saving a shift does
// not re-fetch the machine list.
// -----------------------------------------------------------------------------

final machinesProvider = FutureProvider<List<Machine>>((ref) {
  return ref.watch(mastersRepositoryProvider).machines();
});

final shiftsProvider = FutureProvider<List<Shift>>((ref) {
  return ref.watch(mastersRepositoryProvider).shifts();
});

final pipeTypesProvider = FutureProvider<List<PipeType>>((ref) {
  return ref.watch(mastersRepositoryProvider).pipeTypes();
});

final pipeSizesProvider = FutureProvider<List<PipeSize>>((ref) {
  return ref.watch(mastersRepositoryProvider).pipeSizes();
});

final productsProvider = FutureProvider<List<PipeProduct>>((ref) {
  return ref.watch(mastersRepositoryProvider).products();
});

final rawMaterialsProvider = FutureProvider<List<RawMaterial>>((ref) {
  return ref.watch(mastersRepositoryProvider).rawMaterials();
});

final staffProvider = FutureProvider<List<StaffMember>>((ref) {
  return ref.watch(mastersRepositoryProvider).staff();
});

final assignmentsProvider = FutureProvider<List<MachineAssignment>>((ref) {
  return ref.watch(mastersRepositoryProvider).assignments();
});

final settingsProvider = FutureProvider<List<AppSetting>>((ref) {
  return ref.watch(mastersRepositoryProvider).settings();
});

final machineProductIdsProvider =
    FutureProvider.family<Set<String>, String>((ref, machineId) {
  return ref.watch(mastersRepositoryProvider).machineProductIds(machineId);
});

/// Invalidated together after any write that could change more than one list —
/// saving a product, for instance, also changes finished-goods stock.
void invalidateMasters(WidgetRef ref) {
  ref
    ..invalidate(machinesProvider)
    ..invalidate(shiftsProvider)
    ..invalidate(pipeTypesProvider)
    ..invalidate(pipeSizesProvider)
    ..invalidate(productsProvider)
    ..invalidate(rawMaterialsProvider)
    ..invalidate(staffProvider)
    ..invalidate(assignmentsProvider)
    ..invalidate(settingsProvider);
}
