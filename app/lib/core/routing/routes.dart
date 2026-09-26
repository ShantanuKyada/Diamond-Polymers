/// Every named route in the application.
///
/// Admin routes live under `/admin`, operator routes under `/op`. That prefix is
/// what the router's guard keys off, so a new screen is protected by where it is
/// placed rather than by remembering to add a check (§5).
///
/// The go_router name is the enum constant's own `.name`, so the two can never
/// drift apart.
enum AppRoute {
  splash('/splash'),
  login('/login'),

  // ---- Admin (§34) --------------------------------------------------------
  adminDashboard('/admin/dashboard'),
  adminInventory('/admin/inventory'),
  adminProduction('/admin/production'),
  adminDispatch('/admin/dispatch'),
  adminMore('/admin/more'),
  adminWastage('/admin/wastage'),
  adminMachines('/admin/machines'),
  adminOperators('/admin/operators'),
  adminReports('/admin/reports'),
  adminStaffPunches('/admin/staff/punches'),
  adminStaffSalary('/admin/staff/salary'),
  adminSettings('/admin/settings'),

  /// Material Entry. Admin-only since A30 — the `/admin` prefix is what puts
  /// it behind the router's guard.
  mixtureEntry('/admin/material'),
  // A34: the operator records the machine they are assigned to. Separate route
  // rather than a shared one, because the guard works on the path prefix — an
  // admin route an operator may use would be a hole in that rule, not an
  // exception to it.
  operatorMaterialEntry('/op/material'),

  // Master-data catalogues reached from Settings. They live under `/admin` for
  // the same reason everything else does: the guard keys off the prefix, so a
  // screen is protected by where it sits rather than by anyone remembering.
  adminProducts('/admin/settings/products'),
  adminPipeTypes('/admin/settings/pipe-types'),
  adminPipeSizes('/admin/settings/pipe-sizes'),
  adminRawMaterials('/admin/settings/materials'),
  adminShifts('/admin/settings/shifts'),

  // ---- Operator (§35) -----------------------------------------------------
  operatorHome('/op/home'),
  productionEntry('/op/production'),
  myEntries('/op/entries'),

  // ---- Shared -------------------------------------------------------------
  profile('/profile'),
  notifications('/notifications');

  const AppRoute(this.path);

  final String path;
}
