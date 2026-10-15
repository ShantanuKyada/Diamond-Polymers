-- =============================================================================
-- 0021_preflight.sql — run BEFORE applying 0021_employee_types_and_any_machine.sql
--
-- This migration adds a column, two triggers and a view, and relaxes one rule.
-- It drops no columns and deletes no rows.
--
-- Rows 1 and 2 must say true. The rest are informational, but row 05 is worth
-- reading twice: it tells you how many people are about to be able to record on
-- machines they are not assigned to, which is the point of the change.
--
-- Paste into the Supabase SQL editor and run. Nothing here writes anything.
-- =============================================================================

select
  '01. Migration 0020 applied' as check,
  to_regclass('public.salary_payments') is not null as ok,
  case
    when to_regclass('public.salary_payments') is null
      then 'salary_payments missing — apply 0020 first'
    else 'payroll can record payments, so 0020 is in'
  end as detail

union all
select
  '02. 0021 not applied yet',
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles'
                and column_name = 'employee_type'),
  case
    when not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'profiles'
                       and column_name = 'employee_type')
      then 'profiles.employee_type does not exist — 0021 has not run'
    else 'already applied; skip to 0021_verify.sql'
  end

union all
-- ---------------------------------------------------------------------------
-- What the backfill will do
--
-- Everybody gets a type from what their row already says: an ADMIN becomes
-- OFFICE, everybody else becomes OPERATOR. Nobody is labelled something they
-- are not, and nothing is defaulted over the top of a real answer.
-- ---------------------------------------------------------------------------
select
  '03. Will be filed as office staff',
  true,
  coalesce((select count(*)::text || ' administrator(s) -> OFFICE'
            from public.profiles where role = 'ADMIN'), '0')

union all
select
  '04. Will be filed as machine operators',
  true,
  coalesce((select count(*)::text || ' other profile(s) -> OPERATOR. Change '
            || 'any labourers afterwards under More -> Employees.'
            from public.profiles where role <> 'ADMIN'), '0')

union all
-- ---------------------------------------------------------------------------
-- The rule that relaxes
-- ---------------------------------------------------------------------------
select
  '05. Operators who may record anywhere afterwards',
  true,
  coalesce((select count(*)::text || ' active operator(s). Until now each could '
            || 'only record on their assigned machine; afterwards any of them '
            || 'can record on any machine, and the assignment becomes the '
            || 'default on the form.'
            from public.profiles where active and role = 'OPERATOR'), '0')

union all
select
  '06. Open machine assignments (kept)',
  true,
  coalesce((select count(*)::text || ' open assignment(s); kept as the default '
            || 'on the entry forms and as the history behind past production'
            from public.machine_assignments
            where effective_to is null and active), '0')

union all
-- An open assignment belonging to somebody already off the roll is exactly
-- what the new trigger closes — but it only fires on a change, so these stay
-- until somebody is edited. Worth knowing rather than discovering.
select
  '07. Open assignments held by people already off the roll',
  true,
  coalesce((select count(*)::text || ' — the new trigger closes an assignment '
            || 'when somebody is deactivated, but it does not reach back. '
            || 'Re-save those people under More -> Employees to tidy them.'
            from public.machine_assignments a
            join public.profiles p on p.id = a.operator_id
            where a.effective_to is null and a.active and not p.active), '0')

order by 1;
