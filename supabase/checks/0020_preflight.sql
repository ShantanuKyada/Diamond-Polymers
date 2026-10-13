-- =============================================================================
-- 0020_preflight.sql — run BEFORE applying 0020_worker_profiles_and_salary_payments.sql
--
-- Unlike 0019, this migration adds. It drops no columns and deletes no rows:
-- two nullable columns on profiles, one new table, three new functions, and
-- five read models rebuilt with more columns than they had. There is nothing
-- here that can lose data.
--
-- Rows 1 and 2 must say true. The rest are informational.
--
-- Paste into the Supabase SQL editor and run. Nothing here writes anything.
-- =============================================================================

select
  '01. Migration 0019 applied' as check,
  to_regprocedure('public.remove_staff_adjustment(uuid)') is not null
    and not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'payslips'
                      and column_name = 'basic_amount') as ok,
  case
    when to_regprocedure('public.remove_staff_adjustment(uuid)') is null
      then 'remove_staff_adjustment missing — apply 0019 first'
    when exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'payslips'
                   and column_name = 'basic_amount')
      then 'payslips.basic_amount still present — 0019 has not finished'
    else 'payroll is on the simplified model'
  end as detail

union all
select
  '02. 0020 not applied yet',
  to_regclass('public.salary_payments') is null,
  case
    when to_regclass('public.salary_payments') is null
      then 'salary_payments does not exist — 0020 has not run'
    else 'already applied; skip to 0020_verify.sql'
  end

union all
-- ---------------------------------------------------------------------------
-- Informational — what is already on file, all of which is kept
-- ---------------------------------------------------------------------------
select
  '03. Staff on the roll',
  true,
  coalesce((select count(*)::text || ' profile(s); two nullable columns are '
            || 'added and nothing is rewritten' from public.profiles), '0')

union all
select
  '04. Salaries on file (kept)',
  true,
  coalesce((select count(*)::text || ' salary structure(s)'
            from public.salary_structures), '0')

union all
select
  '05. Payslips on file (kept)',
  true,
  coalesce((select count(*)::text || ' payslip(s); each gains a paid and an '
            || 'outstanding figure, both starting at zero paid'
            from public.payslips), '0')

union all
select
  '06. Advances on file (kept)',
  true,
  coalesce((select count(*)::text || ' advance transaction(s); the ledger is '
            || 'not touched' from public.advance_transactions), '0')

union all
-- A finalised month with payslips becomes payable the moment this lands, which
-- is the point — but worth knowing before, so nobody is surprised by a screen
-- that suddenly asks to be paid.
select
  '07. Months that become payable immediately',
  true,
  coalesce((select count(*)::text || ' finalised month(s) will show as unpaid '
            || 'and can be paid as soon as this is applied'
            from public.payroll_periods where status = 'FINALISED'), '0')

order by 1;
