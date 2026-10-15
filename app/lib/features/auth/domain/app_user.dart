
/// Application roles (A1).
///
/// The specification calls these ADMIN / USER in one place and
/// Admin / Operator in others; `OPERATOR` is the canonical database value.
enum UserRole {
  admin('ADMIN'),
  operator('OPERATOR');

  const UserRole(this.wire);

  /// The value stored in the `user_role` enum column.
  final String wire;

  static UserRole fromWire(String? value) {
    return switch (value) {
      'ADMIN' => UserRole.admin,
      _ => UserRole.operator,
    };
  }

  bool get isAdmin => this == UserRole.admin;
}

/// The signed-in person: their Supabase identity joined to their factory profile.
///
/// Every screen decision keys off [role], which comes from the database, not
/// from anything the client could set for itself.
class AppUser {
  const AppUser({
    required this.profileId,
    required this.authUserId,
    required this.name,
    required this.employeeCode,
    required this.role,
    required this.active,
    this.employeeTypeName = 'Operator',
    this.runsMachines = true,
    this.phone,
  });

  final String profileId;
  final String authUserId;
  final String name;
  final String employeeCode;
  final UserRole role;
  final bool active;

  /// The role they hold, as opposed to [role], which is what they may see.
  final String employeeTypeName;

  /// Whether that role runs machines (A41). Somebody who does not signs in to
  /// the same app but gets no Material or Production screen, because the
  /// database would refuse a run from them anyway.
  final bool runsMachines;

  final String? phone;

  bool get isAdmin => role.isAdmin;



  factory AppUser.fromProfileRow(Map<String, dynamic> row) {
    return AppUser(
      profileId: row['id'] as String,
      authUserId: row['auth_user_id'] as String? ?? '',
      name: row['name'] as String? ?? 'Unknown',
      employeeCode: row['employee_code'] as String? ?? '',
      role: UserRole.fromWire(row['role'] as String?),
      // Embedded from employee_types, or absent on a row that predates the
      // join — in which case the safe reading is that they do run machines,
      // because that is what every profile was before roles existed.
      employeeTypeName: switch (row['employee_types']) {
        final Map<String, dynamic> t => t['name'] as String? ?? 'Operator',
        _ => row['employee_type_name'] as String? ?? 'Operator',
      },
      runsMachines: switch (row['employee_types']) {
        final Map<String, dynamic> t => t['runs_machines'] as bool? ?? true,
        _ => row['runs_machines'] as bool? ?? true,
      },
      active: row['active'] as bool? ?? false,
      phone: row['phone'] as String?,
    );
  }

  /// Initials for the avatar, e.g. "Ravi Kumar" -> "RK".
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters1();
    return '${parts.first.characters1()}${parts.last.characters1()}';
  }
}

extension on String {
  String characters1() => isEmpty ? '' : substring(0, 1).toUpperCase();
}
