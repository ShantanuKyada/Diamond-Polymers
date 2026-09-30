-- =============================================================================
-- 0019_preflight.sql — run BEFORE applying 0019_simple_payroll.sql
--
-- 0019 drops columns. `drop column if exists` guards against erroring on a
-- second run; it does not guard the data. Anything in those columns goes with
-- them, and a payslip reprinted afterwards would be a different document from
-- the one that was paid.
--
-- Rows 4 and 5 are the ones that matter. If either says false, STOP: this
-- database has payroll history and 0019 as written would destroy the figures
-- behind it.
--
-- Paste into the Supabase SQL editor and run. Nothing here writes anything.
-- =============================================================================

select
  '01. Payroll 0012-0014 applied' as check,
  to_regclass('public.payslips') is not null as ok,
  case
    when to_regclass('public.payslips') is null
      then 'payslips missing — apply 0012-0014 first'
    else 'payroll tables present'
  end as detail

union all
select
  '02. Migrations through 0018 applied',
  to_regclass('public.production_entries') is not null
    and exists (select 1 from information_schema.columns
                where table_schema = 'public'
                  and table_name = 'production_entries'
                  and column_name = 'mixture_entry_id'),
  case
    when exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and table_name = 'production_entries'
                   and column_name = 'mixture_entry_id')
      then 'production_entries.mixture_entry_id present (0018 applied)'
    else 'apply 0015-0018 first'
  end

union all
select
  '03. 0019 not applied yet',
  exists (select 1 from information_schema.columns
          where table_schema = 'public'
            and table_name = 'payslips'
            and column_name = 'basic_amount'),
  case
    when exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and table_name = 'payslips'
                   and column_name = 'basic_amount')
      then 'payslips.basic_amount still present — 0019 has not run'
    else 'already applied; skip to 0019_verify.sql'
  end

union all
-- ---------------------------------------------------------------------------
-- The two that decide whether this is safe
-- ---------------------------------------------------------------------------
select
  '04. No payslip has been issued',
  not exists (select 1 from public.payslips),
  case
    when not exists (select 1 from public.payslips)
      then 'no payslips — nothing to lose'
    else (select count(*)::text ||
          ' payslip(s) exist. STOP: 0019 would drop the basic, overtime and ' ||
          'day counts behind them, and those figures are what was paid.'
          from public.payslips)
  end

union all
select
  '05. No salary carries an overtime rate',
  -- Read through to_jsonb rather than naming the column: Postgres parses this
  -- whole statement before running any of it, so naming a column that 0019 has
  -- already dropped would fail the script outright when somebody re-runs it to
  -- confirm. Once the column is gone the key is simply absent, and this reads
  -- as "nothing to lose", which is true.
  not exists (select 1 from public.salary_structures s
              where to_jsonb(s) ->> 'overtime_rate_per_hour' is not null),
  case
    when not exists (select 1 from public.salary_structures s
                     where to_jsonb(s) ->> 'overtime_rate_per_hour' is not null)
      then 'no explicit overtime rates on file'
    else (select count(*)::text ||
          ' salary structure(s) carry an overtime rate. STOP: 0019 drops that ' ||
          'column and the rate is not recorded anywhere else.'
          from public.salary_structures s
          where to_jsonb(s) ->> 'overtime_rate_per_hour' is not null)
  end

union all
-- ---------------------------------------------------------------------------
-- Informational — what 0019 leaves alone
-- ---------------------------------------------------------------------------
select
  '06. Salaries on file (kept)',
  true,
  coalesce((select count(*)::text || ' salary structure(s); monthly_salary is ' ||
            'not touched' from public.salary_structures), '0')

union all
select
  '07. Advances on file (kept)',
  true,
  coalesce((select count(*)::text || ' advance transaction(s); the ledger is ' ||
            'not touched' from public.advance_transactions), '0')

union all
select
  '08. Attendance on file (kept)',
  true,
  coalesce((select count(*)::text || ' attendance day(s); still recorded, no ' ||
            'longer decides pay' from public.attendance_days), '0')

union all
select
  '09. Adjustments that are not deductions',
  not exists (select 1 from public.staff_adjustments
              where component_type <> 'DEDUCTION'),
  case
    when not exists (select 1 from public.staff_adjustments
                     where component_type <> 'DEDUCTION')
      then 'none — the new CHECK will apply cleanly'
    else (select count(*)::text ||
          ' bonus/incentive row(s). STOP: the new CHECK refuses them, so 0019 ' ||
          'will fail until they are removed or converted.'
          from public.staff_adjustments where component_type <> 'DEDUCTION')
  end

order by 1;
