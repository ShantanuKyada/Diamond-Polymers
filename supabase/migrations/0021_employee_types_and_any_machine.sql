-- =============================================================================
-- 0021_employee_types_and_any_machine.sql — who works here, and where (A40)
--
-- Three changes the factory asked for, and one gap they exposed:
--
--   1. An operator may work on ANY machine. The assignment stops being a
--      restriction and becomes a default.
--   2. Staff have a TYPE. Operators run machines; labourers are on the payroll
--      and nothing else.
--   3. Deactivating somebody who leaves closes their open machine assignment,
--      which nothing did before.
--
-- WHY THE ASSIGNMENT SURVIVES AT ALL
--
-- The obvious reading of "operators should be able to work on any machine" is
-- to delete machine_assignments. That would be wrong twice over: it is the
-- history of who ran what, which the reports use, and it is the best guess for
-- which machine an operator is standing at right now. So it stays, and the app
-- offers it pre-selected. What goes is its power to refuse an entry.
--
-- ROLE IS NOT TYPE
--
-- `profiles.role` is about what somebody may see in the app — an ADMIN sees the
-- factory, an OPERATOR sees their own work. That is a different question from
-- what they do for a living, which is what the factory was asking about. A
-- labourer needs no login at all; an administrator is not a machine operator.
-- Conflating the two would mean a labourer could only be put on the payroll by
-- making them an app operator.
--
-- So `employee_type` is a new column, and the existing rows are backfilled from
-- `role` rather than defaulted: the administrator on file is OFFICE, and the
-- four operators are OPERATOR. Nobody is labelled something they are not.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- employee_type
--
-- OFFICE is here so the administrator's own record is not filed as a machine
-- operator. The factory named operators and labourers; this leaves room for the
-- third kind that already exists on their roll.
-- -----------------------------------------------------------------------------

do $mig$ begin
  create type public.employee_type as enum ('OPERATOR', 'LABOURER', 'OFFICE');
exception when duplicate_object then null; end $mig$;

alter table public.profiles
  add column if not exists employee_type public.employee_type;

-- Backfilled from what the row already says about itself, then made NOT NULL.
-- A default of OPERATOR applied to everybody would have quietly told the
-- factory that their administrator runs a machine.
update public.profiles
set employee_type = case when role = 'ADMIN' then 'OFFICE'::public.employee_type
                         else 'OPERATOR'::public.employee_type end
where employee_type is null;

alter table public.profiles
  alter column employee_type set default 'OPERATOR',
  alter column employee_type set not null;

comment on column public.profiles.employee_type is
  'What this person does: runs a machine, labours, or works in the office. '
  'Separate from `role`, which is what they may see in the app.';

create index if not exists profiles_employee_type_idx
  on public.profiles (employee_type, active);

-- =============================================================================
-- An operator may record on any machine
--
-- The only rule left is the one that matters: you record your own work, not
-- somebody else's. Which machine you are standing at is now a fact you report,
-- not a permission you hold.
--
-- DP006 stays, with a narrower meaning. It used to say "you are not assigned to
-- that machine"; it now says "you are not a machine operator", which is the one
-- remaining reason a person may not record a run. Same code, same kind of
-- refusal, and the app already maps it to an authorisation failure.
-- =============================================================================

create or replace function app.assert_can_record(p_operator_id uuid, p_machine_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller uuid := app.require_profile();
  v_type   public.employee_type;
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

  select employee_type into v_type
  from public.profiles where id = p_operator_id;

  -- A labourer is on the payroll and nothing else. They have no machine work to
  -- record, so an entry from one is a mistake worth naming rather than storing.
  if v_type is distinct from 'OPERATOR' then
    raise exception using
      errcode = 'DP006',
      message = 'Only machine operators can record production or material. '
                'Ask an administrator if this is wrong.',
      detail  = json_build_object('operator_id', p_operator_id,
                                  'employee_type', v_type)::text;
  end if;

  -- Deliberately NOT checked: whether this operator is assigned to this
  -- machine. The factory moves people between machines during a shift, and the
  -- assignment is now a default on the form rather than a gate here (A40).
  return v_caller;
end;
$fn$;

-- =============================================================================
-- Only an operator can hold a machine assignment
--
-- Assignments are written straight to the table by an administrator under RLS,
-- not through an RPC, so the rule lives in a trigger. Anywhere else and it
-- would hold for one write path and not the other.
-- =============================================================================

create or replace function app.assignment_requires_operator()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_type   public.employee_type;
  v_active boolean;
  v_name   text;
begin
  select employee_type, active, name
  into v_type, v_active, v_name
  from public.profiles where id = new.operator_id;

  if v_type is distinct from 'OPERATOR' then
    raise exception using
      errcode = 'DP005',
      message = format('%s is not a machine operator, so they cannot be '
                       'assigned to a machine.', coalesce(v_name, 'That person')),
      detail  = json_build_object('operator_id', new.operator_id,
                                  'employee_type', v_type)::text;
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

drop trigger if exists machine_assignments_operator_only on public.machine_assignments;
create trigger machine_assignments_operator_only
  before insert on public.machine_assignments
  for each row execute function app.assignment_requires_operator();

-- =============================================================================
-- Leaving the factory closes the assignment
--
-- Deactivating somebody left their open assignment open, so a machine went on
-- showing a manned operator who had left. The record is not deleted — the
-- assignment is closed with an end date, which is how every other period in
-- this schema ends.
--
-- Changing employee_type away from OPERATOR closes it for the same reason: a
-- person who no longer runs machines is not assigned to one.
-- =============================================================================

create or replace function app.close_assignments_when_inactive()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
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
  after update of active, employee_type on public.profiles
  for each row
  when (
    (old.active and not new.active)
    or (old.employee_type = 'OPERATOR' and new.employee_type <> 'OPERATOR')
  )
  execute function app.close_assignments_when_inactive();

-- =============================================================================
-- save_worker_profile — now carries the type
--
-- Dropped before it is recreated: PostgREST binds by name, and the old
-- ten-argument form left in place would make an overload it cannot choose
-- between.
-- =============================================================================

drop function if exists public.save_worker_profile(
  text, text, public.user_role, boolean, uuid, text, date, smallint, numeric, date);

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
  p_employee_type   public.employee_type default 'OPERATOR'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin   uuid := app.require_admin();
  v_id      uuid := p_id;
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

  -- An administrator who can see the whole factory is not a floor worker, and
  -- the app's two sides are chosen by `role`. Letting the two disagree would
  -- put an administrator on a machine roster.
  if p_role = 'ADMIN' and p_employee_type = 'OPERATOR' then
    raise exception using
      errcode = 'DP005',
      message = 'An administrator cannot also be a machine operator. Choose '
                'Office, or make them an operator instead of an administrator.',
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
       employee_type)
    values
      (btrim(p_name), btrim(p_employee_code), p_role, coalesce(p_active, true),
       nullif(btrim(p_phone), ''), p_joined_on, p_salary_day,
       coalesce(p_employee_type, 'OPERATOR'))
    returning id into v_id;
  else
    -- Role, type, name and code are the admin's to change here; what is NOT
    -- touched is auth_user_id, which only link_profile_to_auth_user() may set.
    --
    -- Turning `active` off, or moving somebody off OPERATOR, closes their open
    -- machine assignment through the trigger above rather than here — so it
    -- happens however the row is written.
    update public.profiles
    set name          = btrim(p_name),
        employee_code = btrim(p_employee_code),
        role          = p_role,
        active        = coalesce(p_active, active),
        phone         = nullif(btrim(p_phone), ''),
        joined_on     = p_joined_on,
        salary_day    = p_salary_day,
        employee_type = coalesce(p_employee_type, employee_type)
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
      -- Nobody has set a salary for this person yet. The first one starts on
      -- their joining date where there is one, so the history begins where the
      -- employment did rather than on whatever day the form was filled in.
      v_salary := public.set_salary_structure(
        v_id, p_monthly_salary,
        coalesce(p_salary_from, p_joined_on, current_date), 'Set with profile');

    elsif v_current <> p_monthly_salary then
      -- A revision has to start after the period already open. Where the
      -- caller gave no date and today is not late enough, it starts tomorrow;
      -- back-dating a raise over a month that has been paid is not something
      -- this should do quietly.
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
    'salary',  v_salary
  );
end;
$fn$;

grant execute on function
  public.save_worker_profile(text, text, public.user_role, boolean, uuid, text,
                             date, smallint, numeric, date,
                             public.employee_type)
to authenticated;

-- =============================================================================
-- Read models carry the type
-- =============================================================================

drop view if exists public.v_staff_pay;
create view public.v_staff_pay with (security_invoker = on) as
select
  p.id                       as profile_id,
  p.employee_code,
  p.name                     as staff_name,
  p.role,
  p.employee_type,
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

-- Every machine an operator may work on, which is now all of them.
--
-- Exists so the app asks one question of the database rather than filtering a
-- master list and hoping the rule matches. `is_mine` is the assignment, kept as
-- a default for the form rather than a restriction (A40).
create or replace view public.v_operator_machines with (security_invoker = on) as
select
  m.id   as machine_id,
  m.code,
  m.name,
  m.status,
  a.id is not null as is_mine,
  a.shift_id       as my_shift_id,
  s.name           as my_shift_name
from public.machines m
left join public.machine_assignments a
  on a.machine_id = m.id
  and a.operator_id = app.current_profile_id()
  and a.effective_to is null
  and a.active
left join public.shifts s on s.id = a.shift_id
where m.active and m.status <> 'INACTIVE';

grant select on public.v_operator_machines to anon, authenticated, service_role;
