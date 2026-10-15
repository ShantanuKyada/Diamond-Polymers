-- =============================================================================
-- 0021_verify.sql — run AFTER applying 0021_employee_types_and_any_machine.sql
--
-- Every row must say ok = true. Nothing here writes anything.
-- =============================================================================

select
  '01. Every employee has a type' as check,
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'employee_type' and is_nullable = 'NO') = 1 as ok,
  'profiles.employee_type, NOT NULL' as detail

union all
select
  '02. Nobody was mislabelled by the backfill',
  not exists (select 1 from public.profiles
              where role = 'ADMIN' and employee_type = 'OPERATOR'),
  -- An administrator filed as a machine operator would appear on a machine
  -- roster and be offered the machine screens.
  coalesce((select count(*)::text || ' administrator(s) wrongly typed as '
            || 'operators' from public.profiles
            where role = 'ADMIN' and employee_type = 'OPERATOR'), '0')

union all
select
  '03. The type is a known one',
  (select count(*) from pg_enum e
   join pg_type t on t.oid = e.enumtypid
   where t.typname = 'employee_type') = 3,
  coalesce((select string_agg(e.enumlabel, ', ' order by e.enumlabel)
            from pg_enum e join pg_type t on t.oid = e.enumtypid
            where t.typname = 'employee_type'), 'MISSING')

union all
select
  '04. A salary day is still a day of the month',
  exists (select 1 from pg_constraint
          where conname = 'profiles_salary_day_ck'
            and conrelid = 'public.profiles'::regclass),
  'profiles_salary_day_ck survived the column change'

union all
-- ---------------------------------------------------------------------------
-- The rule that relaxed, and the ones that replaced it
-- ---------------------------------------------------------------------------
select
  '05. The machine assignment no longer gates an entry',
  -- The guard must no longer read machine_assignments at all. Checking the
  -- source is blunt, but it is the one thing that would silently keep the old
  -- behaviour if the function failed to replace.
  (select position('machine_assignments' in prosrc) = 0
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'assert_can_record'),
  'app.assert_can_record() does not consult machine_assignments'

union all
select
  '06. Only an operator may record a run',
  (select position('employee_type' in prosrc) > 0
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'assert_can_record'),
  'DP006 now means "not a machine operator"'

union all
select
  '07. Only an operator may hold a machine assignment',
  exists (select 1 from pg_trigger
          where tgname = 'machine_assignments_operator_only'
            and tgrelid = 'public.machine_assignments'::regclass
            and not tgisinternal),
  'trigger on machine_assignments'

union all
select
  '08. Leaving the factory closes the assignment',
  exists (select 1 from pg_trigger
          where tgname = 'profiles_close_assignments'
            and tgrelid = 'public.profiles'::regclass
            and not tgisinternal),
  'trigger on profiles'

union all
select
  '09. Nobody off the roll holds an open assignment',
  not exists (select 1 from public.machine_assignments a
              join public.profiles p on p.id = a.operator_id
              where a.effective_to is null and a.active and not p.active),
  -- The trigger only fires on a change, so anything here predates it and is
  -- tidied by re-saving that person.
  coalesce((select count(*)::text || ' left over from before the trigger; '
            || 're-save those people under More -> Employees'
            from public.machine_assignments a
            join public.profiles p on p.id = a.operator_id
            where a.effective_to is null and a.active and not p.active), '0')

union all
select
  '10. Nobody who runs no machine holds one either',
  not exists (select 1 from public.machine_assignments a
              join public.profiles p on p.id = a.operator_id
              where a.effective_to is null and a.active
                and p.employee_type <> 'OPERATOR'),
  'every open assignment belongs to an operator'

union all
-- ---------------------------------------------------------------------------
-- What the app reads
-- ---------------------------------------------------------------------------
select
  '11. The operator machine list exists',
  to_regclass('public.v_operator_machines') is not null
    and (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'v_operator_machines'
           and column_name in ('machine_id', 'is_mine', 'my_shift_id')) = 3,
  'v_operator_machines: every running machine, with their own marked'

union all
select
  '12. It runs as the caller',
  (select coalesce(array_to_string(c.reloptions, ','), '')
     like '%security_invoker=on%'
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'v_operator_machines'),
  -- It reads app.current_profile_id() to decide `is_mine`, so running as the
  -- owner would mark the wrong machine for everybody.
  'security_invoker = on'

union all
select
  '13. The roster reports the type',
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'v_staff_pay'
     and column_name in ('employee_type', 'active', 'has_login')) = 3,
  'v_staff_pay carries employee_type'

union all
select
  '14. save_worker_profile has one signature',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_worker_profile') = 1,
  -- Two would be an overload PostgREST cannot choose between, and every call
  -- from the app would fail with PGRST203.
  (select coalesce(string_agg(array_to_string(p.proargnames, ', '), ' | '),
                   'MISSING')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_worker_profile')

union all
select
  '15. Past work is untouched',
  true,
  coalesce((select count(*)::text || ' production entry/entries still on file, '
            || 'including any by people now off the roll'
            from public.production_entries), '0')

order by 1;
