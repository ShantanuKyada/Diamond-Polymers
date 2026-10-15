-- =============================================================================
-- 0022_employee_roles_master.sql — the factory names its own roles (A41)
--
-- 0021 gave staff a type, as a Postgres enum of three values: OPERATOR,
-- LABOURER, OFFICE. The factory wants to add their own — a supervisor, a
-- helper, a fitter — which an enum cannot do without a migration every time.
--
-- So the enum becomes a master table, like machines and pipe types already are.
--
-- THE ONE QUESTION A ROLE HAS TO ANSWER
--
-- Everything the system does with a type comes down to one thing: does this
-- person run machines? That decides whether they get the Material and
-- Production screens, whether they may be assigned to a machine, and whether
-- the database accepts a run from them.
--
-- So `runs_machines` is a column on the role, and the factory answers it when
-- they create one. Without it a new role would be a label with no meaning, and
-- the app would have to guess — or, worse, match on the name.
--
-- WHAT CANNOT BE TAKEN AWAY
--
-- `is_system` marks Operator. It cannot be deactivated and its `runs_machines`
-- cannot be turned off, because a factory with no machine-running role is one
-- where nobody can record production at all. Everything else about it — its
-- display name, its position in the list — is the factory's to change.
--
-- A role is never deleted, only deactivated, and only while nobody is on it.
-- Deleting one would orphan the history of everybody who ever held it.
-- =============================================================================

create table if not exists public.employee_types (
  id            uuid primary key default gen_random_uuid(),
  -- Stable, uppercase, and never edited after creation: the code is what the
  -- app and these migrations refer to, while `name` is what the factory reads.
  code          text not null unique
                check (code = upper(btrim(code)) and length(btrim(code)) > 0),
  name          text not null check (length(btrim(name)) > 0),
  description   text,
  -- The only thing the rest of the system asks about a role.
  runs_machines boolean not null default false,
  active        boolean not null default true,
  sort_order    integer not null default 100,
  -- Operator. Cannot be deactivated, and cannot stop running machines.
  is_system     boolean not null default false,
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists employee_types_active_idx
  on public.employee_types (active, sort_order);

-- The three that already existed, carried over with the same meanings.
insert into public.employee_types
  (code, name, description, runs_machines, sort_order, is_system)
values
  ('OPERATOR', 'Operator',
   'Runs a machine. Records material and production for whichever machine '
   'they are on.', true, 10, true),
  ('LABOURER', 'Labourer',
   'On the payroll. No machine work to record, so no machine screens.',
   false, 20, false),
  ('OFFICE', 'Office',
   'Works in the office rather than on the floor.', false, 30, false)
on conflict (code) do update
  set name = excluded.name,
      description = excluded.description,
      is_system = excluded.is_system;

-- -----------------------------------------------------------------------------
-- profiles points at a role rather than carrying an enum value
-- -----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists employee_type_id uuid references public.employee_types (id);

do $mig$
begin
  -- Backfilled from the enum column where it still exists, so nobody's type
  -- changes meaning on the way through.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'employee_type') then
    update public.profiles p
    set employee_type_id = t.id
    from public.employee_types t
    where t.code = p.employee_type::text
      and p.employee_type_id is null;
  end if;
end
$mig$;

-- Anybody still unset — there should be none — becomes an operator, which is
-- the default the old column carried.
update public.profiles
set employee_type_id = (select id from public.employee_types where code = 'OPERATOR')
where employee_type_id is null;

alter table public.profiles
  alter column employee_type_id set not null;

-- A default, so a direct insert into profiles still works.
--
-- It cannot be a column DEFAULT — Postgres will not take a subquery for one —
-- so it is a trigger. Without it, NOT NULL turns every hand-written insert,
-- including one an administrator types into the SQL editor, into an error
-- about a column they have never heard of.
create or replace function app.default_employee_type()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if new.employee_type_id is null then
    select id into new.employee_type_id
    from public.employee_types where code = 'OPERATOR';
  end if;
  return new;
end;
$fn$;

drop trigger if exists profiles_default_employee_type on public.profiles;
create trigger profiles_default_employee_type
  before insert on public.profiles
  for each row execute function app.default_employee_type();

create index if not exists profiles_employee_type_id_idx
  on public.profiles (employee_type_id, active);

-- =============================================================================
-- The guard, now asking the role rather than matching a literal
-- =============================================================================

-- Dropped first: its signature names the enum, which goes at the foot of this
-- file, and PostgREST cannot choose between two functions of one name.
drop function if exists public.save_worker_profile(
  text, text, public.user_role, boolean, uuid, text, date, smallint, numeric,
  date, public.employee_type);

create or replace function app.assert_can_record(p_operator_id uuid, p_machine_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller uuid := app.require_profile();
  v_runs   boolean;
  v_role   text;
begin
  -- Admin may record on behalf of any operator on any machine.
  if app.is_admin() then
    return v_caller;
  end if;

  if p_operator_id <> v_caller then
    raise exception using
      errcode = 'DP004',
      message = 'You can only record entries for yourself.',
      detail  = '{"reason":"operator_mismatch"}';
  end if;

  select t.runs_machines, t.name
  into v_runs, v_role
  from public.profiles p
  join public.employee_types t on t.id = p.employee_type_id
  where p.id = p_operator_id;

  -- Whether a role runs machines is the factory's answer, given when they
  -- created it, rather than a list of role names written into this function.
  if not coalesce(v_runs, false) then
    raise exception using
      errcode = 'DP006',
      message = format('%s is not a role that runs machines, so production and '
                       'material cannot be recorded. Ask an administrator if '
                       'this is wrong.', coalesce(v_role, 'That role')),
      detail  = json_build_object('operator_id', p_operator_id)::text;
  end if;

  -- Deliberately NOT checked: whether this operator is assigned to this
  -- machine. The assignment is a default on the form, not a gate here (A40).
  return v_caller;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Only somebody in a machine-running role may hold an assignment
-- -----------------------------------------------------------------------------

create or replace function app.assignment_requires_operator()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_runs   boolean;
  v_active boolean;
  v_name   text;
  v_role   text;
begin
  select t.runs_machines, p.active, p.name, t.name
  into v_runs, v_active, v_name, v_role
  from public.profiles p
  join public.employee_types t on t.id = p.employee_type_id
  where p.id = new.operator_id;

  if not coalesce(v_runs, false) then
    raise exception using
      errcode = 'DP005',
      message = format('%s is a %s, which does not run machines, so they '
                       'cannot be assigned to one.',
                       coalesce(v_name, 'That person'),
                       coalesce(v_role, 'role')),
      detail  = json_build_object('operator_id', new.operator_id)::text;
  end if;

  if not coalesce(v_active, false) then
    raise exception using
      errcode = 'DP005',
      message = format('%s is not on the roll, so they cannot be assigned to '
                       'a machine.', coalesce(v_name, 'That person')),
      detail  = json_build_object('operator_id', new.operator_id)::text;
  end if;

  return new;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Leaving, or moving to a role that does not run machines, closes the
-- assignment. Same rule as 0021; it now reads the role rather than the enum.
-- -----------------------------------------------------------------------------

create or replace function app.close_assignments_when_inactive()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_runs boolean;
begin
  select runs_machines into v_runs
  from public.employee_types where id = new.employee_type_id;

  if new.active and coalesce(v_runs, false) then
    return new;
  end if;

  update public.machine_assignments
  set effective_to = greatest(effective_from, current_date),
      active = false
  where operator_id = new.id
    and effective_to is null
    and active;

  return new;
end;
$fn$;

drop trigger if exists profiles_close_assignments on public.profiles;
create trigger profiles_close_assignments
  after update of active, employee_type_id on public.profiles
  for each row
  when (old.active is distinct from new.active
        or old.employee_type_id is distinct from new.employee_type_id)
  execute function app.close_assignments_when_inactive();

-- A role that stops running machines takes its people's assignments with it,
-- for the same reason: nobody who does not run a machine is assigned to one.
create or replace function app.close_assignments_for_role()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  update public.machine_assignments a
  set effective_to = greatest(a.effective_from, current_date),
      active = false
  from public.profiles p
  where p.id = a.operator_id
    and p.employee_type_id = new.id
    and a.effective_to is null
    and a.active;

  return new;
end;
$fn$;

drop trigger if exists employee_types_close_assignments on public.employee_types;
create trigger employee_types_close_assignments
  after update of runs_machines, active on public.employee_types
  for each row
  when ((old.runs_machines and not new.runs_machines)
        or (old.active and not new.active))
  execute function app.close_assignments_for_role();

-- =============================================================================
-- save_employee_type — the factory's own roles
-- =============================================================================

create or replace function public.save_employee_type(
  p_name          text,
  p_code          text default null,
  p_id            uuid default null,
  p_description   text default null,
  -- Null means "leave as it is", not "false". An edit that only changes a
  -- role's name must not quietly strip its ability to run machines, which is
  -- what a default of false did.
  p_runs_machines boolean default null,
  p_active        boolean default null,
  p_sort_order    integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_row   public.employee_types;
  v_code  text;
  v_held  integer;
  v_id    uuid;
begin
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A role needs a name.',
      detail  = '{"field":"name"}';
  end if;

  if p_id is null then
    -- A code is derived from the name when none is given, which is what an
    -- administrator typing "Supervisor" expects to happen.
    v_code := upper(btrim(coalesce(nullif(btrim(p_code), ''), p_name)));
    v_code := regexp_replace(v_code, '[^A-Z0-9]+', '_', 'g');
    v_code := btrim(v_code, '_');

    if length(v_code) = 0 then
      raise exception using
        errcode = 'DP005',
        message = 'That name has no letters or numbers in it to make a code '
                  'from. Give the role a different name.',
        detail  = '{"field":"name"}';
    end if;

    if exists (select 1 from public.employee_types where code = v_code) then
      raise exception using
        errcode = 'DP005',
        message = format('A role called %s already exists.', btrim(p_name)),
        detail  = json_build_object('field', 'name', 'code', v_code)::text;
    end if;

    insert into public.employee_types
      (code, name, description, runs_machines, active, sort_order, created_by)
    values
      (v_code, btrim(p_name), nullif(btrim(p_description), ''),
       -- A new role does not run machines unless the factory says so.
       coalesce(p_runs_machines, false), coalesce(p_active, true),
       coalesce(p_sort_order, 100), v_admin)
    returning id into v_id;

    return jsonb_build_object('id', v_id, 'code', v_code, 'created', true);
  end if;

  select * into v_row from public.employee_types where id = p_id for update;

  if v_row.id is null then
    raise exception using
      errcode = 'DP005',
      message = 'That role does not exist.',
      detail  = '{"field":"id"}';
  end if;

  -- The code is never edited: it is what this schema and the app refer to, and
  -- renaming it would quietly change what every existing profile means.
  -- The display name is free to change.

  if v_row.is_system then
    if p_active is not null and not p_active then
      raise exception using
        errcode = 'DP005',
        message = format('%s cannot be switched off. A factory with no role '
                         'that runs machines is one where nobody can record '
                         'production.', v_row.name),
        detail  = '{"field":"active"}';
    end if;
    if p_runs_machines is not null and not p_runs_machines then
      raise exception using
        errcode = 'DP005',
        message = format('%s has to keep running machines — it is the role the '
                         'factory falls back on.', v_row.name),
        detail  = '{"field":"runs_machines"}';
    end if;
  end if;

  if v_row.active and p_active is not null and not p_active then
    select count(*) into v_held
    from public.profiles
    where employee_type_id = v_row.id and active;

    if v_held > 0 then
      raise exception using
        errcode = 'DP005',
        message = format('%s people are on the %s role, so it cannot be '
                         'switched off. Move them to another role first.',
                         v_held, v_row.name),
        detail  = json_build_object('field', 'active', 'held_by', v_held)::text;
    end if;
  end if;

  update public.employee_types
  set name          = btrim(p_name),
      description   = nullif(btrim(p_description), ''),
      runs_machines = case when v_row.is_system then true
                           else coalesce(p_runs_machines, runs_machines) end,
      active        = case when v_row.is_system then true
                           else coalesce(p_active, active) end,
      sort_order    = coalesce(p_sort_order, sort_order),
      updated_at    = now()
  where id = p_id;

  return jsonb_build_object('id', p_id, 'code', v_row.code, 'created', false);
end;
$fn$;

-- =============================================================================
-- save_worker_profile — takes a role code rather than an enum value
-- =============================================================================

create or replace function public.save_worker_profile(
  p_name            text,
  p_employee_code   text,
  p_role            public.user_role,
  p_active          boolean,
  p_id              uuid default null,
  p_phone           text default null,
  p_joined_on       date default null,
  p_salary_day      smallint default null,
  p_monthly_salary  numeric default null,
  p_salary_from     date default null,
  p_employee_type   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin   uuid := app.require_admin();
  v_id      uuid := p_id;
  v_type    public.employee_types;
  v_current numeric(12, 2);
  v_open    public.salary_structures;
  v_from    date := coalesce(p_salary_from, current_date);
  v_salary  jsonb := null;
begin
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A name is required.',
      detail  = '{"field":"name"}';
  end if;

  if p_employee_code is null or length(btrim(p_employee_code)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A worker ID is required.',
      detail  = '{"field":"employee_code"}';
  end if;

  if p_salary_day is not null and p_salary_day not between 1 and 31 then
    raise exception using
      errcode = 'DP005',
      message = 'The salary day must be a day of the month, 1 to 31.',
      detail  = '{"field":"salary_day"}';
  end if;

  if p_joined_on is not null and p_joined_on > current_date + 1 then
    raise exception using
      errcode = 'DP005',
      message = 'A joining date cannot be in the future.',
      detail  = '{"field":"joined_on"}';
  end if;

  -- The role: the one given, the one they already have, or Operator.
  if p_employee_type is not null then
    select * into v_type from public.employee_types
    where code = upper(btrim(p_employee_type));

    if v_type.id is null then
      raise exception using
        errcode = 'DP005',
        message = format('There is no role called %s.', btrim(p_employee_type)),
        detail  = '{"field":"employee_type"}';
    end if;

    if not v_type.active then
      raise exception using
        errcode = 'DP005',
        message = format('The %s role has been switched off, so nobody new can '
                         'be put on it.', v_type.name),
        detail  = '{"field":"employee_type"}';
    end if;
  elsif v_id is not null then
    select t.* into v_type from public.employee_types t
    join public.profiles p on p.employee_type_id = t.id
    where p.id = v_id;
  end if;

  if v_type.id is null then
    select * into v_type from public.employee_types where code = 'OPERATOR';
  end if;

  -- An administrator who can see the whole factory is not a floor worker, and
  -- the app's two sides are chosen by `role`. Letting the two disagree would
  -- put an administrator on a machine roster.
  if p_role = 'ADMIN' and v_type.runs_machines then
    raise exception using
      errcode = 'DP005',
      message = format('An administrator cannot also be on a role that runs '
                       'machines. Choose a different role, or make them an '
                       'operator instead of an administrator.'),
      detail  = '{"field":"employee_type"}';
  end if;

  if exists (select 1 from public.profiles
             where btrim(employee_code) = btrim(p_employee_code)
               and (v_id is null or id <> v_id)) then
    raise exception using
      errcode = 'DP005',
      message = format('Worker ID %s is already used by somebody else.',
                       btrim(p_employee_code)),
      detail  = '{"field":"employee_code"}';
  end if;

  if v_id is null then
    insert into public.profiles
      (name, employee_code, role, active, phone, joined_on, salary_day,
       employee_type_id)
    values
      (btrim(p_name), btrim(p_employee_code), p_role, coalesce(p_active, true),
       nullif(btrim(p_phone), ''), p_joined_on, p_salary_day, v_type.id)
    returning id into v_id;
  else
    -- Turning `active` off, or moving somebody to a role that does not run
    -- machines, closes their open assignment through the trigger above — so it
    -- happens however the row is written.
    update public.profiles
    set name             = btrim(p_name),
        employee_code    = btrim(p_employee_code),
        role             = p_role,
        active           = coalesce(p_active, active),
        phone            = nullif(btrim(p_phone), ''),
        joined_on        = p_joined_on,
        salary_day       = p_salary_day,
        employee_type_id = v_type.id
    where id = v_id;

    if not found then
      raise exception using
        errcode = 'DP005',
        message = 'That worker does not exist.',
        detail  = '{"field":"id"}';
    end if;
  end if;

  if p_monthly_salary is not null then
    select * into v_open
    from public.salary_structures
    where profile_id = v_id and effective_to is null;

    v_current := v_open.monthly_salary;

    if v_current is null then
      v_salary := public.set_salary_structure(
        v_id, p_monthly_salary,
        coalesce(p_salary_from, p_joined_on, current_date), 'Set with profile');
    elsif v_current <> p_monthly_salary then
      if v_from <= v_open.effective_from then
        v_from := v_open.effective_from + 1;
      end if;
      v_salary := public.set_salary_structure(
        v_id, p_monthly_salary, v_from, 'Changed with profile');
    end if;
  end if;

  return jsonb_build_object(
    'id',      v_id,
    'created', p_id is null,
    'role',    v_type.code,
    'salary',  v_salary
  );
end;
$fn$;

-- =============================================================================
-- Read models
-- =============================================================================

-- Every role, with how many people are on it — which is what tells an
-- administrator whether one can be switched off.
create or replace view public.v_employee_types with (security_invoker = on) as
select
  t.id,
  t.code,
  t.name,
  t.description,
  t.runs_machines,
  t.active,
  t.sort_order,
  t.is_system,
  count(p.id) filter (where p.active)       as active_staff,
  count(p.id)                               as total_staff
from public.employee_types t
left join public.profiles p on p.employee_type_id = t.id
group by t.id;

drop view if exists public.v_staff_pay;
create view public.v_staff_pay with (security_invoker = on) as
select
  p.id                       as profile_id,
  p.employee_code,
  p.name                     as staff_name,
  p.role,
  t.code                     as employee_type,
  t.name                     as employee_type_name,
  t.runs_machines,
  p.phone,
  p.active,
  p.auth_user_id is not null as has_login,
  p.joined_on,
  p.salary_day,
  app.salary_due_on(current_date, p.salary_day) as next_due_on,
  today.id                   as salary_structure_id,
  today.monthly_salary,
  today.effective_from,
  case when open.effective_from > current_date then open.monthly_salary end
                             as upcoming_salary,
  case when open.effective_from > current_date then open.effective_from end
                             as upcoming_from,
  coalesce(b.outstanding, 0) as outstanding_advance
from public.profiles p
join public.employee_types t on t.id = p.employee_type_id
left join lateral (
  select st.*
  from public.salary_structures st
  where st.profile_id = p.id
    and st.effective_from <= current_date
    and (st.effective_to is null or st.effective_to >= current_date)
  order by st.effective_from desc
  limit 1
) today on true
left join public.salary_structures open
  on open.profile_id = p.id and open.effective_to is null
left join public.staff_advance_balance b
  on b.profile_id = p.id
where app.is_admin() or p.id = app.current_profile_id();

-- =============================================================================
-- Row level security
--
-- Roles are master data: everybody signed in may read them — the app needs the
-- list to render a profile — and only an administrator may write, through the
-- RPC above.
-- =============================================================================

alter table public.employee_types enable row level security;

drop policy if exists employee_types_read on public.employee_types;
create policy employee_types_read on public.employee_types
  for select to authenticated using (true);

grant select on public.employee_types to anon, authenticated, service_role;
grant select on public.v_employee_types to anon, authenticated, service_role;

grant execute on function
  public.save_employee_type(text, text, uuid, text, boolean, boolean, integer),
  public.save_worker_profile(text, text, public.user_role, boolean, uuid, text,
                             date, smallint, numeric, date, text)
to authenticated;

-- =============================================================================
-- The enum goes last
--
-- Nothing refers to it now: the column is replaced, both functions that named
-- it are rebuilt, and the triggers read the table. Dropping it means there is
-- one answer to "what roles exist" rather than two that can disagree.
-- =============================================================================

alter table public.profiles drop column if exists employee_type;
drop type if exists public.employee_type;
