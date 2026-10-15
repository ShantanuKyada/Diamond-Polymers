/// Master data: the things an administrator configures once and the rest of the
/// factory then records against (§32, Phase 2).
///
/// These are plain value types with a `.from(row)` factory, matching
/// `AppNotification` and `AppUser`. Every parse is defensive about nulls: a
/// master row that lost a column to a migration should render as "unknown"
/// rather than crash a screen an administrator needs in order to fix it.
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Whether a line is running, idle or under maintenance (§9).
enum MachineStatus {
  active('ACTIVE', 'Active'),
  maintenance('MAINTENANCE', 'Maintenance'),
  inactive('INACTIVE', 'Inactive');

  const MachineStatus(this.wire, this.label);

  final String wire;
  final String label;

  static MachineStatus fromWire(String? value) {
    return MachineStatus.values.firstWhere(
      (s) => s.wire == value,
      orElse: () => MachineStatus.inactive,
    );
  }

  Color get color => switch (this) {
        MachineStatus.active => AppTheme.good,
        MachineStatus.maintenance => AppTheme.low,
        MachineStatus.inactive => AppTheme.neutral,
      };
}

class Machine {
  const Machine({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.active,
    this.description,
  });

  final String id;
  final String code;
  final String name;
  final MachineStatus status;
  final bool active;
  final String? description;

  factory Machine.from(Map<String, dynamic> row) => Machine(
        id: row['id'] as String,
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? 'Unnamed machine',
        status: MachineStatus.fromWire(row['status'] as String?),
        active: row['active'] as bool? ?? true,
        description: row['description'] as String?,
      );
}

class Shift {
  const Shift({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.active,
  });

  final String id;
  final String name;

  /// Postgres `time` arrives as "06:00:00".
  final String startTime;
  final String endTime;
  final bool active;

  /// "06:00 – 14:00". A night shift reads 22:00 – 06:00 and is understood to
  /// cross midnight (A16); no arithmetic is done here.
  String get range =>
      '${startTime.padRight(5).substring(0, 5)} – ${endTime.padRight(5).substring(0, 5)}';

  factory Shift.from(Map<String, dynamic> row) => Shift(
        id: row['id'] as String,
        name: row['name'] as String? ?? '',
        startTime: row['start_time'] as String? ?? '00:00:00',
        endTime: row['end_time'] as String? ?? '00:00:00',
        active: row['active'] as bool? ?? true,
      );
}

class PipeType {
  const PipeType({
    required this.id,
    required this.code,
    required this.name,
    required this.active,
    this.description,
    this.recycledMaterialId,
  });

  final String id;
  final String code;
  final String name;
  final bool active;
  final String? description;

  /// Which regrind pool shredded pipe of this type returns to (A20). Null means
  /// `shred_pipe()` has to be told explicitly, or will refuse.
  final String? recycledMaterialId;

  factory PipeType.from(Map<String, dynamic> row) => PipeType(
        id: row['id'] as String,
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? '',
        active: row['active'] as bool? ?? true,
        description: row['description'] as String?,
        recycledMaterialId: row['recycled_material_id'] as String?,
      );
}

class PipeSize {
  const PipeSize({
    required this.id,
    required this.code,
    required this.name,
    required this.sortOrder,
    required this.active,
    this.description,
    this.diameterMm,
    this.lengthM,
  });

  final String id;
  final String code;
  final String name;
  final int sortOrder;
  final bool active;
  final String? description;
  final double? diameterMm;
  final double? lengthM;

  factory PipeSize.from(Map<String, dynamic> row) => PipeSize(
        id: row['id'] as String,
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? '',
        sortOrder: _int(row['sort_order']),
        active: row['active'] as bool? ?? true,
        description: row['description'] as String?,
        diameterMm: _doubleOrNull(row['diameter_mm']),
        lengthM: _doubleOrNull(row['length_m']),
      );
}

/// A (pipe type × pipe size) pair with the weight that makes it countable in
/// kilograms as well as bundles (A21). Read from `v_pipe_products`, which joins
/// live stock onto the specification.
class PipeProduct {
  const PipeProduct({
    required this.id,
    required this.sku,
    required this.pipeTypeId,
    required this.pipeTypeName,
    required this.pipeSizeId,
    required this.pipeSizeName,
    required this.bundleWeightKg,
    required this.active,
    required this.quantityBundles,
    required this.stockWeightKg,
    required this.minimumStock,
    required this.status,
    this.diameterMm,
    this.pipesPerBundle,
    this.pipesPerBag,
    this.quantityBags = 0,
    this.bagWeightKg,
  });

  final String id;
  final String sku;
  final String pipeTypeId;
  final String pipeTypeName;
  final String pipeSizeId;
  final String pipeSizeName;
  final double bundleWeightKg;
  final bool active;
  final int quantityBundles;
  final double stockWeightKg;
  final int minimumStock;
  final String status;
  final double? diameterMm;
  final int? pipesPerBundle;

  /// How many pipes make one bag. Null means this product is not sold in bags.
  final int? pipesPerBag;

  final int quantityBags;

  /// Derived by the database from the bundle weight and the two pipe counts.
  final double? bagWeightKg;

  String get label => '$pipeTypeName — $pipeSizeName';

  /// Bags can be produced and dispatched only once the database can weigh one,
  /// which needs both pipe counts (A26).
  bool get hasBagPacking => pipesPerBag != null && pipesPerBundle != null;

  /// The individual pipes a quantity represents, when the mapping allows it.
  int? pipesFor({int bundles = 0, int bags = 0}) {
    if (bundles > 0 && pipesPerBundle == null) return null;
    if (bags > 0 && pipesPerBag == null) return null;
    return bundles * (pipesPerBundle ?? 0) + bags * (pipesPerBag ?? 0);
  }

  factory PipeProduct.from(Map<String, dynamic> row) => PipeProduct(
        id: row['pipe_product_id'] as String,
        sku: row['sku'] as String? ?? '',
        pipeTypeId: row['pipe_type_id'] as String,
        pipeTypeName: row['pipe_type_name'] as String? ?? '',
        pipeSizeId: row['pipe_size_id'] as String,
        pipeSizeName: row['pipe_size_name'] as String? ?? '',
        bundleWeightKg: _double(row['bundle_weight_kg']),
        active: row['active'] as bool? ?? true,
        quantityBundles: _int(row['quantity_bundles']),
        stockWeightKg: _double(row['stock_weight_kg']),
        minimumStock: _int(row['minimum_stock']),
        status: row['status'] as String? ?? 'GOOD',
        diameterMm: _doubleOrNull(row['diameter_mm']),
        pipesPerBundle: row['pipes_per_bundle'] == null
            ? null
            : _int(row['pipes_per_bundle']),
        pipesPerBag:
            row['pipes_per_bag'] == null ? null : _int(row['pipes_per_bag']),
        quantityBags: _int(row['quantity_bags']),
        bagWeightKg: _doubleOrNull(row['bag_weight_kg']),
      );
}

/// Read from `v_raw_material_stock`, so the reorder threshold sits next to the
/// quantity it is judged against.
class RawMaterial {
  const RawMaterial({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    required this.categoryName,
    required this.unit,
    required this.minimumStock,
    required this.quantity,
    required this.status,
    required this.active,
  });

  final String id;
  final String code;
  final String name;
  final String category;
  final String categoryName;
  final String unit;
  final double minimumStock;
  final double quantity;
  final String status;
  final bool active;

  bool get isRecycled => category == 'RECYCLED';

  factory RawMaterial.from(Map<String, dynamic> row) => RawMaterial(
        id: row['raw_material_id'] as String,
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? '',
        category: row['category'] as String? ?? '',
        categoryName: row['category_name'] as String? ?? '',
        unit: row['unit'] as String? ?? 'kg',
        minimumStock: _double(row['minimum_stock']),
        quantity: _double(row['quantity']),
        status: row['status'] as String? ?? 'GOOD',
        active: row['active'] as bool? ?? true,
      );
}

/// A person on the factory roll. An operator *is* a profile row (A2), and it may
/// exist with no login at all (A3) — [hasLogin] is what the UI keys off.
/// What somebody does for a living (A40).
///
/// Separate from [StaffMember.role], which is what they may *see* in the app.
/// Conflating the two would mean a labourer could only be put on the payroll by
/// making them an app operator, and the factory's administrator would be filed
/// as a machine operator.
/// A role somebody can hold, from `employee_types` (A41).
///
/// This was an enum of three values until the factory asked to add their own —
/// a supervisor, a helper, a fitter — which an enum cannot do without a
/// migration every time. It is master data now, like machines and pipe types.
///
/// [runsMachines] is the only thing the rest of the system asks about a role.
/// It decides whether somebody gets the Material and Production screens,
/// whether they may be assigned to a machine, and whether the database accepts
/// a run from them. The factory answers it when they create the role, rather
/// than the app matching on the name.
class EmployeeType {
  const EmployeeType({
    required this.id,
    required this.code,
    required this.name,
    required this.runsMachines,
    required this.active,
    required this.isSystem,
    this.description,
    this.sortOrder = 100,
    this.activeStaff = 0,
    this.totalStaff = 0,
  });

  final String id;

  /// Stable and never edited. The database and these screens refer to the code;
  /// [name] is what the factory reads and may change freely.
  final String code;

  final String name;
  final String? description;
  final bool runsMachines;
  final bool active;

  /// Operator. It cannot be switched off and cannot stop running machines —
  /// a factory with no machine-running role is one where nobody can record
  /// production at all.
  final bool isSystem;

  final int sortOrder;

  /// How many people hold it, which is what decides whether it can be retired.
  final int activeStaff;
  final int totalStaff;

  bool get canBeRetired => !isSystem && activeStaff == 0;

  /// The code the database falls back on, and the one this app assumes when it
  /// has no better answer.
  static const operatorCode = 'OPERATOR';

  factory EmployeeType.from(Map<String, dynamic> row) => EmployeeType(
        id: row['id'] as String? ?? '',
        code: row['code'] as String? ?? operatorCode,
        name: row['name'] as String? ?? 'Operator',
        description: row['description'] as String?,
        runsMachines: row['runs_machines'] as bool? ?? false,
        active: row['active'] as bool? ?? true,
        isSystem: row['is_system'] as bool? ?? false,
        sortOrder: switch (row['sort_order']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s) ?? 100,
          _ => 100,
        },
        activeStaff: switch (row['active_staff']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s) ?? 0,
          _ => 0,
        },
        totalStaff: switch (row['total_staff']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s) ?? 0,
          _ => 0,
        },
      );
}

class StaffMember {
  const StaffMember({
    required this.id,
    required this.name,
    required this.employeeCode,
    required this.role,
    required this.active,
    required this.hasLogin,
    this.employeeTypeCode = EmployeeType.operatorCode,
    this.employeeTypeName = 'Operator',
    this.runsMachines = true,
    this.phone,
    this.joinedOn,
    this.salaryDay,
    this.monthlySalary,
  });

  final String id;
  final String name;
  final String employeeCode;
  final String role;
  final bool active;
  final bool hasLogin;

  /// The role they hold, as opposed to [role], which is what they may see.
  /// Carried as a code and a name rather than a reference: the roster shows
  /// the name and the form saves the code (A41).
  final String employeeTypeCode;
  final String employeeTypeName;

  /// Whether that role runs machines — the one question everything else asks.
  final bool runsMachines;

  final String? phone;

  /// The day they joined the factory. Null for staff who were already on the
  /// roll before the field existed — an invented date would be a false record.
  final DateTime? joinedOn;

  /// Day of the month they are paid on, 1–31. Null means no fixed day.
  final int? salaryDay;

  /// The salary in force today, read from `salary_structures`. Null when nobody
  /// has set one, which is the state that keeps somebody off the payroll.
  final double? monthlySalary;

  bool get isAdmin => role == 'ADMIN';
  bool get hasSalary => monthlySalary != null;



  factory StaffMember.from(Map<String, dynamic> row) => StaffMember(
        id: row['id'] as String,
        name: row['name'] as String? ?? '',
        employeeCode: row['employee_code'] as String? ?? '',
        role: row['role'] as String? ?? 'OPERATOR',
        employeeTypeCode:
            row['employee_type'] as String? ?? EmployeeType.operatorCode,
        employeeTypeName: row['employee_type_name'] as String? ?? 'Operator',
        runsMachines: row['runs_machines'] as bool? ?? true,
        active: row['active'] as bool? ?? true,
        // `v_staff_pay` reports this as a boolean and does not hand out the
        // auth id. A row read straight from `profiles` still carries the id, so
        // both shapes are accepted — and a `false` must not read as "present",
        // which a bare null check would get wrong.
        hasLogin: switch (row['has_login']) {
          final bool b => b,
          _ => row['auth_user_id'] != null,
        },
        phone: row['phone'] as String?,
        joinedOn: DateTime.tryParse(row['joined_on'] as String? ?? ''),
        salaryDay: switch (row['salary_day']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        },
        monthlySalary: switch (row['monthly_salary']) {
          final num n => n.toDouble(),
          final String s => double.tryParse(s),
          _ => null,
        },
      );

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }
}

/// An open assignment from `v_current_machine_assignments`. Assignments are
/// effective-dated in the database, so ending one preserves the history rather
/// than deleting it (§10).
class MachineAssignment {
  const MachineAssignment({
    required this.assignmentId,
    required this.operatorId,
    required this.operatorName,
    required this.employeeCode,
    required this.machineId,
    required this.machineName,
    required this.machineCode,
    required this.effectiveFrom,
    this.shiftId,
    this.shiftName,
  });

  final String assignmentId;
  final String operatorId;
  final String operatorName;
  final String employeeCode;
  final String machineId;
  final String machineName;
  final String machineCode;
  final DateTime effectiveFrom;
  final String? shiftId;
  final String? shiftName;

  factory MachineAssignment.from(Map<String, dynamic> row) => MachineAssignment(
        assignmentId: row['assignment_id'] as String,
        operatorId: row['operator_id'] as String,
        operatorName: row['operator_name'] as String? ?? '',
        employeeCode: row['employee_code'] as String? ?? '',
        machineId: row['machine_id'] as String,
        machineName: row['machine_name'] as String? ?? '',
        machineCode: row['machine_code'] as String? ?? '',
        effectiveFrom:
            DateTime.tryParse(row['effective_from'] as String? ?? '') ??
                DateTime.now(),
        shiftId: row['shift_id'] as String?,
        shiftName: row['shift_name'] as String?,
      );
}

/// One row of `app_settings`. The value is always text in the database; the
/// meaning of each key is documented there, not here.
class AppSetting {
  const AppSetting({
    required this.key,
    required this.value,
    this.description,
  });

  final String key;
  final String value;
  final String? description;

  factory AppSetting.from(Map<String, dynamic> row) => AppSetting(
        key: row['key'] as String,
        value: row['value'] as String? ?? '',
        description: row['description'] as String?,
      );
}

// Postgres `numeric` arrives over PostgREST as a String, not a num, so every
// quantity has to survive both. Getting this wrong shows up as a silent zero.
double _double(Object? value) => _doubleOrNull(value) ?? 0;

double? _doubleOrNull(Object? value) => switch (value) {
      null => null,
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };

int _int(Object? value) => switch (value) {
      null => 0,
      final num n => n.toInt(),
      final String s => int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? 0,
      _ => 0,
    };

/// A machine an operator may work on, from `v_operator_machines` (A40).
///
/// Every running machine is offered. [isMine] marks the one they are assigned
/// to, which the entry forms select by default — the assignment is now a good
/// guess about where somebody is standing, not a rule about where they may
/// stand.
class OperatorMachine {
  const OperatorMachine({
    required this.machineId,
    required this.code,
    required this.name,
    required this.status,
    required this.isMine,
    this.myShiftId,
    this.myShiftName,
  });

  final String machineId;
  final String code;
  final String name;
  final String status;
  final bool isMine;

  /// The shift on their assignment, where there is one. Used to default the
  /// shift on an entry form for the machine they usually run.
  final String? myShiftId;
  final String? myShiftName;

  String get label => '$code · $name';

  /// The same machine in the shape the entry forms already speak.
  ///
  /// `v_operator_machines` answers a different question from the machine master
  /// — "which may this person use" rather than "which exist" — but the forms
  /// only need the identity, so they take a [Machine] and stay one code path
  /// for an operator and an administrator.
  Machine get asMachine => Machine(
        id: machineId,
        code: code,
        name: name,
        status: MachineStatus.fromWire(status),
        active: true,
      );

  factory OperatorMachine.from(Map<String, dynamic> row) => OperatorMachine(
        machineId: row['machine_id'] as String? ?? '',
        code: row['code'] as String? ?? '',
        name: row['name'] as String? ?? '',
        status: row['status'] as String? ?? 'ACTIVE',
        isMine: row['is_mine'] as bool? ?? false,
        myShiftId: row['my_shift_id'] as String?,
        myShiftName: row['my_shift_name'] as String?,
      );
}
