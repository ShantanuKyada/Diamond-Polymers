-- =============================================================================
-- 0013_payroll_rpc.sql — the write API for attendance and payroll
--
-- Same discipline as the stock side: no table takes a client INSERT, every
-- movement is one SECURITY DEFINER routine, and money is ledgered with a locked
-- balance row.
--
-- The one rule worth stating on its own: ADVANCE RECOVERY HAPPENS ON FINALISE,
-- NOT ON CALCULATE. run_payroll() can be run twenty times while the numbers are
-- being checked, and it only ever *proposes* a recovery. finalise_payroll()
-- posts it to the advance ledger once. Recovering on calculate would drain a
-- worker's advance balance every time somebody reloaded the screen.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Who may act on whose record
--
-- An admin may act for anybody. Anybody else may act only for themselves, which
-- is what lets an operator punch their own card without being able to mark a
-- colleague present.
-- -----------------------------------------------------------------------------

create or replace function app.assert_self_or_admin(p_profile_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller uuid := app.require_profile();
begin
  if app.is_admin() or p_profile_id = v_caller then
    return v_caller;
  end if;

  raise exception using
    errcode = 'DP004',
    message = 'You can only do that for your own record.',
    detail  = '{"reason":"profile_mismatch"}';
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Advance ledger movement — the money equivalent of app.apply_raw_movement
-- -----------------------------------------------------------------------------

create or replace function app.apply_advance_movement(
  p_profile_id      uuid,
  p_type            public.advance_txn_type,
  p_delta           numeric,
  p_created_by      uuid,
  p_entry_date      date default current_date,
  p_reference_id    uuid default null,
  p_reference_table text default null,
  p_client_ref      uuid default null,
  p_remarks         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_prev numeric(12, 2);
  v_next numeric(12, 2);
  v_txn  uuid;
  v_name text;
begin
  if p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'An advance movement cannot be zero.',
      detail  = '{"field":"amount"}';
  end if;

  insert into public.staff_advance_balance (profile_id, outstanding)
  values (p_profile_id, 0)
  on conflict (profile_id) do nothing;

  select outstanding into v_prev
  from public.staff_advance_balance
  where profile_id = p_profile_id
  for update;

  v_next := v_prev + p_delta;

  -- Recovering more than is owed would turn an advance into a fine.
  if v_next < 0 then
    select name into v_name from public.profiles where id = p_profile_id;
    raise exception using
      errcode = 'DP010',
      message = format('%s has only %s outstanding in advances.',
                       coalesce(v_name, 'That employee'),
                       trim(to_char(v_prev, 'FM999999990.00'))),
      detail  = json_build_object('profile_id', p_profile_id,
                                  'outstanding', v_prev,
                                  'requested', abs(p_delta))::text;
  end if;

  update public.staff_advance_balance
  set outstanding = v_next, updated_at = now()
  where profile_id = p_profile_id;

  insert into public.advance_transactions (
    profile_id, transaction_type, amount,
    previous_outstanding, resulting_outstanding,
    entry_date, reference_id, reference_table, client_ref, created_by, remarks
  )
  values (
    p_profile_id, p_type, p_delta, v_prev, v_next,
    p_entry_date, p_reference_id, p_reference_table, p_client_ref, p_created_by, p_remarks
  )
  returning id into v_txn;

  return v_txn;
end;
$fn$;

-- =============================================================================
-- Attendance
-- =============================================================================

create or replace function public.punch_in(
  p_profile_id uuid default null,
  p_at         timestamptz default now(),
  p_shift_id   uuid default null,
  p_work_date  date default null,
  p_client_ref uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_person uuid := coalesce(p_profile_id, app.current_profile_id());
  v_caller uuid;
  v_tz     text := coalesce(app.setting('factory_timezone', 'Asia/Kolkata'), 'Asia/Kolkata');
  v_date   date;
  v_row    public.attendance_days;
begin
  v_caller := app.assert_self_or_admin(v_person);

  -- The work date is the date on the factory floor, not in UTC. A 22:00 punch
  -- in Mumbai belongs to that day's night shift, not to the next UTC day.
  v_date := coalesce(p_work_date, ((p_at at time zone v_tz)::date));

  select * into v_row
  from public.attendance_days
  where profile_id = v_person and work_date = v_date;

  if v_row.id is not null then
    if v_row.punch_in_at is not null then
      -- Idempotent: punching in twice is a double tap, not a second shift.
      return jsonb_build_object('id', v_row.id, 'duplicate', true,
                                'punch_in_at', v_row.punch_in_at);
    end if;

    update public.attendance_days
    set punch_in_at = p_at,
        status      = 'PRESENT',
        shift_id    = coalesce(p_shift_id, shift_id)
    where id = v_row.id
    returning * into v_row;
  else
    insert into public.attendance_days
      (profile_id, work_date, shift_id, status, punch_in_at, client_ref, created_by)
    values
      (v_person, v_date, p_shift_id, 'PRESENT', p_at, p_client_ref, v_caller)
    returning * into v_row;
  end if;

  return jsonb_build_object('id', v_row.id, 'duplicate', false,
                            'work_date', v_row.work_date,
                            'punch_in_at', v_row.punch_in_at);
end;
$fn$;

create or replace function public.punch_out(
  p_profile_id     uuid default null,
  p_at             timestamptz default now(),
  p_work_date      date default null,
  p_overtime_hours numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_person uuid := coalesce(p_profile_id, app.current_profile_id());
  v_caller uuid;
  v_tz     text := coalesce(app.setting('factory_timezone', 'Asia/Kolkata'), 'Asia/Kolkata');
  v_date   date;
  v_row    public.attendance_days;
begin
  v_caller := app.assert_self_or_admin(v_person);
  v_date   := coalesce(p_work_date, ((p_at at time zone v_tz)::date));

  select * into v_row
  from public.attendance_days
  where profile_id = v_person and work_date = v_date;

  -- A night shift is punched out on the following calendar day. Fall back to
  -- the previous day's open row rather than opening a second one.
  if v_row.id is null or v_row.punch_in_at is null then
    select * into v_row
    from public.attendance_days
    where profile_id = v_person
      and work_date = v_date - 1
      and punch_in_at is not null
      and punch_out_at is null;
  end if;

  if v_row.id is null then
    raise exception using
      errcode = 'DP005',
      message = 'There is no open punch to close for that day.',
      detail  = '{"field":"work_date"}';
  end if;

  if v_row.punch_out_at is not null then
    return jsonb_build_object('id', v_row.id, 'duplicate', true,
                              'punch_out_at', v_row.punch_out_at);
  end if;

  if p_at <= v_row.punch_in_at then
    raise exception using
      errcode = 'DP005',
      message = 'Punch out must be after punch in.',
      detail  = '{"field":"punch_out_at"}';
  end if;

  update public.attendance_days
  set punch_out_at   = p_at,
      overtime_hours = coalesce(p_overtime_hours, overtime_hours)
  where id = v_row.id
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'duplicate', false,
                            'work_date', v_row.work_date,
                            'worked_hours', v_row.worked_hours,
                            'overtime_hours', v_row.overtime_hours);
end;
$fn$;

-- Admin marking: absence, leave, a holiday, or a correction to the punches.
create or replace function public.set_attendance(
  p_profile_id     uuid,
  p_work_date      date,
  p_status         public.attendance_status,
  p_punch_in_at    timestamptz default null,
  p_punch_out_at   timestamptz default null,
  p_overtime_hours numeric default 0,
  p_shift_id       uuid default null,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_row   public.attendance_days;
  v_in    timestamptz := p_punch_in_at;
  v_out   timestamptz := p_punch_out_at;
begin
  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception using
      errcode = 'DP005',
      message = 'That staff member does not exist.',
      detail  = '{"field":"profile_id"}';
  end if;

  -- A day marked absent or on leave cannot also carry punches. The table CHECK
  -- says so too; clearing them here means an admin correcting a mis-punch to
  -- "absent" is not told off for data they did not supply.
  if p_status in ('ABSENT', 'UNPAID_LEAVE', 'PAID_LEAVE') then
    v_in  := null;
    v_out := null;
  end if;

  if v_in is not null and v_out is not null and v_out <= v_in then
    raise exception using
      errcode = 'DP005',
      message = 'Punch out must be after punch in.',
      detail  = '{"field":"punch_out_at"}';
  end if;

  insert into public.attendance_days
    (profile_id, work_date, shift_id, status, punch_in_at, punch_out_at,
     overtime_hours, created_by, remarks)
  values
    (p_profile_id, p_work_date, p_shift_id, p_status, v_in, v_out,
     coalesce(p_overtime_hours, 0), v_admin, p_remarks)
  on conflict (profile_id, work_date) do update
    set status         = excluded.status,
        shift_id       = coalesce(excluded.shift_id, public.attendance_days.shift_id),
        punch_in_at    = excluded.punch_in_at,
        punch_out_at   = excluded.punch_out_at,
        overtime_hours = excluded.overtime_hours,
        remarks        = excluded.remarks
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'status', v_row.status,
                            'worked_hours', v_row.worked_hours);
end;
$fn$;

-- =============================================================================
-- Salary structure
-- =============================================================================

create or replace function public.set_salary_structure(
  p_profile_id             uuid,
  p_monthly_salary         numeric,
  p_effective_from         date default current_date,
  p_overtime_rate_per_hour numeric default null,
  p_standard_hours_per_day numeric default 8,
  p_remarks                text default null
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

  -- Lock the person so two admins granting a raise at the same moment cannot
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
                         'must start after it.', to_char(v_open.effective_from, 'DD Mon YYYY')),
        detail  = json_build_object('effective_from', v_open.effective_from)::text;
    end if;

    -- The previous rate ends the day before the new one starts. A raise is a new
    -- row, never an edit, so past payslips keep the rate they were paid at.
    update public.salary_structures
    set effective_to = p_effective_from - 1
    where id = v_open.id;
  end if;

  insert into public.salary_structures
    (profile_id, effective_from, monthly_salary, overtime_rate_per_hour,
     standard_hours_per_day, created_by, remarks)
  values
    (p_profile_id, p_effective_from, p_monthly_salary, p_overtime_rate_per_hour,
     coalesce(p_standard_hours_per_day, 8), v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'profile_id', p_profile_id,
                            'monthly_salary', p_monthly_salary,
                            'effective_from', p_effective_from,
                            'previous_closed', v_open.id);
end;
$fn$;

-- =============================================================================
-- Advances
-- =============================================================================

create or replace function public.issue_salary_advance(
  p_profile_id uuid,
  p_amount     numeric,
  p_client_ref uuid,
  p_entry_date date default current_date,
  p_remarks    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_txn   uuid;
  v_left  numeric(12, 2);
begin
  if p_amount is null or p_amount <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'An advance must be greater than zero.',
      detail  = '{"field":"amount"}';
  end if;

  -- Idempotent: a retried submission returns the advance already issued rather
  -- than handing out the money twice.
  select id into v_txn from public.advance_transactions where client_ref = p_client_ref;
  if v_txn is not null then
    select outstanding into v_left
    from public.staff_advance_balance where profile_id = p_profile_id;
    return jsonb_build_object('transaction_id', v_txn, 'duplicate', true,
                              'outstanding', v_left);
  end if;

  v_txn := app.apply_advance_movement(
    p_profile_id, 'ISSUED', p_amount, v_admin, p_entry_date,
    null, 'manual', p_client_ref, p_remarks);

  select outstanding into v_left
  from public.staff_advance_balance where profile_id = p_profile_id;

  return jsonb_build_object('transaction_id', v_txn, 'duplicate', false,
                            'outstanding', v_left);
end;
$fn$;

-- =============================================================================
-- run_payroll — compute a month's payslips
--
-- Recomputable while a period is DRAFT: it deletes and rebuilds the payslips
-- each time. It NEVER touches the advance ledger — it only records what it
-- proposes to recover. finalise_payroll() posts that once.
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
  v_admin        uuid := app.require_admin();
  v_month        date := date_trunc('month', p_period_month)::date;
  v_days         integer;
  v_period       public.payroll_periods;
  v_unmarked     text := coalesce(app.setting('payroll_unmarked_day_policy', 'PAYABLE'), 'PAYABLE');
  v_basis        text := coalesce(app.setting('payroll_proration_basis', 'CALENDAR_DAYS'), 'CALENDAR_DAYS');
  v_fixed_days   numeric := coalesce(nullif(app.setting('payroll_fixed_days', '26'), '')::numeric, 26);
  v_ot_multiple  numeric := coalesce(nullif(app.setting('payroll_overtime_multiplier', '2.0'), '')::numeric, 2.0);
  v_recover      boolean := coalesce(app.setting('payroll_recover_advances', 'true'), 'true') = 'true';
  v_divisor      numeric;
  r              record;
  v_marked       numeric;
  v_payable      numeric;
  v_present      numeric;
  v_absent       numeric;
  v_ot_hours     numeric;
  v_ot_rate      numeric;
  v_basic        numeric(12, 2);
  v_ot_amount    numeric(12, 2);
  v_additions    numeric(12, 2);
  v_deductions   numeric(12, 2);
  v_gross        numeric(12, 2);
  v_recovery     numeric(12, 2);
  v_net          numeric(12, 2);
  v_outstanding  numeric(12, 2);
  v_payslip      uuid;
  v_count        integer := 0;
  v_total        numeric(14, 2) := 0;
begin
  v_days := extract(day from (v_month + interval '1 month - 1 day'))::integer;

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
  -- written, so there is nothing to unwind.
  delete from public.payslips where payroll_period_id = v_period.id;

  v_divisor := case when v_basis = 'FIXED_DAYS' then v_fixed_days else v_days end;

  for r in
    select p.id as profile_id, p.name, s.id as structure_id, s.monthly_salary,
           s.overtime_rate_per_hour, s.standard_hours_per_day
    from public.profiles p
    join lateral (
      -- The structure in force during this month: the latest one that had
      -- started by month end and had not ended before month start.
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
    select
      coalesce(count(*), 0),
      coalesce(sum(case a.status
                     when 'PRESENT' then 1
                     when 'HALF_DAY' then 0.5
                     when 'PAID_LEAVE' then 1
                     when 'HOLIDAY' then 1
                     when 'WEEKLY_OFF' then 1
                     else 0 end), 0),
      coalesce(sum(case when a.status in ('PRESENT', 'HALF_DAY') then 1 else 0 end), 0),
      coalesce(sum(case when a.status in ('ABSENT', 'UNPAID_LEAVE') then 1 else 0 end), 0),
      coalesce(sum(a.overtime_hours), 0)
    into v_marked, v_payable, v_present, v_absent, v_ot_hours
    from public.attendance_days a
    where a.profile_id = r.profile_id
      and a.work_date >= v_month
      and a.work_date <= (v_month + interval '1 month - 1 day')::date;

    -- Days nobody said anything about. PAYABLE means the factory marks only
    -- exceptions, which is the common convention and the safer failure.
    if v_unmarked = 'PAYABLE' then
      v_payable := v_payable + (v_days - v_marked);
    end if;

    v_payable := least(greatest(v_payable, 0), v_days);

    v_basic := round(r.monthly_salary * v_payable / v_divisor, 2);

    v_ot_rate := coalesce(
      r.overtime_rate_per_hour,
      round(r.monthly_salary / v_fixed_days / r.standard_hours_per_day * v_ot_multiple, 2)
    );
    v_ot_amount := round(v_ot_hours * v_ot_rate, 2);

    select
      coalesce(sum(amount) filter (where component_type in ('BONUS', 'INCENTIVE')), 0),
      coalesce(sum(amount) filter (where component_type = 'DEDUCTION'), 0)
    into v_additions, v_deductions
    from public.staff_adjustments
    where profile_id = r.profile_id and period_month = v_month;

    v_gross := v_basic + v_ot_amount + v_additions;

    -- Recovery is capped so a payslip can never come out negative. A worker who
    -- owes more than they earned this month carries the rest forward.
    v_recovery := 0;
    if v_recover then
      select coalesce(outstanding, 0) into v_outstanding
      from public.staff_advance_balance where profile_id = r.profile_id;

      v_recovery := least(coalesce(v_outstanding, 0),
                          greatest(v_gross - v_deductions, 0));
    end if;

    v_net := v_gross - v_deductions - v_recovery;

    insert into public.payslips (
      payroll_period_id, profile_id, salary_structure_id,
      monthly_salary, overtime_rate_per_hour, calendar_days,
      present_days, absent_days, payable_days, overtime_hours,
      basic_amount, overtime_amount, additions_amount,
      deductions_amount, advance_recovered, gross_amount, net_payable,
      created_by
    )
    values (
      v_period.id, r.profile_id, r.structure_id,
      r.monthly_salary, v_ot_rate, v_days,
      v_present, v_absent, v_payable, v_ot_hours,
      v_basic, v_ot_amount, v_additions,
      v_deductions, v_recovery, v_gross, v_net,
      v_admin
    )
    returning id into v_payslip;

    insert into public.payslip_components (payslip_id, component_type, label, amount, sort_order)
    values (v_payslip, 'BASIC',
            format('Basic — %s of %s days', trim(to_char(v_payable, 'FM990.9')), v_days),
            v_basic, 1);

    if v_ot_amount > 0 then
      insert into public.payslip_components (payslip_id, component_type, label, amount, sort_order)
      values (v_payslip, 'OVERTIME',
              format('Overtime — %s h at %s', trim(to_char(v_ot_hours, 'FM990.99')),
                     trim(to_char(v_ot_rate, 'FM999990.00'))),
              v_ot_amount, 2);
    end if;

    insert into public.payslip_components (payslip_id, component_type, label, amount, sort_order)
    select v_payslip, component_type, label, amount, 3
    from public.staff_adjustments
    where profile_id = r.profile_id and period_month = v_month
      and component_type in ('BONUS', 'INCENTIVE');

    insert into public.payslip_components (payslip_id, component_type, label, amount, sort_order)
    select v_payslip, component_type, label, -amount, 4
    from public.staff_adjustments
    where profile_id = r.profile_id and period_month = v_month
      and component_type = 'DEDUCTION';

    if v_recovery > 0 then
      insert into public.payslip_components (payslip_id, component_type, label, amount, sort_order)
      values (v_payslip, 'ADVANCE_RECOVERY', 'Advance recovered', -v_recovery, 5);
    end if;

    v_count := v_count + 1;
    v_total := v_total + v_net;
  end loop;

  return jsonb_build_object(
    'period_id',    v_period.id,
    'period_month', v_month,
    'status',       v_period.status,
    'payslips',     v_count,
    'net_total',    v_total,
    'calendar_days', v_days
  );
end;
$fn$;

-- =============================================================================
-- finalise_payroll — freeze the month and post the advance recoveries
--
-- This is the only place a payslip's proposed recovery becomes a real movement
-- on the advance ledger. It is done under a lock on the period, and the whole
-- thing is one transaction: if any recovery fails, no payslip is frozen and no
-- balance has moved.
-- =============================================================================

create or replace function public.finalise_payroll(p_period_month date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin  uuid := app.require_admin();
  v_month  date := date_trunc('month', p_period_month)::date;
  v_period public.payroll_periods;
  r        record;
  v_posted integer := 0;
begin
  select * into v_period from public.payroll_periods where period_month = v_month;

  if v_period.id is null then
    raise exception using
      errcode = 'DP005',
      message = format('Payroll has not been calculated for %s yet.',
                       to_char(v_month, 'Mon YYYY')),
      detail  = '{"field":"period_month"}';
  end if;

  perform 1 from public.payroll_periods where id = v_period.id for update;

  -- Re-read under the lock: another session may have finalised it while this
  -- one was waiting.
  select * into v_period from public.payroll_periods where id = v_period.id;

  if v_period.status <> 'DRAFT' then
    return jsonb_build_object('period_id', v_period.id, 'duplicate', true,
                              'status', v_period.status);
  end if;

  if not exists (select 1 from public.payslips where payroll_period_id = v_period.id) then
    raise exception using
      errcode = 'DP005',
      message = 'There are no payslips to finalise. Calculate the payroll first.',
      detail  = '{"field":"period_month"}';
  end if;

  for r in
    select id, profile_id, advance_recovered
    from public.payslips
    where payroll_period_id = v_period.id and advance_recovered > 0
    order by profile_id
  loop
    -- Raises DP010 and rolls the whole finalisation back if the outstanding
    -- balance has shrunk since the payroll was calculated.
    perform app.apply_advance_movement(
      r.profile_id, 'RECOVERED', -r.advance_recovered, v_admin,
      current_date, r.id, 'payslips', null, 'Recovered on payslip');
    v_posted := v_posted + 1;
  end loop;

  update public.payroll_periods
  set status = 'FINALISED', finalised_at = now(), finalised_by = v_admin
  where id = v_period.id;

  perform app.notify_role(
    'ADMIN',
    format('Payroll finalised — %s', to_char(v_month, 'Mon YYYY')),
    format('%s payslips were finalised and %s advance recoveries posted.',
           (select count(*) from public.payslips where payroll_period_id = v_period.id),
           v_posted),
    'SYSTEM',
    json_build_object('period_id', v_period.id)::jsonb
  );

  return jsonb_build_object('period_id', v_period.id, 'duplicate', false,
                            'status', 'FINALISED', 'recoveries_posted', v_posted);
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Ad-hoc bonus or deduction for one person in one month
-- -----------------------------------------------------------------------------

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
      message = 'The amount must be greater than zero. A deduction is entered as '
                'a positive number with type DEDUCTION.',
      detail  = '{"field":"amount"}';
  end if;

  if p_component_type not in ('BONUS', 'INCENTIVE', 'DEDUCTION') then
    raise exception using
      errcode = 'DP005',
      message = 'An adjustment must be a bonus, an incentive or a deduction.',
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
      message = format('Payroll for %s is already finalised.', to_char(v_month, 'Mon YYYY')),
      detail  = '{"field":"period_month"}';
  end if;

  insert into public.staff_adjustments
    (profile_id, period_month, component_type, label, amount, client_ref, created_by, remarks)
  values
    (p_profile_id, v_month, p_component_type, btrim(p_label), p_amount,
     p_client_ref, v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$fn$;
