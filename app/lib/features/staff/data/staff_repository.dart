import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_exception.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../core/utils/formatters.dart';
import '../../auth/presentation/session_controller.dart';

/// Attendance and payroll (§33, A38).
///
/// Payroll is one sentence: a worker is on a monthly salary, anything drawn
/// against it during the month comes off, and so does anything deducted by
/// hand. Nothing is prorated by attendance and nothing is added. Attendance is
/// still recorded — it just no longer decides what anybody is paid.

double _toDouble(Object? value) => switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? 0,
      _ => 0,
    };

double? _toDoubleOrNull(Object? value) => switch (value) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
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

/// Where a payslip stands: not yet agreed, owed, part paid, or settled.
enum PaymentStatus {
  /// The month is still a draft, so the figures can change and nothing is
  /// payable yet. Distinct from [unpaid], which is a debt.
  draft('DRAFT', 'Draft'),
  unpaid('UNPAID', 'Unpaid'),
  partial('PARTIAL', 'Part paid'),
  paid('PAID', 'Paid');

  const PaymentStatus(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => draft);

  bool get isPayable => this == unpaid || this == partial;
}

/// A payslip, from `v_payslips`.
///
/// The three figures the factory asked to see are [monthlySalary],
/// [advanceRecovered] and [netPayable] — salary, what was taken during the
/// month, what is left. [paidAmount] and [outstanding] carry it to settled.
class Payslip {
  const Payslip({
    required this.id,
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.role,
    required this.periodMonth,
    required this.periodStatus,
    required this.monthlySalary,
    required this.deductionsAmount,
    required this.advanceRecovered,
    required this.netPayable,
    required this.paidAmount,
    required this.outstanding,
    required this.status,
    this.phone,
    this.joinedOn,
    this.salaryDay,
    this.salaryDueOn,
  });

  final String id;
  final String profileId;
  final String staffName;
  final String employeeCode;
  final String role;
  final DateTime periodMonth;
  final String periodStatus;
  final double monthlySalary;
  final double deductionsAmount;
  final double advanceRecovered;
  final double netPayable;
  final double paidAmount;
  final double outstanding;
  final PaymentStatus status;
  final String? phone;
  final DateTime? joinedOn;
  final int? salaryDay;

  /// The day this month's salary falls due, from the worker's own salary day.
  /// Null when no salary day is set for them.
  final DateTime? salaryDueOn;

  bool get isDraft => periodStatus == 'DRAFT';

  factory Payslip.from(Map<String, dynamic> row) => Payslip(
        id: row['id'] as String? ?? '',
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        role: row['role'] as String? ?? '',
        periodMonth: DateTime.tryParse(row['period_month'] as String? ?? '') ??
            DateTime.now(),
        periodStatus: row['period_status'] as String? ?? 'DRAFT',
        monthlySalary: _toDouble(row['monthly_salary']),
        deductionsAmount: _toDouble(row['deductions_amount']),
        advanceRecovered: _toDouble(row['advance_recovered']),
        netPayable: _toDouble(row['net_payable']),
        paidAmount: _toDouble(row['paid_amount']),
        outstanding: _toDouble(row['outstanding']),
        status: PaymentStatus.fromWire(row['payment_status'] as String?),
        phone: row['phone'] as String?,
        joinedOn: DateTime.tryParse(row['joined_on'] as String? ?? ''),
        salaryDay: switch (row['salary_day']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        },
        salaryDueOn: DateTime.tryParse(row['salary_due_on'] as String? ?? ''),
      );
}

/// One payment handed over against a payslip, from `v_salary_payments`.
///
/// The ledger is signed and append-only: a correction is a negative row that
/// points at what it reverses, so a slip printed next year shows the mistake
/// and the undo rather than a tidied-up history.
class SalaryPayment {
  const SalaryPayment({
    required this.id,
    required this.payslipId,
    required this.profileId,
    required this.amount,
    required this.paidOn,
    required this.isReversal,
    required this.isReversed,
    this.method,
    this.remarks,
  });

  final String id;
  final String payslipId;
  final String profileId;
  final double amount;
  final DateTime paidOn;
  final bool isReversal;
  final bool isReversed;
  final String? method;
  final String? remarks;

  factory SalaryPayment.from(Map<String, dynamic> row) => SalaryPayment(
        id: row['id'] as String? ?? '',
        payslipId: row['payslip_id'] as String? ?? '',
        profileId: row['profile_id'] as String? ?? '',
        amount: _toDouble(row['amount']),
        paidOn: DateTime.tryParse(row['paid_on'] as String? ?? '') ??
            DateTime.now(),
        isReversal: row['is_reversal'] as bool? ?? false,
        isReversed: row['is_reversed'] as bool? ?? false,
        method: row['method'] as String?,
        remarks: row['remarks'] as String?,
      );
}

/// One advance taken, from `v_salary_advances`. The salary slip prints these
/// with their dates, which is what the worker recognises.
class AdvanceTaken {
  const AdvanceTaken({
    required this.id,
    required this.profileId,
    required this.entryDate,
    required this.amount,
    this.remarks,
  });

  final String id;
  final String profileId;
  final DateTime entryDate;
  final double amount;
  final String? remarks;

  factory AdvanceTaken.from(Map<String, dynamic> row) => AdvanceTaken(
        id: row['id'] as String? ?? '',
        profileId: row['profile_id'] as String? ?? '',
        entryDate: DateTime.tryParse(row['entry_date'] as String? ?? '') ??
            DateTime.now(),
        amount: _toDouble(row['amount']),
        remarks: row['remarks'] as String?,
      );
}

/// A month of payroll, from `v_payroll_summary`. Administrators only.
class PayrollPeriod {
  const PayrollPeriod({
    required this.id,
    required this.periodMonth,
    required this.status,
    required this.payslipCount,
    required this.salaryTotal,
    required this.deductionsTotal,
    required this.advanceRecoveredTotal,
    required this.netTotal,
    required this.paidTotal,
    required this.outstandingTotal,
    required this.paidCount,
    required this.partialCount,
    required this.unpaidCount,
    this.finalisedAt,
  });

  final String id;
  final DateTime periodMonth;
  final String status;
  final int payslipCount;
  final double salaryTotal;
  final double deductionsTotal;
  final double advanceRecoveredTotal;
  final double netTotal;
  final double paidTotal;
  final double outstandingTotal;
  final int paidCount;
  final int partialCount;
  final int unpaidCount;
  final DateTime? finalisedAt;

  bool get isDraft => status == 'DRAFT';

  /// Everybody has been paid in full. Not the same as `paidTotal == netTotal`
  /// on an empty month, which would be trivially true of nothing.
  bool get isSettled => payslipCount > 0 && paidCount == payslipCount;

  factory PayrollPeriod.from(Map<String, dynamic> row) => PayrollPeriod(
        id: row['payroll_period_id'] as String? ?? '',
        periodMonth: DateTime.tryParse(row['period_month'] as String? ?? '') ??
            DateTime.now(),
        status: row['status'] as String? ?? 'DRAFT',
        payslipCount: _toInt(row['payslip_count']),
        salaryTotal: _toDouble(row['salary_total']),
        deductionsTotal: _toDouble(row['deductions_total']),
        advanceRecoveredTotal: _toDouble(row['advance_recovered_total']),
        netTotal: _toDouble(row['net_total']),
        paidTotal: _toDouble(row['paid_total']),
        outstandingTotal: _toDouble(row['outstanding_total']),
        paidCount: _toInt(row['paid_count']),
        partialCount: _toInt(row['partial_count']),
        unpaidCount: _toInt(row['unpaid_count']),
        finalisedAt: DateTime.tryParse(row['finalised_at'] as String? ?? ''),
      );
}

/// What one person is on and what they have drawn, from `v_staff_pay`.
///
/// [monthlySalary] is the salary in force today, so a raise dated next month
/// does not read as this month's pay; when one is on file it arrives separately
/// as [upcomingSalary].
class StaffPay {
  const StaffPay({
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.role,
    required this.outstandingAdvance,
    this.monthlySalary,
    this.effectiveFrom,
    this.upcomingSalary,
    this.upcomingFrom,
    this.salaryDay,
    this.joinedOn,
    this.nextDueOn,
  });

  final String profileId;
  final String staffName;
  final String employeeCode;
  final String role;
  final double outstandingAdvance;
  final double? monthlySalary;
  final DateTime? effectiveFrom;
  final double? upcomingSalary;
  final DateTime? upcomingFrom;

  /// Nobody has set a salary yet, so this person cannot be paid.
  bool get hasSalary => monthlySalary != null;

  /// Day of the month they are paid on, 1–31. Null means no fixed day.
  final int? salaryDay;

  /// The day they joined the factory, where it is recorded.
  final DateTime? joinedOn;

  /// When this month's salary next falls due, from their own salary day.
  final DateTime? nextDueOn;

  factory StaffPay.from(Map<String, dynamic> row) => StaffPay(
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        role: row['role'] as String? ?? '',
        outstandingAdvance: _toDouble(row['outstanding_advance']),
        monthlySalary: _toDoubleOrNull(row['monthly_salary']),
        effectiveFrom:
            DateTime.tryParse(row['effective_from'] as String? ?? ''),
        upcomingSalary: _toDoubleOrNull(row['upcoming_salary']),
        upcomingFrom: DateTime.tryParse(row['upcoming_from'] as String? ?? ''),
        salaryDay: switch (row['salary_day']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        },
        joinedOn: DateTime.tryParse(row['joined_on'] as String? ?? ''),
        nextDueOn: DateTime.tryParse(row['next_due_on'] as String? ?? ''),
      );
}

/// A deduction waiting to land on a payslip, from `v_staff_deductions`.
class StaffDeduction {
  const StaffDeduction({
    required this.id,
    required this.profileId,
    required this.staffName,
    required this.employeeCode,
    required this.periodMonth,
    required this.label,
    required this.amount,
    this.remarks,
  });

  final String id;
  final String profileId;
  final String staffName;
  final String employeeCode;
  final DateTime periodMonth;
  final String label;
  final double amount;
  final String? remarks;

  factory StaffDeduction.from(Map<String, dynamic> row) => StaffDeduction(
        id: row['id'] as String? ?? '',
        profileId: row['profile_id'] as String? ?? '',
        staffName: row['staff_name'] as String? ?? '—',
        employeeCode: row['employee_code'] as String? ?? '',
        periodMonth: DateTime.tryParse(row['period_month'] as String? ?? '') ??
            DateTime.now(),
        label: row['label'] as String? ?? '',
        amount: _toDouble(row['amount']),
        remarks: row['remarks'] as String?,
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

  // ---------------------------------------------------------------------------
  // Attendance
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Everyone who can be paid. Inactive staff are in `v_staff_pay` so an
  /// administrator can find somebody they took off the roll, but they do not
  /// belong on a screen about paying people.
  Future<List<StaffPay>> staffPay() async {
    try {
      final rows = await _client
          .from('v_staff_pay')
          .select()
          .eq('active', true)
          .order('employee_code');
      return rows.map(StaffPay.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Every payment against one payslip, oldest first, reversals included.
  Future<List<SalaryPayment>> paymentsFor(String payslipId) async {
    try {
      final rows = await _client
          .from('v_salary_payments')
          .select()
          .eq('payslip_id', payslipId)
          .order('created_at');
      return rows.map(SalaryPayment.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// The advances one person took during one month, for their salary slip.
  Future<List<AdvanceTaken>> advancesTaken({
    required String profileId,
    required DateTime month,
  }) async {
    try {
      final rows = await _client
          .from('v_salary_advances')
          .select()
          .eq('profile_id', profileId)
          .eq('period_month', Fmt.isoDate(DateTime(month.year, month.month, 1)))
          .order('entry_date');
      return rows.map(AdvanceTaken.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<PayrollPeriod>> payrollPeriods({int limit = 24}) async {
    try {
      final rows = await _client
          .from('v_payroll_summary')
          .select()
          .order('period_month', ascending: false)
          .limit(limit);
      return rows.map(PayrollPeriod.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<Payslip>> payslips({DateTime? month}) async {
    try {
      var query = _client.from('v_payslips').select();
      if (month != null) {
        query = query.eq(
          'period_month',
          Fmt.isoDate(DateTime(month.year, month.month, 1)),
        );
      }
      final rows = await query
          .order('period_month', ascending: false)
          .order('staff_name')
          .limit(200);
      return rows.map(Payslip.from).toList(growable: false);
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<List<StaffDeduction>> deductions(DateTime month) async {
    try {
      final rows = await _client
          .from('v_staff_deductions')
          .select()
          .eq('period_month', Fmt.isoDate(DateTime(month.year, month.month, 1)))
          .order('created_at', ascending: false);
      return rows.map(StaffDeduction.from).toList(growable: false);
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

  // ---------------------------------------------------------------------------
  // Writes — every one of them an admin-only RPC
  // ---------------------------------------------------------------------------

  /// Puts somebody on a monthly salary from [effectiveFrom].
  ///
  /// A raise never edits the old figure; the database closes the previous
  /// period and opens a new one, so a payslip already issued keeps the rate it
  /// was paid at.
  Future<Map<String, dynamic>> setSalary({
    required String profileId,
    required double monthlySalary,
    DateTime? effectiveFrom,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'set_salary_structure',
        params: {
          'p_profile_id': profileId,
          'p_monthly_salary': monthlySalary,
          'p_effective_from': Fmt.isoDate(effectiveFrom ?? DateTime.now()),
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Hands somebody part of their salary before salary day. It comes back off
  /// the next payslip.
  Future<Map<String, dynamic>> issueAdvance({
    required String profileId,
    required double amount,
    required String clientRef,
    DateTime? entryDate,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'issue_salary_advance',
        params: {
          'p_profile_id': profileId,
          'p_amount': amount,
          'p_client_ref': clientRef,
          'p_entry_date': Fmt.isoDate(entryDate ?? DateTime.now()),
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Takes something off one person's pay for one month — the only manual
  /// lever left in the calculation.
  Future<Map<String, dynamic>> addDeduction({
    required String profileId,
    required DateTime periodMonth,
    required String label,
    required double amount,
    required String clientRef,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'add_staff_adjustment',
        params: {
          'p_profile_id': profileId,
          'p_period_month':
              Fmt.isoDate(DateTime(periodMonth.year, periodMonth.month, 1)),
          'p_component_type': 'DEDUCTION',
          'p_label': label,
          'p_amount': amount,
          'p_client_ref': clientRef,
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  Future<Map<String, dynamic>> removeDeduction(String id) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'remove_staff_adjustment',
        params: {'p_id': id},
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Works out the month. Safe to run as often as you like: a draft is rebuilt
  /// from scratch and no money moves until it is finalised.
  Future<Map<String, dynamic>> runPayroll(DateTime month,
      {String? remarks}) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'run_payroll',
        params: {
          'p_period_month': Fmt.isoDate(DateTime(month.year, month.month, 1)),
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Hands over money against an agreed payslip.
  ///
  /// Only works once the month is finalised: a draft's figures still move, and
  /// paying against a number that can change is how a system ends up paying one
  /// amount and reporting another. Partial payments are expected — pay what was
  /// handed over, as many times as it takes.
  Future<Map<String, dynamic>> recordPayment({
    required String payslipId,
    required double amount,
    required String clientRef,
    DateTime? paidOn,
    String? method,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'record_salary_payment',
        params: {
          'p_payslip_id': payslipId,
          'p_amount': amount,
          'p_client_ref': clientRef,
          'p_paid_on': Fmt.isoDate(paidOn ?? DateTime.now()),
          'p_method': method,
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Takes a payment back without erasing it: the reversal is its own row, so
  /// the slip still shows what was paid in error and what undid it.
  Future<Map<String, dynamic>> reversePayment({
    required String paymentId,
    required String clientRef,
    String? remarks,
  }) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'reverse_salary_payment',
        params: {
          'p_payment_id': paymentId,
          'p_client_ref': clientRef,
          'p_remarks': remarks,
        },
      );
    } catch (error, stack) {
      throw ErrorMapper.map(error, stack);
    }
  }

  /// Closes the month. This is the point at which the advances shown on the
  /// payslips actually come off the advance ledger, so it happens once.
  Future<Map<String, dynamic>> finalisePayroll(DateTime month) async {
    try {
      return await _client.rpc<Map<String, dynamic>>(
        'finalise_payroll',
        params: {
          'p_period_month': Fmt.isoDate(DateTime(month.year, month.month, 1)),
        },
      );
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

/// The month the Salary screen is showing. Always the first of a month, so
/// every query built from it lines up with `period_month`.
class PayrollMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  void show(DateTime month) => state = DateTime(month.year, month.month, 1);
}

final payrollMonthProvider =
    NotifierProvider<PayrollMonth, DateTime>(PayrollMonth.new);

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

final staffPayProvider = FutureProvider<List<StaffPay>>((ref) async {
  return ref.watch(staffRepositoryProvider).staffPay();
});

final payrollPeriodsProvider = FutureProvider<List<PayrollPeriod>>((ref) async {
  return ref.watch(staffRepositoryProvider).payrollPeriods();
});

/// The payslips of the month on screen.
final payslipsProvider = FutureProvider<List<Payslip>>((ref) async {
  return ref
      .watch(staffRepositoryProvider)
      .payslips(month: ref.watch(payrollMonthProvider));
});

final deductionsProvider = FutureProvider<List<StaffDeduction>>((ref) async {
  return ref
      .watch(staffRepositoryProvider)
      .deductions(ref.watch(payrollMonthProvider));
});

final advancesProvider = FutureProvider<List<StaffAdvance>>((ref) async {
  return ref.watch(staffRepositoryProvider).advances();
});

/// The payments against one payslip. Keyed by payslip id, so opening two
/// workers' histories does not make them share one list.
final paymentsProvider =
    FutureProvider.family<List<SalaryPayment>, String>((ref, payslipId) async {
  return ref.watch(staffRepositoryProvider).paymentsFor(payslipId);
});

/// Everything the Salary screen shows, after anything on it changes.
void invalidatePayroll(WidgetRef ref) {
  ref
    ..invalidate(staffPayProvider)
    ..invalidate(payrollPeriodsProvider)
    ..invalidate(payslipsProvider)
    ..invalidate(deductionsProvider)
    ..invalidate(advancesProvider)
    // The whole family: a payment changes one payslip's history, and which one
    // is not worth threading through every caller.
    ..invalidate(paymentsProvider);
}
