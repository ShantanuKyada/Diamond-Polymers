-- =============================================================================
-- 0022_verify.sql — run AFTER applying 0022_employee_roles_master.sql
--
-- Every row must say ok = true. Nothing here writes anything.
-- =============================================================================

select
  '01. Roles are a table the factory can add to' as check,
  to_regclass('public.employee_types') is not null as ok,
  coalesce((select count(*)::text || ' role(s) on file'
            from public.employee_types), '0') as detail

union all
select
  '02. The three that existed came across',
  (select count(*) from public.employee_types
   where code in ('OPERATOR', 'LABOURER', 'OFFICE')) = 3,
  coalesce((select string_agg(code, ', ' order by sort_order)
            from public.employee_types), 'none')

union all
select
  '03. Everybody points at a role',
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'employee_type_id' and is_nullable = 'NO') = 1
  and not exists (select 1 from public.profiles where employee_type_id is null),
  'profiles.employee_type_id, NOT NULL'

union all
select
  '04. Nobody changed role on the way across',
  -- The administrator was Office and the operators were Operator. If the
  -- backfill had missed, everybody would have landed on Operator.
  not exists (select 1 from public.profiles p
              join public.employee_types t on t.id = p.employee_type_id
              where p.role = 'ADMIN' and t.runs_machines),
  coalesce((select string_agg(t.code || ': ' || c.n, ', ' order by t.code)
            from (select employee_type_id, count(*)::text as n
                  from public.profiles group by employee_type_id) c
            join public.employee_types t on t.id = c.employee_type_id), 'none')

union all
select
  '05. The old enum is gone',
  -- One answer to "what roles exist" rather than two that can disagree.
  not exists (select 1 from pg_type where typname = 'employee_type')
  and not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles'
                    and column_name = 'employee_type'),
  'neither the type nor the column remains'

union all
select
  '06. A direct insert still works',
  exists (select 1 from pg_trigger
          where tgname = 'profiles_default_employee_type'
            and tgrelid = 'public.profiles'::regclass
            and not tgisinternal),
  -- NOT NULL with no default would turn every hand-written insert into an
  -- error about a column nobody has heard of. A column DEFAULT cannot hold a
  -- subquery, so it is a trigger.
  'profiles_default_employee_type fills it with Operator'

union all
select
  '07. Exactly one role is the built-in one',
  (select count(*) from public.employee_types where is_system) = 1
  and exists (select 1 from public.employee_types
              where is_system and code = 'OPERATOR' and runs_machines and active),
  coalesce((select string_agg(code, ', ') from public.employee_types
            where is_system), 'NONE')

union all
select
  '08. At least one role runs machines',
  exists (select 1 from public.employee_types where active and runs_machines),
  -- Without one, nobody in the factory could record production at all.
  coalesce((select string_agg(code, ', ' order by code)
            from public.employee_types where active and runs_machines), 'NONE')

union all
select
  '09. The guard asks the role, not a list of names',
  (select position('runs_machines' in prosrc) > 0
          and position('''OPERATOR''' in prosrc) = 0
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'assert_can_record'),
  'app.assert_can_record() reads employee_types.runs_machines'

union all
select
  '10. A role that stops running machines frees its people',
  exists (select 1 from pg_trigger
          where tgname = 'employee_types_close_assignments'
            and tgrelid = 'public.employee_types'::regclass
            and not tgisinternal),
  'trigger on employee_types'

union all
select
  '11. Nobody who runs no machine holds an assignment',
  not exists (select 1 from public.machine_assignments a
              join public.profiles p on p.id = a.operator_id
              join public.employee_types t on t.id = p.employee_type_id
              where a.effective_to is null and a.active
                and not t.runs_machines),
  'every open assignment belongs to a machine-running role'

union all
select
  '12. The two functions exist, one signature each',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('save_employee_type', 'save_worker_profile')) = 2,
  -- Two of either would be an overload PostgREST cannot choose between, and
  -- every call from the app would fail with PGRST203.
  coalesce((select string_agg(p.proname, ', ' order by p.proname)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('save_employee_type', 'save_worker_profile')),
           'NONE')

union all
select
  '13. save_worker_profile takes a role code, not an enum',
  (select array_to_string(proargtypes::regtype[], ',') like '%text%'
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_worker_profile'),
  (select array_to_string(proargnames, ', ')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_worker_profile')

union all
select
  '14. The roster reports the role by name',
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'v_staff_pay'
     and column_name in ('employee_type', 'employee_type_name',
                         'runs_machines')) = 3,
  'v_staff_pay carries the code, the name and what it can do'

union all
select
  '15. The roles screen can see who holds what',
  to_regclass('public.v_employee_types') is not null
    and (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'v_employee_types'
           and column_name in ('active_staff', 'total_staff', 'is_system')) = 3,
  'v_employee_types carries the counts that decide whether a role can retire'

union all
select
  '16. Everybody signed in can read the roles',
  exists (select 1 from pg_policies
          where schemaname = 'public' and tablename = 'employee_types'
            and cmd = 'SELECT'),
  -- The app needs the list to render a profile. Writing is the RPC's job, and
  -- there is deliberately no INSERT, UPDATE or DELETE policy.
  (select count(*)::text || ' policy/policies, select only'
   from pg_policies
   where schemaname = 'public' and tablename = 'employee_types')

order by 1;
