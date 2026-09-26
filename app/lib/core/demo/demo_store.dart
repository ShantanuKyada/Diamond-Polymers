import '../utils/formatters.dart';

/// In-memory stand-in for the database, used only by demo mode.
///
/// Rows are held in exactly the shape the corresponding view or table returns,
/// because every domain model parses itself with a `Model.from(Map)` factory.
/// Keeping the demo data in row shape means the models are exercised for real —
/// if a column is renamed in the schema, demo mode breaks in the same place
/// live data would, instead of quietly diverging.
///
/// The figures mirror `supabase/seed.sql` so the two tell the same story.
/// Nothing here is persisted: a reload restores the seeded state.
class DemoStore {
  DemoStore() {
    _seed();
  }

  /// Artificial delay on every demo read and write, so loading states and
  /// disabled submit buttons are visible rather than flashing past. Widget
  /// tests set this to zero: a pending timer never settles, and a spinner
  /// that is still animating makes pumpAndSettle time out.
  static Duration latency = const Duration(milliseconds: 320);

  // Fixed ids, matching seed.sql so screenshots and SQL line up.
  static const raizinId = '55555555-5555-4555-8555-000000000001';
  static const chemicalId = '55555555-5555-4555-8555-000000000002';
  static const colorId = '55555555-5555-4555-8555-000000000003';
  static const regrindId = '55555555-5555-4555-8555-000000000004';

  static const machine1 = '11111111-1111-4111-8111-000000000001';
  static const machine2 = '11111111-1111-4111-8111-000000000002';
  static const machine3 = '11111111-1111-4111-8111-000000000003';
  static const machine4 = '11111111-1111-4111-8111-000000000004';

  static const shiftMorning = '22222222-2222-4222-8222-000000000001';
  static const shiftNight = '22222222-2222-4222-8222-000000000003';

  static const typeA = '33333333-3333-4333-8333-000000000001';
  static const typeB = '33333333-3333-4333-8333-000000000002';

  static const adminId = '66666666-6666-4666-8666-000000000001';
  static const raviId = '66666666-6666-4666-8666-000000000002';

  final List<Map<String, dynamic>> rawMaterials = [];
  final List<Map<String, dynamic>> categories = [];
  final List<Map<String, dynamic>> machines = [];
  final List<Map<String, dynamic>> shifts = [];
  final List<Map<String, dynamic>> pipeTypes = [];
  final List<Map<String, dynamic>> pipeSizes = [];
  final List<Map<String, dynamic>> products = [];
  final List<Map<String, dynamic>> staff = [];
  final List<Map<String, dynamic>> assignments = [];
  final List<Map<String, dynamic>> settings = [];
  final List<Map<String, dynamic>> notifications = [];
  final List<Map<String, dynamic>> productionEntries = [];

  /// Material batches (A37). The demo kept none before, because nothing read
  /// them back — a production run now belongs to one, so they have to persist
  /// for the demo to behave like the real thing.
  final List<Map<String, dynamic>> mixtures = [];
  final List<Map<String, dynamic>> recycled = [];
  final List<Map<String, dynamic>> dispatchRows = [];
  final List<Map<String, dynamic>> wastageRows = [];
  final List<Map<String, dynamic>> attendanceRows = [];
  final List<Map<String, dynamic>> monthlyAttendanceRows = [];
  final List<Map<String, dynamic>> payslipRows = [];
  final List<Map<String, dynamic>> advanceRows = [];

  /// Who is signed in. Set by the demo auth repository, and read by the
  /// repositories that behave differently for an administrator — exactly as
  /// the database reads auth.uid().
  String? signedInProfileId;

  bool get signedInIsAdmin {
    final id = signedInProfileId;
    if (id == null) return false;
    for (final person in staff) {
      if (person['id'] == id) return person['role'] == 'ADMIN';
    }
    return false;
  }

  /// Whether the signed-in person currently runs this machine (A34).
  ///
  /// Mirrors `app.assert_can_record()`: it is the assignment that grants the
  /// right to record, not the role.
  bool isAssignedTo(String machineId) {
    final id = signedInProfileId;
    if (id == null) return false;
    return assignments.any(
      (a) => a['operator_id'] == id && a['machine_id'] == machineId,
    );
  }

  /// machine id -> the products that machine is allowed to run.
  final Map<String, Set<String>> machineProducts = {};

  /// Client references already seen, so a retried submission is recognised as
  /// a duplicate exactly as the real RPCs do (§47).
  final Set<String> usedClientRefs = {};

  int _sequence = 0;

  String nextId(String prefix) => '$prefix-${(++_sequence).toString().padLeft(4, '0')}';

  // ---------------------------------------------------------------------------
  // Derived values. Recomputed on read so a write on one screen shows up on
  // every other screen, the way a real query would.
  // ---------------------------------------------------------------------------

  static String stockStatus(num quantity, num minimum) {
    if (quantity <= 0) return 'OUT';
    if (minimum > 0 && quantity <= minimum) return 'LOW';
    return 'GOOD';
  }

  void refreshStatuses() {
    for (final material in rawMaterials) {
      material['status'] = stockStatus(
        material['quantity'] as num,
        material['minimum_stock'] as num,
      );
    }
    for (final product in products) {
      final bundles = product['quantity_bundles'] as int;
      product['stock_weight_kg'] =
          bundles * (product['bundle_weight_kg'] as num).toDouble();

      // Derived exactly as the database derives it (A26).
      final perBag = product['pipes_per_bag'] as int?;
      final perBundle = product['pipes_per_bundle'] as int?;
      product['bag_weight_kg'] = perBag == null || perBundle == null
          ? null
          : double.parse(((product['bundle_weight_kg'] as num) *
                  perBag /
                  perBundle)
              .toStringAsFixed(3));
      product['status'] = stockStatus(bundles, product['minimum_stock'] as num);
    }
  }

  Map<String, dynamic>? materialById(String id) {
    for (final material in rawMaterials) {
      if (material['raw_material_id'] == id) return material;
    }
    return null;
  }

  Map<String, dynamic>? productFor(String pipeTypeId, String pipeSizeId) {
    for (final product in products) {
      if (product['pipe_type_id'] == pipeTypeId &&
          product['pipe_size_id'] == pipeSizeId) {
        return product;
      }
    }
    return null;
  }

  /// `v_finished_goods_stock` — the type x size matrix the admin screens read.
  List<Map<String, dynamic>> finishedGoodsRows() {
    refreshStatuses();
    final rows = [
      for (final product in products)
        {
          'pipe_type_id': product['pipe_type_id'],
          'pipe_type_name': product['pipe_type_name'],
          'pipe_size_id': product['pipe_size_id'],
          'pipe_size_name': product['pipe_size_name'],
          'sort_order': product['sort_order'],
          'quantity_bundles': product['quantity_bundles'],
          'quantity_bags': product['quantity_bags'],
          'minimum_stock': product['minimum_stock'],
          'status': product['status'],
        },
    ];
    rows.sort((a, b) {
      final byType =
          (a['pipe_type_name'] as String).compareTo(b['pipe_type_name'] as String);
      return byType != 0
          ? byType
          : (a['sort_order'] as int).compareTo(b['sort_order'] as int);
    });
    return rows;
  }

  String? nameOf(List<Map<String, dynamic>> rows, String idKey, String id) {
    for (final row in rows) {
      if (row[idKey] == id) return row['name'] as String?;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Seed
  // ---------------------------------------------------------------------------

  void _seed() {
    categories.addAll([
      {'code': 'RAIZIN', 'name': 'Raizin'},
      {'code': 'CHEMICAL', 'name': 'Chemical'},
      {'code': 'COLOR', 'name': 'Color'},
      {'code': 'RECYCLED', 'name': 'Recycled'},
    ]);

    rawMaterials.addAll([
      _material(raizinId, 'RM-RAIZIN', 'Raizin', 'RAIZIN', 1842.5, 400),
      // Deliberately under its threshold, so the low-stock banner, the status
      // chip and the alerts list all have something real to show.
      _material(chemicalId, 'RM-CHEM', 'Chemical', 'CHEMICAL', 38.0, 50),
      _material(colorId, 'RM-COLOR', 'Color', 'COLOR', 96.5, 20),
      _material(regrindId, 'RM-REGRIND', 'Regrind', 'RECYCLED', 124.0, 0),
    ]);

    machines.addAll([
      _machine(machine1, 'M1', 'Machine 1', 'Braiding line 1', 'ACTIVE'),
      _machine(machine2, 'M2', 'Machine 2', 'Braiding line 2', 'ACTIVE'),
      _machine(machine3, 'M3', 'Machine 3', 'Braiding line 3', 'ACTIVE'),
      _machine(machine4, 'M4', 'Machine 4', 'Braiding head service due',
          'MAINTENANCE'),
    ]);

    shifts.addAll([
      // Exactly two shifts (A29), covering the day between them.
      {
        'id': shiftMorning,
        'name': 'Morning',
        'start_time': '06:00:00',
        'end_time': '18:00:00',
        'active': true,
      },
      {
        'id': shiftNight,
        'name': 'Night',
        'start_time': '18:00:00',
        'end_time': '06:00:00',
        'active': true,
      },
    ]);

    pipeTypes.addAll([
      {
        'id': typeA,
        'code': 'TA',
        'name': 'Type A',
        'description': 'Standard braided',
        'active': true,
        'recycled_material_id': regrindId,
      },
      {
        'id': typeB,
        'code': 'TB',
        'name': 'Type B',
        'description': 'Heavy-duty braided',
        'active': true,
        'recycled_material_id': regrindId,
      },
    ]);

    const sizeSpecs = [
      ('S1', 'Size 1', '1/2 inch', 1, 12.7, 100.0),
      ('S2', 'Size 2', '3/4 inch', 2, 19.05, 100.0),
      ('S3', 'Size 3', '1 inch', 3, 25.4, 50.0),
      ('S4', 'Size 4', '1.25 inch', 4, 31.75, 50.0),
    ];

    for (final (index, spec) in sizeSpecs.indexed) {
      final (code, name, description, order, diameter, length) = spec;
      pipeSizes.add({
        'id': '44444444-4444-4444-8444-00000000000${index + 1}',
        'code': code,
        'name': name,
        'description': description,
        'sort_order': order,
        'diameter_mm': diameter,
        'length_m': length,
        'active': true,
      });
    }

    // One product per type x size, with the bundle weight that makes the
    // kg <-> bundle conversion work.
    const bundleWeights = {1: 18.0, 2: 24.0, 3: 31.0, 4: 38.0};

    // Pipes per bundle and per bag, by size. The largest size is not bagged, so
    // "bag packing not set up" is a real state in the demo too.
    const pipesPerBundle = {1: 10, 2: 8, 3: 6, 4: 5};
    const pipesPerBag = {1: 20, 2: 16, 3: 12, 4: null};
    const openingBags = {
      (typeA, 1): 18,
      (typeA, 2): 9,
      (typeA, 3): 6,
      (typeB, 1): 12,
      (typeB, 2): 7,
      (typeB, 3): 4,
    };
    const openingBundles = {
      (typeA, 1): 64,
      (typeA, 2): 12, // low against its threshold of 15
      (typeA, 3): 51,
      (typeA, 4): 40,
      (typeB, 1): 33,
      (typeB, 2): 28,
      (typeB, 3): 45,
      (typeB, 4): 25,
    };

    for (final type in pipeTypes) {
      for (final size in pipeSizes) {
        final order = size['sort_order'] as int;
        final key = (type['id'] as String, order);
        products.add({
          'pipe_product_id': 'prod-${type['code']}-${size['code']}',
          'sku': '${type['code']}-${size['code']}',
          'pipe_type_id': type['id'],
          'pipe_type_name': type['name'],
          'pipe_size_id': size['id'],
          'pipe_size_name': size['name'],
          'sort_order': order,
          'bundle_weight_kg': bundleWeights[order],
          'pipes_per_bundle': pipesPerBundle[order],
          'pipes_per_bag': pipesPerBag[order],
          'quantity_bags': openingBags[key] ?? 0,
          'bag_weight_kg': null,
          'diameter_mm': size['diameter_mm'],
          'active': true,
          'quantity_bundles': openingBundles[key] ?? 30,
          'stock_weight_kg': 0.0,
          'minimum_stock': 15,
          'status': 'GOOD',
        });
      }
    }

    staff.addAll([
      _person(adminId, 'Factory Admin', 'EMP-001', 'ADMIN', hasLogin: true),
      _person(raviId, 'Ravi Kumar', 'EMP-101', 'OPERATOR', hasLogin: true),
      _person('66666666-6666-4666-8666-000000000003', 'Suresh Patel', 'EMP-102',
          'OPERATOR'),
      _person('66666666-6666-4666-8666-000000000004', 'Imran Shaikh', 'EMP-103',
          'OPERATOR'),
      _person('66666666-6666-4666-8666-000000000005', 'Ganesh Jadhav', 'EMP-104',
          'OPERATOR'),
    ]);

    _assign(raviId, machine1, shiftMorning);
    _assign('66666666-6666-4666-8666-000000000003', machine2, shiftMorning);
    _assign('66666666-6666-4666-8666-000000000004', machine3, shiftNight);
    _assign('66666666-6666-4666-8666-000000000005', machine4, shiftNight);

    for (final machine in machines) {
      machineProducts[machine['id'] as String] = {
        for (final product in products) product['pipe_product_id'] as String,
      };
    }

    settings.addAll([
      {
        'key': 'factory_name',
        'value': 'Diamond Polymers',
        'description': 'Shown in the app header and on reports.',
      },
      {
        'key': 'production_wastage_unit',
        'value': 'kg',
        'description': 'Unit for the wastage figure on a production entry.',
      },
      {
        'key': 'reusable_wastage_mode',
        'value': 'SEPARATE',
        'description':
            'SEPARATE keeps recycled material out of virgin raw stock.',
      },
      {
        'key': 'currency_symbol',
        'value': '₹',
        'description': 'Currency shown on payroll screens.',
      },
      {
        'key': 'low_stock_banner_enabled',
        'value': 'true',
        'description': 'Show the low-stock banner on the admin dashboard.',
      },
    ]);

    recycled.add({
      'raw_material_id': regrindId,
      'code': 'RM-REGRIND',
      'name': 'Regrind',
      'unit': 'kg',
      'quantity': 124.0,
      'total_recovered_kg': 186.5,
      'total_consumed_kg': 62.5,
    });

    _seedProduction();
    _seedDispatch();
    _seedWastage();
    _seedStaff();
    _seedNotifications();
    refreshStatuses();
  }

  void _seedProduction() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    const suresh = '66666666-6666-4666-8666-000000000003';
    const imran = '66666666-6666-4666-8666-000000000004';

    // (days ago, machine, operator, shift, type, size, bundles, bags,
    //  scrap kg, wastage used kg or null, hour of the day)
    const shape = [
      // Today, across the running machines.
      (0, machine1, raviId, shiftMorning, typeA, 1, 34, 0, 1.4, 6.5, 8),
      (0, machine1, raviId, shiftMorning, typeA, 3, 22, 4, 0.9, null, 11),
      (0, machine2, suresh, shiftMorning, typeB, 2, 28, 0, 1.1, null, 10),
      (0, machine2, suresh, shiftMorning, typeB, 4, 19, 0, 0.8, 4.0, 13),
      (0, machine3, imran, shiftNight, typeA, 2, 0, 12, 1.0, null, 20),
      // Ravi's week, so My Entries has something to show for every day.
      (1, machine1, raviId, shiftMorning, typeA, 1, 30, 6, 1.2, 5.0, 9),
      (1, machine1, raviId, shiftMorning, typeA, 2, 18, 0, 0.7, null, 14),
      (2, machine1, raviId, shiftMorning, typeB, 1, 26, 0, 1.0, null, 10),
      (3, machine1, raviId, shiftNight, typeA, 3, 20, 5, 0.8, 3.5, 21),
      (4, machine1, raviId, shiftMorning, typeA, 1, 32, 0, 1.3, null, 9),
      (5, machine1, raviId, shiftMorning, typeB, 2, 0, 10, 0.6, 2.0, 12),
      (6, machine1, raviId, shiftMorning, typeA, 1, 29, 3, 1.1, null, 10),
      // Older than a week: must NOT appear in My Entries.
      (9, machine1, raviId, shiftMorning, typeA, 1, 25, 0, 1.0, null, 10),
    ];

    for (final row in shape) {
      final (
        daysAgo,
        machineId,
        operatorId,
        shiftId,
        typeId,
        order,
        bundles,
        bags,
        scrap,
        usedKg,
        hour,
      ) = row;
      final day = today.subtract(Duration(days: daysAgo));
      final size = pipeSizes.firstWhere((s) => s['sort_order'] == order);

      productionEntries.add({
        'id': nextId('pe'),
        'entry_date': Fmt.isoDate(day),
        'machine_id': machineId,
        'operator_id': operatorId,
        'shift_id': shiftId,
        'pipe_type_id': typeId,
        'pipe_size_id': size['id'],
        'bundle_quantity': bundles,
        'bag_quantity': bags,
        'wastage_quantity': scrap,
        'wastage_used': usedKg != null,
        'wastage_used_kg': usedKg,
        'remarks': null,
        'created_at': day.add(Duration(hours: hour)).toIso8601String(),
      });
    }
  }

  void _seedNotifications() {
    final now = DateTime.now();
    notifications.addAll([
      {
        'id': nextId('ntf'),
        'title': 'Low stock — Chemical',
        'message': 'Chemical has only 38 kg remaining.',
        'type': 'STOCK_LOW',
        'metadata': <String, dynamic>{},
        'created_at': now.subtract(const Duration(minutes: 25)).toIso8601String(),
        'is_read': false,
      },
      {
        'id': nextId('ntf'),
        'title': 'Dispatch completed',
        'message':
            'Type A Size 2 — dispatched 30 bundles. Remaining stock: 12 bundles.',
        'type': 'DISPATCH',
        'metadata': <String, dynamic>{},
        'created_at': now.subtract(const Duration(hours: 3)).toIso8601String(),
        'is_read': false,
      },
      {
        'id': nextId('ntf'),
        'title': 'Low stock — Type A Size 2',
        'message': 'Type A Size 2 has only 12 bundles remaining.',
        'type': 'STOCK_LOW',
        'metadata': <String, dynamic>{},
        'created_at': now.subtract(const Duration(hours: 3)).toIso8601String(),
        'is_read': true,
      },
      {
        'id': nextId('ntf'),
        'title': 'Demo data',
        'message':
            'This build runs on in-memory demo data. Nothing you enter is saved.',
        'type': 'SYSTEM',
        'metadata': <String, dynamic>{},
        'created_at': now.subtract(const Duration(hours: 8)).toIso8601String(),
        'is_read': true,
      },
    ]);
  }

  Map<String, dynamic> _material(
    String id,
    String code,
    String name,
    String category,
    double quantity,
    double minimum,
  ) {
    return {
      'raw_material_id': id,
      'id': id,
      'code': code,
      'name': name,
      'category': category,
      'category_name':
          categories.firstWhere((c) => c['code'] == category)['name'],
      'unit': 'kg',
      'minimum_stock': minimum,
      'quantity': quantity,
      'status': stockStatus(quantity, minimum),
      'active': true,
    };
  }

  Map<String, dynamic> _machine(
    String id,
    String code,
    String name,
    String description,
    String status,
  ) {
    return {
      'id': id,
      'code': code,
      'name': name,
      'description': description,
      'status': status,
      'active': true,
    };
  }

  Map<String, dynamic> _person(
    String id,
    String name,
    String employeeCode,
    String role, {
    bool hasLogin = false,
  }) {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
      'phone': null,
      'role': role,
      'active': true,
      'auth_user_id': hasLogin ? 'auth-$employeeCode' : null,
    };
  }

  void _seedDispatch() {
    final now = DateTime.now();

    void dispatch(
      String buyer,
      String reference,
      String vehicle,
      int daysAgo,
      List<(String, int, int, int)> lines,
    ) {
      final id = nextId('dsp');
      final date = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: daysAgo));

      for (final (typeId, order, bundles, bags) in lines) {
        final size = pipeSizes.firstWhere((s) => s['sort_order'] == order);
        dispatchRows.add({
          'dispatch_id': id,
          'dispatch_date': Fmt.isoDate(date),
          'customer_name': buyer,
          'reference': reference,
          'vehicle_number': vehicle,
          'remarks': null,
          'created_at': date.add(const Duration(hours: 11)).toIso8601String(),
          'line_id': nextId('dl'),
          'pipe_type_id': typeId,
          'pipe_type_name': nameOf(pipeTypes, 'id', typeId),
          'pipe_size_id': size['id'],
          'pipe_size_name': size['name'],
          'bundle_quantity': bundles,
          'bag_quantity': bags,
        });
      }
    }

    // The change request's own example: bundles and bags, one buyer, one lorry.
    dispatch('ABC Industries', 'DN-1043', 'GJXX1234', 0,
        [(typeA, 1, 20, 10)]);
    dispatch('Shree Traders', 'DN-1042', 'MH12AB4471', 1,
        [(typeA, 2, 30, 0), (typeB, 3, 20, 0)]);
    dispatch('Patel Agro Supply', 'DN-1041', 'MH14CD9920', 3,
        [(typeA, 1, 0, 8)]);
    dispatch('Krishna Irrigation', 'DN-1039', 'MH12AB4471', 6,
        [(typeB, 4, 18, 0), (typeA, 3, 12, 4)]);
  }

  void _seedWastage() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    void waste(String materialId, String source, double qty, bool reusable,
        String? machineId, String? operatorId, int daysAgo, String remarks) {
      final date = today.subtract(Duration(days: daysAgo));
      wastageRows.add({
        'id': nextId('wst'),
        'entry_date': Fmt.isoDate(date),
        'machine_id': machineId,
        'machine_name':
            machineId == null ? null : nameOf(machines, 'id', machineId),
        'operator_id': operatorId,
        'operator_name':
            operatorId == null ? null : nameOf(staff, 'id', operatorId),
        'shift_id': shiftMorning,
        'shift_name': 'Morning',
        'raw_material_id': materialId,
        'raw_material_name':
            nameOf(rawMaterials, 'raw_material_id', materialId),
        'source': source,
        'quantity': qty,
        'unit': 'kg',
        'reusable': reusable,
        'remarks': remarks,
        'created_at': date.add(const Duration(hours: 13)).toIso8601String(),
      });
    }

    waste(raizinId, 'PRODUCTION_SCRAP', 12.5, true, machine1, raviId, 0,
        'Purge and offcuts, collected for reuse');
    waste(chemicalId, 'RAW_MATERIAL_LOSS', 3.0, false, machine2,
        '66666666-6666-4666-8666-000000000003', 0, 'Spillage during charging');
    waste(raizinId, 'PRODUCTION_SCRAP', 9.0, true, machine3,
        '66666666-6666-4666-8666-000000000004', 2, 'Start-up purge');
  }

  void _seedStaff() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);

    // Today: the three running machines are manned. The operator on the
    // machine under maintenance is not in, which is why the count differs
    // from the headcount.
    // (days ago, person, status, shift, punch-in hour, punch-out hour,
    //  hours worked, overtime)
    const shape = [
      (0, raviId, 'PRESENT', shiftMorning, 6, null, 7.8, 0.0),
      (0, '66666666-6666-4666-8666-000000000003', 'PRESENT', shiftMorning, 6,
          null, 7.5, 0.0),
      (0, '66666666-6666-4666-8666-000000000004', 'PRESENT', shiftNight, 18,
          null, 1.0, 0.0),
      (0, '66666666-6666-4666-8666-000000000005', 'ABSENT', shiftNight, null,
          null, 0.0, 0.0),
      // Ravi's previous week, for the attendance card on his home screen.
      (1, raviId, 'PRESENT', shiftMorning, 6, 18, 12.0, 0.0),
      (2, raviId, 'PRESENT', shiftMorning, 6, 19, 12.5, 0.5),
      (3, raviId, 'PRESENT', shiftNight, 18, 6, 12.0, 0.0),
      (4, raviId, 'PRESENT', shiftMorning, 6, 18, 12.0, 0.0),
      (5, raviId, 'PAID_LEAVE', shiftMorning, null, null, 0.0, 0.0),
      (6, raviId, 'PRESENT', shiftMorning, 7, 18, 11.0, 0.0),
    ];

    for (final row in shape) {
      final (daysAgo, id, status, shiftId, inHour, outHour, worked, overtime) =
          row;
      final person = staff.firstWhere((p) => p['id'] == id);
      final day = today.subtract(Duration(days: daysAgo));
      // A night shift punched out at 06:00 finishes the following morning.
      final outDay = outHour != null && inHour != null && outHour <= inHour
          ? day.add(const Duration(days: 1))
          : day;

      attendanceRows.add({
        'id': nextId('att'),
        'profile_id': id,
        'staff_name': person['name'],
        'employee_code': person['employee_code'],
        'work_date': Fmt.isoDate(day),
        'status': status,
        'shift_id': shiftId,
        'shift_name': nameOf(shifts, 'id', shiftId),
        'punch_in_at': inHour == null
            ? null
            : day.add(Duration(hours: inHour)).toIso8601String(),
        'punch_out_at': outHour == null
            ? null
            : outDay.add(Duration(hours: outHour)).toIso8601String(),
        'worked_hours': worked,
        'overtime_hours': overtime,
        'payable_day': status == 'PRESENT' ? 1 : 0,
        'remarks': null,
        'created_at': day.toIso8601String(),
      });
    }

    const monthly = [
      (adminId, 22, 0, 1, 176.0, 4.0),
      (raviId, 21, 1, 1, 168.0, 12.5),
      ('66666666-6666-4666-8666-000000000003', 20, 2, 1, 160.0, 8.0),
      ('66666666-6666-4666-8666-000000000004', 22, 0, 1, 176.0, 15.0),
      ('66666666-6666-4666-8666-000000000005', 18, 4, 1, 144.0, 0.0),
    ];

    for (final row in monthly) {
      final (id, present, absent, leave, worked, overtime) = row;
      final person = staff.firstWhere((p) => p['id'] == id);

      monthlyAttendanceRows.add({
        'profile_id': id,
        'staff_name': person['name'],
        'employee_code': person['employee_code'],
        'period_month': Fmt.isoDate(monthStart),
        'present_days': present,
        'absent_days': absent,
        'paid_leave_days': leave,
        'worked_hours': worked,
        'overtime_hours': overtime,
      });

      final basic = id == adminId ? 42000.0 : 21000.0;
      final hourly = basic / 26 / 8;
      final overtimeAmount = (overtime * hourly * 1.5).roundToDouble();
      final deductions = (absent * (basic / 26)).roundToDouble();
      final advance = id == raviId ? 3000.0 : 0.0;

      payslipRows.add({
        'id': nextId('pay'),
        'profile_id': id,
        'staff_name': person['name'],
        'employee_code': person['employee_code'],
        'role': person['role'],
        'period_month': Fmt.isoDate(monthStart),
        'period_status': 'DRAFT',
        'monthly_salary': basic,
        'present_days': present,
        'absent_days': absent,
        'payable_days': (present + leave).toDouble(),
        'calendar_days': 26,
        'basic_amount': basic,
        'overtime_hours': overtime,
        'overtime_rate_per_hour': hourly * 1.5,
        'overtime_amount': overtimeAmount,
        'additions_amount': 0.0,
        'deductions_amount': deductions,
        'advance_recovered': advance,
        'gross_amount': basic + overtimeAmount,
        'net_payable': basic + overtimeAmount - deductions - advance,
        'created_at': monthStart.toIso8601String(),
      });
    }

    advanceRows.addAll([
      {
        'profile_id': raviId,
        'staff_name': 'Ravi Kumar',
        'employee_code': 'EMP-101',
        'total_issued': 8000.0,
        'total_recovered': 5000.0,
        'outstanding': 3000.0,
        'updated_at': today.toIso8601String(),
      },
      {
        'profile_id': '66666666-6666-4666-8666-000000000005',
        'staff_name': 'Ganesh Jadhav',
        'employee_code': 'EMP-104',
        'total_issued': 4000.0,
        'total_recovered': 4000.0,
        'outstanding': 0.0,
        'updated_at': today.toIso8601String(),
      },
    ]);
  }

  void _assign(String operatorId, String machineId, String shiftId) {
    final person = staff.firstWhere((p) => p['id'] == operatorId);
    final machine = machines.firstWhere((m) => m['id'] == machineId);
    final shift = shifts.firstWhere((s) => s['id'] == shiftId);

    assignments.add({
      'assignment_id': nextId('asg'),
      'operator_id': operatorId,
      'operator_name': person['name'],
      'employee_code': person['employee_code'],
      'machine_id': machineId,
      'machine_name': machine['name'],
      'machine_code': machine['code'],
      'machine_status': machine['status'],
      'shift_id': shiftId,
      'shift_name': shift['name'],
      'start_time': shift['start_time'],
      'end_time': shift['end_time'],
      'effective_from': Fmt.isoDate(DateTime.now()),
    });
  }
}
