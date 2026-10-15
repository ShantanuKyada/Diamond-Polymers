-- =============================================================================
-- 0022_preflight.sql — run BEFORE applying 0022_employee_roles_master.sql
--
-- 0021 gave staff a type as a Postgres enum of three values. 0022 turns that
-- into a master table the factory can add to.
--
-- Nothing is lost: every profile keeps the role it has, carried across by code.
-- The enum column is replaced by a reference and then dropped, which is the
-- only destructive step — and it is only destructive if the backfill missed
-- somebody, which row 04 checks for in advance.
--
-- Rows 1 and 2 must say true. Paste into the Supabase SQL editor and run.
-- Nothing here writes anything.
-- =============================================================================

select
  '01. Migration 0021 applied' as check,
  exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'profiles'
            and column_name = 'employee_type') as ok,
  case
    when exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles'
                   and column_name = 'employee_type')
      then 'profiles.employee_type present, so 0021 is in'
    else 'apply 0021 first'
  end as detail

union all
select
  '02. 0022 not applied yet',
  to_regclass('public.employee_types') is null,
  case
    when to_regclass('public.employee_types') is null
      then 'employee_types does not exist — 0022 has not run'
    else 'already applied; skip to 0022_verify.sql'
  end

union all
-- ---------------------------------------------------------------------------
-- What carries across
-- ---------------------------------------------------------------------------
-- Read through to_jsonb rather than naming the column: Postgres parses this
-- whole statement before running any of it, so naming a column 0022 has
-- already dropped would fail the script outright when somebody re-runs it to
-- confirm. Afterwards the key is simply absent.
select
  '03. People on each role today',
  true,
  coalesce((select string_agg(role_code || ': ' || n, ', ' order by role_code)
            from (select to_jsonb(p) ->> 'employee_type' as role_code,
                         count(*)::text as n
                  from public.profiles p
                  group by to_jsonb(p) ->> 'employee_type') c
            where role_code is not null),
           'already carried across to employee_types')

union all
select
  '04. Every role in use is one of the three carried over',
  not exists (select 1 from public.profiles p
              where to_jsonb(p) ->> 'employee_type' is not null
                and to_jsonb(p) ->> 'employee_type'
                  not in ('OPERATOR', 'LABOURER', 'OFFICE')),
  -- The backfill matches on the code. Anything outside these three would be
  -- carried across as Operator by the catch-all, which would be wrong rather
  -- than merely unhelpful — so it is worth knowing beforehand.
  coalesce((select count(*)::text || ' profile(s) on something else'
            from public.profiles p
            where to_jsonb(p) ->> 'employee_type' is not null
              and to_jsonb(p) ->> 'employee_type'
                not in ('OPERATOR', 'LABOURER', 'OFFICE')), '0')

union all
select
  '05. Machine assignments (kept)',
  true,
  coalesce((select count(*)::text || ' open assignment(s); unaffected'
            from public.machine_assignments
            where effective_to is null and active), '0')

order by 1;
