-- =============================================================================
-- 0014_payroll_views_rls.sql — read models and row level security for Phase 8
--
-- PRIVACY IS THE POINT OF THIS FILE.
--
-- Stock data is factory-wide: an operator seeing how much Raizin is in the shed
-- costs nothing. Pay is not like that. What one worker earns, what they owe in
-- advances, and what has been deducted from them are none of their colleagues'
-- business, and a mistake here is not a bug people shrug at.
--
-- So every table below is "yours or nobody's": an operator sees their own row
-- and no one else's, an administrator sees all. There is no policy anywhere that
-- lets one worker read another's pay.
--
-- As everywhere else, no table grants INSERT, UPDATE or DELETE to a client.
-- Attendance, advances and payslips move only through the RPCs in 0013.
-- =============================================================================

alter table public.salary_structures     enable row level security;
alter table public.attendance_days       enable row level security;
alter table public.staff_advance_balance enable row level security;
alter table public.advance_transactions  enable row level security;
alter table public.staff_adjustments     enable row level security;
alter table public.payroll_periods       enable row level security;
alter table public.payslips              enable row level security;
alter table public.payslip_components    enable row level security;

-- -----------------------------------------------------------------------------
-- Salary structures: yours, or everyone's if you are an administrator.
-- Writes go through set_salary_structure(), which keeps the effective-dated
-- history consistent; there is deliberately no direct write policy.
-- -----------------------------------------------------------------------------

drop policy if exists salary_structures_read on public.salary_structures;
create policy salary_structures_read on public.salary_structures
  for select to authenticated
  using (app.is_admin() or profile_id = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Attendance: a worker sees their own card, an administrator sees the floor.
-- -----------------------------------------------------------------------------

drop policy if exists attendance_read on public.attendance_days;
create policy attendance_read on public.attendance_days
  for select to authenticated
  using (app.is_admin() or profile_id = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Advances: a worker must be able to see what they still owe.
-- -----------------------------------------------------------------------------

drop policy if exists advance_balance_read on public.staff_advance_balance;
create policy advance_balance_read on public.staff_advance_balance
  for select to authenticated
  using (app.is_admin() or profile_id = app.current_profile_id());

drop policy if exists advance_txn_read on public.advance_transactions;
create policy advance_txn_read on public.advance_transactions
  for select to authenticated
  using (app.is_admin() or profile_id = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Adjustments are administrator-only.
--
-- A fine or a bonus is visible to the worker as a line on their payslip, once
-- the payslip exists. It is not visible while it is still being decided.
-- -----------------------------------------------------------------------------

drop policy if exists staff_adjustments_admin_read on public.staff_adjustments;
create policy staff_adjustments_admin_read on public.staff_adjustments
  for select to authenticated using (app.is_admin());

-- A worker may read a period they have a payslip in, and no other.
--
-- Not cosmetic: every payslip view joins the period for its month and status,
-- and `security_invoker` means an admin-only policy here silently empties that
-- join for everybody else. The worker keeps their own payslip out of sight of
-- themselves, which is the opposite of what this file is for.
drop policy if exists payroll_periods_admin_read on public.payroll_periods;
drop policy if exists payroll_periods_read on public.payroll_periods;
create policy payroll_periods_read on public.payroll_periods
  for select to authenticated
  using (
    app.is_admin()
    or exists (
      select 1 from public.payslips s
      where s.payroll_period_id = payroll_periods.id
        and s.profile_id = app.current_profile_id()
    )
  );

-- -----------------------------------------------------------------------------
-- Payslips: yours, or all of them if you are an administrator. Append-only —
-- nobody gets UPDATE or DELETE. A draft is rebuilt by run_payroll(), which runs
-- as the owner and is the only thing that may replace one.
-- -----------------------------------------------------------------------------

drop policy if exists payslips_read on public.payslips;
create policy payslips_read on public.payslips
  for select to authenticated
  using (app.is_admin() or profile_id = app.current_profile_id());

drop policy if exists payslip_components_read on public.payslip_components;
create policy payslip_components_read on public.payslip_components
  for select to authenticated
  using (
    exists (
      select 1 from public.payslips p
      where p.id = payslip_id
        and (app.is_admin() or p.profile_id = app.current_profile_id())
    )
  );

-- =============================================================================
-- Read models
--
-- security_invoker = on, so the policies above still apply through the view. A
-- view without it would run as its owner and hand every worker the whole payroll.
-- =============================================================================

create or replace view public.v_attendance_days with (security_invoker = on) as
select
  a.id,
  a.profile_id,
  p.name          as staff_name,
  p.employee_code,
  a.work_date,
  a.status,
  a.shift_id,
  s.name          as shift_name,
  a.punch_in_at,
  a.punch_out_at,
  a.worked_hours,
  a.overtime_hours,
  case a.status
    when 'PRESENT'    then 1.0
    when 'HALF_DAY'   then 0.5
    when 'PAID_LEAVE' then 1.0
    when 'HOLIDAY'    then 1.0
    when 'WEEKLY_OFF' then 1.0
    else 0.0
  end             as payable_day,
  a.remarks,
  a.created_at
from public.attendance_days a
join public.profiles p on p.id = a.profile_id
left join public.shifts s on s.id = a.shift_id;

create or replace view public.v_staff_advances with (security_invoker = on) as
select
  p.id            as profile_id,
  p.employee_code,
  p.name          as staff_name,
  coalesce(b.outstanding, 0) as outstanding,
  coalesce(i.issued, 0)      as total_issued,
  coalesce(rec.recovered, 0) as total_recovered,
  b.updated_at
from public.profiles p
left join public.staff_advance_balance b on b.profile_id = p.id
left join (
  select profile_id, sum(amount) as issued
  from public.advance_transactions where transaction_type = 'ISSUED'
  group by profile_id
) i on i.profile_id = p.id
left join (
  select profile_id, -sum(amount) as recovered
  from public.advance_transactions where transaction_type = 'RECOVERED'
  group by profile_id
) rec on rec.profile_id = p.id
where p.active;

create or replace view public.v_payslips with (security_invoker = on) as
select
  s.id,
  s.payroll_period_id,
  pp.period_month,
  pp.status        as period_status,
  s.profile_id,
  p.employee_code,
  p.name           as staff_name,
  p.role,
  s.monthly_salary,
  s.calendar_days,
  s.present_days,
  s.absent_days,
  s.payable_days,
  s.overtime_hours,
  s.overtime_rate_per_hour,
  s.basic_amount,
  s.overtime_amount,
  s.additions_amount,
  s.deductions_amount,
  s.advance_recovered,
  s.gross_amount,
  s.net_payable,
  s.created_at
from public.payslips s
join public.payroll_periods pp on pp.id = s.payroll_period_id
join public.profiles p on p.id = s.profile_id;

-- One row per month: what the factory owes, and whether it is still editable.
--
-- Administrators only, and stated as a WHERE rather than left to RLS. Under RLS
-- alone a worker would see this view aggregate their own single payslip and
-- read it as the factory's total payroll — not a leak, but a number that means
-- something quite different from what it appears to say.
create or replace view public.v_payroll_summary with (security_invoker = on) as
select
  pp.id            as payroll_period_id,
  pp.period_month,
  pp.status,
  count(s.id)                       as payslip_count,
  coalesce(sum(s.gross_amount), 0)  as gross_total,
  coalesce(sum(s.deductions_amount), 0) as deductions_total,
  coalesce(sum(s.advance_recovered), 0) as advance_recovered_total,
  coalesce(sum(s.net_payable), 0)   as net_total,
  pp.finalised_at
from public.payroll_periods pp
left join public.payslips s on s.payroll_period_id = pp.id
where app.is_admin()
group by pp.id, pp.period_month, pp.status, pp.finalised_at;

-- Monthly attendance per person, which is what the payroll screen shows before
-- anyone presses calculate.
create or replace view public.v_monthly_attendance with (security_invoker = on) as
select
  a.profile_id,
  p.employee_code,
  p.name                                   as staff_name,
  date_trunc('month', a.work_date)::date   as period_month,
  count(*)                                 as marked_days,
  count(*) filter (where a.status in ('PRESENT', 'HALF_DAY'))       as present_days,
  count(*) filter (where a.status in ('ABSENT', 'UNPAID_LEAVE'))    as absent_days,
  count(*) filter (where a.status = 'PAID_LEAVE')                   as paid_leave_days,
  coalesce(sum(a.worked_hours), 0)                                  as worked_hours,
  coalesce(sum(a.overtime_hours), 0)                                as overtime_hours
from public.attendance_days a
join public.profiles p on p.id = a.profile_id
group by a.profile_id, p.employee_code, p.name, date_trunc('month', a.work_date);

-- -----------------------------------------------------------------------------
-- Grants
--
-- punch_in and punch_out are callable by anyone signed in — they act on the
-- caller's own record unless an administrator names someone else, and
-- app.assert_self_or_admin() enforces that. The rest call app.require_admin()
-- and refuse everyone else at runtime.
-- -----------------------------------------------------------------------------

grant execute on function
  app.assert_self_or_admin(uuid)
to authenticated;

grant execute on function
  public.punch_in(uuid, timestamptz, uuid, date, uuid),
  public.punch_out(uuid, timestamptz, date, numeric)
to authenticated;

grant execute on function
  public.set_attendance(uuid, date, public.attendance_status, timestamptz, timestamptz, numeric, uuid, text),
  public.set_salary_structure(uuid, numeric, date, numeric, numeric, text),
  public.issue_salary_advance(uuid, numeric, uuid, date, text),
  public.add_staff_adjustment(uuid, date, public.payslip_component_type, text, numeric, uuid, text),
  public.run_payroll(date, text),
  public.finalise_payroll(date)
to authenticated;

-- Realtime: attendance is what changes on a supervisor's screen during a shift.
do $mig$
begin
  alter publication supabase_realtime add table public.attendance_days;
exception when duplicate_object then null;
end
$mig$;
