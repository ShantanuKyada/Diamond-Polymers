-- =============================================================================
-- 0019_simple_payroll.sql — payroll is a salary, less what was taken (A38)
--
-- How the factory actually pays people, in their words:
--
--   "Every worker is assigned some salary — say worker A has 1000 for the
--    month. He gets that at the end of the month. If he needs some of it
--    mid-month he asks, we give him 300, and we reduce it from his monthly
--    salary. Just like this."
--
-- So:
--
--     net payable = monthly salary − advances taken − any deduction entered
--
-- and nothing else. What 0012–0014 built was an engine for a factory that
-- prorates pay by attendance and pays statutory overtime. This one does
-- neither. Every part of that engine the factory does not use is removed here
-- rather than switched off, because a dormant rule is one somebody later
-- assumes is running.
--
-- REMOVED
--   * attendance proration — a month's pay does not move with days present
--   * overtime — no hours, no multiplier, no derived hourly rate
--   * bonuses and incentives — nothing adds to a salary
--   * the payroll_* settings that drove all of the above
--
-- KEPT
--   * advances, ledgered exactly as before. This is the point of the module
--     and the part that has to be right.
--   * a deduction entered by hand for one worker in one month — how a long
--     absence is handled: judged case by case rather than computed from a
--     register. Asked and confirmed, not assumed; see A38.
--   * draft / finalise, because advance recovery must post once and only once.
--
-- ATTENDANCE IS NOT DELETED. punch_in, punch_out and set_attendance stay, and
-- the register still records who was in. It simply no longer decides pay; the
-- two were coupled, and the factory says they are not.
--
-- THIS MIGRATION DESTROYS DATA IF THERE IS ANY. Every drop is guarded against
-- erroring twice, which is not the same as being safe: dropping a column takes
-- what was in it. On a database with payslips already issued, the figures
-- behind them — the basic, the overtime, the day counts — are gone, and a
-- payslip reprinted afterwards would be a different document from the one that
-- was paid.
--
-- Run supabase/checks/0019_preflight.sql first. It refuses if there is anything
-- to lose. Here there was not: no payslip, salary structure, advance,
-- adjustment or attendance row existed on the live project, so the module was
-- rebuilt rather than converted.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The read models go first
--
-- Both select columns that are about to disappear, and Postgres will refuse to
-- drop a column a view depends on. They are rebuilt at the foot of this file.
-- -----------------------------------------------------------------------------

drop view if exists public.v_payroll_summary;
drop view if exists public.v_payslips;

-- -----------------------------------------------------------------------------
-- A salary is a number, not a structure of rates
-- -----------------------------------------------------------------------------

alter table public.salary_structures
  drop column if exists overtime_rate_per_hour,
  drop column if exists standard_hours_per_day;

-- -----------------------------------------------------------------------------
-- A payslip carries four figures
--
-- The CHECK constraints go before the columns they mention, so nothing is left
-- referring to something that no longer exists.
-- -----------------------------------------------------------------------------

alter table public.payslips
  drop constraint if exists payslip_gross_ck,
  drop constraint if exists payslip_net_ck;

alter table public.payslips
  drop column if exists overtime_rate_per_hour,
  drop column if exists calendar_days,
  drop column if exists present_days,
  drop column if exists absent_days,
  drop column if exists payable_days,
  drop column if exists overtime_hours,
  drop column if exists overtime_amount,
  drop column if exists additions_amount,
  drop column if exists basic_amount,
  drop column if exists gross_amount;

-- What is left: the salary, what was deducted, what was recovered, what is
-- paid. The arithmetic stays enforced rather than merely intended — a payslip
-- that does not add up cannot be stored at all.
alter table public.payslips
  add constraint payslip_net_ck
    check (net_payable = monthly_salary - deductions_amount - advance_recovered);

-- -----------------------------------------------------------------------------
-- An adjustment can only subtract
--
-- BONUS and INCENTIVE remain in the enum — removing a value from a Postgres
-- enum means rebuilding the type — but nothing may be stored as one. A bonus
-- row that run_payroll silently ignored would be worse than no bonus at all.
-- -----------------------------------------------------------------------------

alter table public.staff_adjustments
  drop constraint if exists staff_adjustment_type_ck;

alter table public.staff_adjustments
  add constraint staff_adjustment_type_ck check (component_type = 'DEDUCTION');

-- -----------------------------------------------------------------------------
-- Settings that no longer mean anything
--
-- Deleted rather than left sitting at a default. A setting nobody reads is a
-- promise the system has quietly stopped keeping.
-- -----------------------------------------------------------------------------

delete from public.app_settings
where key in (
  'payroll_unmarked_day_policy',
  'payroll_proration_basis',
  'payroll_fixed_days',
  'payroll_overtime_multiplier'
);

-- =============================================================================
-- run_payroll — the entire calculation
-- =============================================================================

create or replace function public.run_payroll(
  p_period_month date,
  p_remarks      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin       uuid := app.require_admin();
  v_month       date := date_trunc('month', p_period_month)::date;
  v_period      public.payroll_periods;
  v_recover     boolean := coalesce(app.setting('payroll_recover_advances', 'true'), 'true') = 'true';
  r             record;
  v_deductions  numeric(12, 2);
  v_recovery    numeric(12, 2);
  v_outstanding numeric(12, 2);
  v_net         numeric(12, 2);
  v_payslip     uuid;
  v_count       integer := 0;
  v_total       numeric(14, 2) := 0;
begin
  select * into v_period from public.payroll_periods where period_month = v_month;

  if v_period.id is null then
    insert into public.payroll_periods (period_month, status, created_by, remarks)
    values (v_month, 'DRAFT', v_admin, p_remarks)
    returning * into v_period;
  elsif v_period.status <> 'DRAFT' then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised and cannot be '
                       'recalculated.', to_char(v_month, 'Mon YYYY')),
      detail  = json_build_object('period_id', v_period.id,
                                  'status', v_period.status)::text;
  end if;

  -- Lock the period so two admins cannot compute it into each other.
  perform 1 from public.payroll_periods where id = v_period.id for update;

  -- A draft is rebuilt from scratch. Nothing outside this table has been
  -- written — recovery posts on finalise — so there is nothing to unwind.
  delete from public.payslips where payroll_period_id = v_period.id;

  for r in
    select p.id as profile_id, p.name, p.employee_code,
           s.id as structure_id, s.monthly_salary
    from public.profiles p
    join lateral (
      -- The salary in force during this month: the latest one that had started
      -- by month end and had not ended before month start.
      select st.*
      from public.salary_structures st
      where st.profile_id = p.id
        and st.effective_from <= (v_month + interval '1 month - 1 day')::date
        and (st.effective_to is null or st.effective_to >= v_month)
      order by st.effective_from desc
      limit 1
    ) s on true
    where p.active
    order by p.employee_code
  loop
    -- Entered by hand for this person in this month. This is how a long absence
    -- is handled now that days present no longer move the figure.
    select coalesce(sum(amount), 0)
    into v_deductions
    from public.staff_adjustments
    where profile_id = r.profile_id
      and period_month = v_month
      and component_type = 'DEDUCTION';

    if v_deductions > r.monthly_salary then
      raise exception using
        errcode = 'DP005',
        message = format('Deductions for %s (%s) come to %s, more than the '
                         'monthly salary of %s. Reduce them before calculating '
                         'the payroll.',
                         r.name, r.employee_code,
                         to_char(v_deductions, 'FM999999990.00'),
                         to_char(r.monthly_salary, 'FM999999990.00')),
        detail  = json_build_object('profile_id', r.profile_id,
                                    'deductions', v_deductions,
                                    'monthly_salary', r.monthly_salary)::text;
    end if;

    -- Capped, so a payslip can never come out negative. Somebody who has drawn
    -- more than a month's pay carries the remainder forward to the next one.
    v_recovery := 0;
    if v_recover then
      select coalesce(outstanding, 0) into v_outstanding
      from public.staff_advance_balance where profile_id = r.profile_id;

      v_recovery := least(coalesce(v_outstanding, 0),
                          r.monthly_salary - v_deductions);
    end if;

    v_net := r.monthly_salary - v_deductions - v_recovery;

    insert into public.payslips (
      payroll_period_id, profile_id, salary_structure_id,
      monthly_salary, deductions_amount, advance_recovered, net_payable,
      created_by
    )
    values (
      v_period.id, r.profile_id, r.structure_id,
      r.monthly_salary, v_deductions, v_recovery, v_net,
      v_admin
    )
    returning id into v_payslip;

    -- The itemised lines, signed so that adding them up gives net_payable.
    insert into public.payslip_components
      (payslip_id, component_type, label, amount, sort_order)
    values (v_payslip, 'BASIC', 'Monthly salary', r.monthly_salary, 1);

    insert into public.payslip_components
      (payslip_id, component_type, label, amount, sort_order)
    select v_payslip, 'DEDUCTION', label, -amount, 2
    from public.staff_adjustments
    where profile_id = r.profile_id
      and period_month = v_month
      and component_type = 'DEDUCTION';

    if v_recovery > 0 then
      insert into public.payslip_components
        (payslip_id, component_type, label, amount, sort_order)
      values (v_payslip, 'ADVANCE_RECOVERY', 'Advance already taken',
              -v_recovery, 3);
    end if;

    v_count := v_count + 1;
    v_total := v_total + v_net;
  end loop;

  return jsonb_build_object(
    'period_id',    v_period.id,
    'period_month', v_month,
    'status',       v_period.status,
    'payslips',     v_count,
    'net_total',    v_total
  );
end;
$fn$;

-- =============================================================================
-- set_salary_structure — without the rate fields it no longer carries
--
-- Dropped before it is recreated: PostgREST binds arguments by name, and the
-- old six-argument form left in place would make an overload it cannot choose
-- between.
-- =============================================================================

drop function if exists public.set_salary_structure(uuid, numeric, date, numeric, numeric, text);

create or replace function public.set_salary_structure(
  p_profile_id     uuid,
  p_monthly_salary numeric,
  p_effective_from date default current_date,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_open  public.salary_structures;
  v_id    uuid;
begin
  if p_monthly_salary is null or p_monthly_salary <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Monthly salary must be greater than zero.',
      detail  = '{"field":"monthly_salary"}';
  end if;

  if not exists (select 1 from public.profiles where id = p_profile_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That staff member does not exist or is inactive.',
      detail  = '{"field":"profile_id"}';
  end if;

  -- Lock the person, so two admins granting a raise at the same moment cannot
  -- both close the open period and leave two open rows behind.
  perform 1 from public.profiles where id = p_profile_id for update;

  select * into v_open
  from public.salary_structures
  where profile_id = p_profile_id and effective_to is null;

  if v_open.id is not null then
    if p_effective_from <= v_open.effective_from then
      raise exception using
        errcode = 'DP005',
        message = format('A salary effective %s is already on record. A change '
                         'must start after it.',
                         to_char(v_open.effective_from, 'DD Mon YYYY')),
        detail  = json_build_object('effective_from', v_open.effective_from)::text;
    end if;

    -- The previous rate ends the day before the new one starts. A raise is a
    -- new row, never an edit, so a past payslip keeps the rate it was paid at.
    update public.salary_structures
    set effective_to = p_effective_from - 1
    where id = v_open.id;
  end if;

  insert into public.salary_structures
    (profile_id, effective_from, monthly_salary, created_by, remarks)
  values
    (p_profile_id, p_effective_from, p_monthly_salary, v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'profile_id', p_profile_id,
                            'monthly_salary', p_monthly_salary,
                            'effective_from', p_effective_from,
                            'previous_closed', v_open.id);
end;
$fn$;

grant execute on function
  public.set_salary_structure(uuid, numeric, date, text)
to authenticated;

-- =============================================================================
-- add_staff_adjustment — deductions only
--
-- The signature is unchanged, so PostgREST sees the same function; what it
-- accepts is not.
-- =============================================================================

create or replace function public.add_staff_adjustment(
  p_profile_id     uuid,
  p_period_month   date,
  p_component_type public.payslip_component_type,
  p_label          text,
  p_amount         numeric,
  p_client_ref     uuid,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_month date := date_trunc('month', p_period_month)::date;
  v_id    uuid;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'The amount must be greater than zero. A deduction is entered '
                'as a positive number.',
      detail  = '{"field":"amount"}';
  end if;

  if p_component_type <> 'DEDUCTION' then
    raise exception using
      errcode = 'DP005',
      message = 'Only a deduction can be added to a payslip. Nothing adds to a '
                'monthly salary.',
      detail  = '{"field":"component_type"}';
  end if;

  select id into v_id from public.staff_adjustments where client_ref = p_client_ref;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;

  if exists (select 1 from public.payroll_periods
             where period_month = v_month and status <> 'DRAFT') then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised.',
                       to_char(v_month, 'Mon YYYY')),
      detail  = '{"field":"period_month"}';
  end if;

  insert into public.staff_adjustments
    (profile_id, period_month, component_type, label, amount, client_ref,
     created_by, remarks)
  values
    (p_profile_id, v_month, 'DEDUCTION', btrim(p_label), p_amount,
     p_client_ref, v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$fn$;

-- =============================================================================
-- remove_staff_adjustment — the undo the deduction never had
--
-- A deduction is now the only manual lever in the whole module, and a mistyped
-- one that exceeds the salary stops the month's payroll dead. Before this there
-- was no way to take one back: staff_adjustments is admin-readable and has no
-- write path but add_staff_adjustment.
--
-- Deleting is honest here rather than lossy. A draft's payslips are rebuilt
-- from scratch on every run, and a finalised month is refused outright, so
-- nothing that has been paid can be rewritten by this.
-- =============================================================================

create or replace function public.remove_staff_adjustment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_row   public.staff_adjustments;
begin
  select * into v_row from public.staff_adjustments where id = p_id;

  -- Already gone. Saying so beats raising at an admin who pressed twice.
  if v_row.id is null then
    return jsonb_build_object('id', p_id, 'removed', false);
  end if;

  if exists (select 1 from public.payroll_periods
             where period_month = v_row.period_month and status <> 'DRAFT') then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised, so its deductions '
                       'can no longer be changed.',
                       to_char(v_row.period_month, 'Mon YYYY')),
      detail  = json_build_object('period_month', v_row.period_month)::text;
  end if;

  delete from public.staff_adjustments where id = p_id;

  return jsonb_build_object('id', p_id, 'removed', true,
                            'profile_id', v_row.profile_id,
                            'period_month', v_row.period_month,
                            'amount', v_row.amount);
end;
$fn$;

grant execute on function public.remove_staff_adjustment(uuid) to authenticated;

-- =============================================================================
-- The read models, rebuilt to match what a payslip now says
--
-- security_invoker = on, so the policies on payslips still apply through the
-- view. Without it the view would run as its owner and hand every worker the
-- whole payroll.
-- =============================================================================

create view public.v_payslips with (security_invoker = on) as
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
  s.deductions_amount,
  s.advance_recovered,
  s.net_payable,
  s.created_at
from public.payslips s
join public.payroll_periods pp on pp.id = s.payroll_period_id
join public.profiles p on p.id = s.profile_id;

-- Everyone on the payroll with the salary they are on and what they have drawn
-- against it — the two numbers the factory works from day to day.
--
-- The salary shown is the one in force today, not the latest row on file: a
-- raise dated next month is not what somebody is paid this month. Any such raise
-- is reported separately rather than hidden, so the roster can say both.
--
-- A worker sees only their own row. Under security_invoker alone they would see
-- every colleague listed with a blank salary, since profiles is readable but
-- salary_structures is not: no leak, but a roster that looks like everybody is
-- unpaid.
drop view if exists public.v_staff_pay;
create view public.v_staff_pay with (security_invoker = on) as
select
  p.id                       as profile_id,
  p.employee_code,
  p.name                     as staff_name,
  p.role,
  today.id                   as salary_structure_id,
  today.monthly_salary,
  today.effective_from,
  case when open.effective_from > current_date then open.monthly_salary end
                             as upcoming_salary,
  case when open.effective_from > current_date then open.effective_from end
                             as upcoming_from,
  coalesce(b.outstanding, 0) as outstanding_advance
from public.profiles p
left join lateral (
  select st.*
  from public.salary_structures st
  where st.profile_id = p.id
    and st.effective_from <= current_date
    and (st.effective_to is null or st.effective_to >= current_date)
  order by st.effective_from desc
  limit 1
) today on true
-- At most one open-ended row per person, by unique index.
left join public.salary_structures open
  on open.profile_id = p.id and open.effective_to is null
left join public.staff_advance_balance b
  on b.profile_id = p.id
where p.active
  and (app.is_admin() or p.id = app.current_profile_id());

-- Deductions waiting to land on a payslip. Administrators only, which the
-- policy on staff_adjustments already says; the view inherits it.
drop view if exists public.v_staff_deductions;
create view public.v_staff_deductions with (security_invoker = on) as
select
  a.id,
  a.profile_id,
  p.employee_code,
  p.name         as staff_name,
  a.period_month,
  a.label,
  a.amount,
  a.remarks,
  a.created_at
from public.staff_adjustments a
join public.profiles p on p.id = a.profile_id
where a.component_type = 'DEDUCTION';

-- One row per month: what the factory owes, and whether it is still editable.
--
-- Administrators only, and stated as a WHERE rather than left to RLS. Under RLS
-- alone a worker would see this view aggregate their own single payslip and
-- read it as the factory's total payroll — not a leak, but a number that means
-- something quite different from what it appears to say.
create view public.v_payroll_summary with (security_invoker = on) as
select
  pp.id            as payroll_period_id,
  pp.period_month,
  pp.status,
  count(s.id)                               as payslip_count,
  coalesce(sum(s.monthly_salary), 0)        as salary_total,
  coalesce(sum(s.deductions_amount), 0)     as deductions_total,
  coalesce(sum(s.advance_recovered), 0)     as advance_recovered_total,
  coalesce(sum(s.net_payable), 0)           as net_total,
  pp.finalised_at
from public.payroll_periods pp
left join public.payslips s on s.payroll_period_id = pp.id
where app.is_admin()
group by pp.id, pp.period_month, pp.status, pp.finalised_at;
