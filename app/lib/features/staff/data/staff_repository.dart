import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';
import '../../auth/presentation/session_controller.dart';

/// Attendance and payroll (§33).
///
/// Both are read-only here. Marking attendance and running payroll are real
/// operations with real consequences, and they belong behind the same
/// deliberate confirmation flows the stock operations have — so this layer
/// surfaces what the payroll module already computes rather than offering a
/// half-built way to change it.

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

/// One person's day, from `v_attendance_days`.
class AttendanceDay {
  const AttendanceDay({
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.workDate,
    required this.status,
    required this.workedHours,
    required this.overtimeHours,
    this.punchInAt,
    this.punchOutAt,
    this.shiftName,
  });

  final String profileId;
  final String staffName;
  final String employeeCode;
  final DateTime workDate;
  final String status;
  final double workedHours;
  final double overtimeHours;
  final DateTime? punchInAt;
  final DateTime? punchOutAt;
  final String? shiftName;

  bool get isOnSite => punchInAt != null && punchOutAt == null;

  factory AttendanceDay.from(Map<String, dynamic> row) => AttendanceDay(
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        workDate: DateTime.tryParse(row['work_date'] as String? ?? '') ??
            DateTime.now(),
        status: row['status'] as String? ?? 'UNMARKED',
        workedHours: _toDouble(row['worked_hours']),
        overtimeHours: _toDouble(row['overtime_hours']),
        punchInAt: DateTime.tryParse(row['punch_in_at'] as String? ?? ''),
        punchOutAt: DateTime.tryParse(row['punch_out_at'] as String? ?? ''),
        shiftName: row['shift_name'] as String?,
      );
}

/// A month per person, from `v_monthly_attendance`.
class MonthlyAttendance {
  const MonthlyAttendance({
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.presentDays,
    required this.absentDays,
    required this.paidLeaveDays,
    required this.workedHours,
    required this.overtimeHours,
  });

  final String profileId;
  final String staffName;
  final String employeeCode;
  final int presentDays;
  final int absentDays;
  final int paidLeaveDays;
  final double workedHours;
  final double overtimeHours;

  factory MonthlyAttendance.from(Map<String, dynamic> row) => MonthlyAttendance(
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        presentDays: _toInt(row['present_days']),
        absentDays: _toInt(row['absent_days']),
        paidLeaveDays: _toInt(row['paid_leave_days']),
        workedHours: _toDouble(row['worked_hours']),
        overtimeHours: _toDouble(row['overtime_hours']),
      );
}

/// A payslip, from `v_payslips`.
class Payslip {
  const Payslip({
    required this.id,
    required this.staffName,
    required this.employeeCode,
    required this.role,
    required this.periodMonth,
    required this.periodStatus,
    required this.presentDays,
    required this.payableDays,
    required this.basicAmount,
    required this.overtimeAmount,
    required this.additionsAmount,
    required this.deductionsAmount,
    required this.advanceRecovered,
    required this.grossAmount,
    required this.netPayable,
  });

  final String id;
  final String staffName;
  final String employeeCode;
  final String role;
  final DateTime periodMonth;
  final String periodStatus;
  final int presentDays;
  final double payableDays;
  final double basicAmount;
  final double overtimeAmount;
  final double additionsAmount;
  final double deductionsAmount;
  final double advanceRecovered;
  final double grossAmount;
  final double netPayable;

  factory Payslip.from(Map<String, dynamic> row) => Payslip(
        id: row['id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        role: row['role'] as String? ?? '',
        periodMonth: DateTime.tryParse(row['period_month'] as String? ?? '') ??
            DateTime.now(),
        periodStatus: row['period_status'] as String? ?? 'DRAFT',
        presentDays: _toInt(row['present_days']),
        payableDays: _toDouble(row['payable_days']),
        basicAmount: _toDouble(row['basic_amount']),
        overtimeAmount: _toDouble(row['overtime_amount']),
        additionsAmount: _toDouble(row['additions_amount']),
        deductionsAmount: _toDouble(row['deductions_amount']),
        advanceRecovered: _toDouble(row['advance_recovered']),
        grossAmount: _toDouble(row['gross_amount']),
        netPayable: _toDouble(row['net_payable']),
      );
}

/// Outstanding advances, from `v_staff_advances`.
class StaffAdvance {
  const StaffAdvance({
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.totalIssued,
    required this.totalRecovered,
    required this.outstanding,
  });

  final String profileId;
  final String staffName;
  final String employeeCode;
  final double totalIssued;
  final double totalRecovered;
  final double outstanding;

  factory StaffAdvance.from(Map<String, dynamic> row) => StaffAdvance(
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        totalIssued: _toDouble(row['total_issued']),
        totalRecovered: _toDouble(row['total_recovered']),
        outstanding: _toDouble(row['outstanding']),
      );
}

class StaffRepository {
  const StaffRepository(this._client);

  final SupabaseClient _client;

  Future<List<AttendanceDay>> attendanceOn(DateTime date) async {
    try {
      final rows = await _client
          .from('v_attendance_days')
          .select()
          .eq('work_date', Fmt.isoDate(date))
          .order('staff_name');
      return rows.map(AttendanceDay.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// One person's recent days, newest first. Row level security limits an
  /// operator to their own rows; the explicit filter keeps an administrator's
  /// view of this screen to themselves too.
  Future<List<AttendanceDay>> recentAttendance({
    required String profileId,
    int days = 7,
  }) async {
    try {
      final today = DateTime.now();
      final since = DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: days - 1));

      final rows = await _client
          .from('v_attendance_days')
          .select()
          .eq('profile_id', profileId)
          .gte('work_date', Fmt.isoDate(since))
          .order('work_date', ascending: false);
      return rows.map(AttendanceDay.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<MonthlyAttendance>> monthlyAttendance(DateTime month) async {
    try {
      final rows = await _client
          .from('v_monthly_attendance')
          .select()
          .eq('period_month', Fmt.isoDate(DateTime(month.year, month.month, 1)))
          .order('staff_name');
      return rows.map(MonthlyAttendance.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<Payslip>> payslips() async {
    try {
      final rows = await _client
          .from('v_payslips')
          .select()
          .order('period_month', ascending: false)
          .order('staff_name')
          .limit(200);
      return rows.map(Payslip.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<StaffAdvance>> advances() async {
    try {
      final rows =
          await _client.from('v_staff_advances').select().order('staff_name');
      return rows.map(StaffAdvance.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }
}

final staffRepositoryProvider = Provider<StaffRepository>((ref) {
  return StaffRepository(ref.watch(supabaseClientProvider));
});

/// The day the Punches screen is showing.
final attendanceDateProvider = Provider<DateTime>((ref) => DateTime.now());

final attendanceProvider = FutureProvider<List<AttendanceDay>>((ref) async {
  return ref
      .watch(staffRepositoryProvider)
      .attendanceOn(ref.watch(attendanceDateProvider));
});

/// The signed-in person's last seven days, for the operator home (A33).
final myAttendanceProvider = FutureProvider<List<AttendanceDay>>((ref) async {
  final me = ref.watch(currentUserProvider);
  if (me == null) return const [];
  return ref
      .watch(staffRepositoryProvider)
      .recentAttendance(profileId: me.profileId);
});

final monthlyAttendanceProvider =
    FutureProvider<List<MonthlyAttendance>>((ref) async {
  return ref
      .watch(staffRepositoryProvider)
      .monthlyAttendance(ref.watch(attendanceDateProvider));
});

final payslipsProvider = FutureProvider<List<Payslip>>((ref) async {
  return ref.watch(staffRepositoryProvider).payslips();
});

final advancesProvider = FutureProvider<List<StaffAdvance>>((ref) async {
  return ref.watch(staffRepositoryProvider).advances();
});
