-- =============================================================================
-- 0020_worker_profiles_and_salary_payments.sql — paying the salary (A39)
--
-- 0019 worked out what a worker is owed. It had no way to record that they were
-- actually paid, so every payslip sat at "owed" forever and the factory kept the
-- real answer somewhere else.
--
-- This adds the missing half:
--
--     outstanding = net payable − what has been handed over
--
-- and with it the two profile fields the payroll needed and did not have: when
-- somebody joined, and which day of the month they are paid on.
--
-- THE ONE IDEA WORTH STATING
--
-- An advance and a salary payment are the same act — money handed to a worker —
-- separated only by when it happens. The factory described it exactly that way:
-- 5000 a month, 2000 taken mid-month, 3000 on salary day. So the two are not
-- modelled twice. An advance already reduces `net_payable` through the existing
-- advance ledger; `salary_payments` records what is handed over after that. Each
-- rupee appears in exactly one ledger, which is what makes double-counting
-- structurally impossible rather than merely unlikely.
--
--     monthly salary        5000   salary_structures
--     − deductions             0   staff_adjustments
--     − advance taken       2000   advance_transactions  (recovered on finalise)
--     = net payable         3000   payslips
--     − paid                3000   salary_payments       ← new
--     = outstanding            0
--
-- WHY PAYMENT NEEDS A FINALISED MONTH
--
-- A draft is rebuilt from scratch on every run, and its figures move. Allowing a
-- payment against a figure that can still change is how a system ends up paying
-- against one number and reporting another. Finalising is the moment the month's
-- numbers are agreed; paying comes after. `salary_payments.payslip_id` is
-- ON DELETE RESTRICT so that if that rule were ever broken by a later change,
-- the draft rebuild would fail loudly instead of deleting payment history.
--
-- Nothing in 0019 is replaced. Every table, function and policy it created still
-- does what it did; this only adds, and widens three read models.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The two profile fields payroll needed
--
-- Both nullable, and deliberately so. The staff already on the roll have no
-- recorded joining date, and inventing one would put a false fact in a record
-- the factory may rely on. A null salary day means "no fixed day" — which is
-- true today, and is reported as such rather than defaulted to the 1st.
-- -----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists joined_on  date,
  add column if not exists salary_day smallint;

do $mig$ begin
  alter table public.profiles
    add constraint profiles_salary_day_ck
      check (salary_day is null or salary_day between 1 and 31);
exception when duplicate_object then null; end $mig$;

do $mig$ begin
  alter table public.profiles
    add constraint profiles_joined_on_ck
      check (joined_on is null or joined_on >= date '1970-01-01');
exception when duplicate_object then null; end $mig$;

comment on column public.profiles.joined_on is
  'The day this person joined the factory. Null for staff who were already on '
  'the roll when the field was added.';
comment on column public.profiles.salary_day is
  'Day of the month this person is paid on, 1-31. Null means no fixed day. A '
  'day past the end of a short month is reported as that month''s last day.';

-- -----------------------------------------------------------------------------
-- salary_payments — money actually handed over
--
-- Append-only, like every other ledger here. A mistake is corrected by a
-- reversing row that points at what it reverses, never by an edit: the question
-- "what did we pay this worker in October" has to keep the same answer a year
-- from now, including the wrong payment and its correction.
-- -----------------------------------------------------------------------------

create table if not exists public.salary_payments (
  id          uuid primary key default gen_random_uuid(),
  -- RESTRICT, not CASCADE: see the header. A draft rebuild deletes payslips,
  -- and that must never be able to take payment history with it.
  payslip_id  uuid not null references public.payslips (id) on delete restrict,
  -- SIGNED: positive pays, negative reverses an earlier payment.
  amount      numeric(12, 2) not null check (amount <> 0),
  paid_on     date not null default current_date,
  -- Free text, not an enum. The factory pays cash today and nobody has said
  -- what the full list of methods will be; an enum would be a guess that needs
  -- a migration to correct.
  method      text check (method is null or length(btrim(method)) > 0),
  reverses    uuid references public.salary_payments (id),
  client_ref  uuid unique,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now(),
  remarks     text
);

create index if not exists salary_payments_payslip_idx
  on public.salary_payments (payslip_id, paid_on);

-- One reversal per payment, so a double-tap on "undo" cannot reverse twice.
create unique index if not exists salary_payments_one_reversal
  on public.salary_payments (reverses) where reverses is not null;

-- -----------------------------------------------------------------------------
-- The one line on a salary slip the factory may want to change
--
-- Blank by default. A slip prints a plain "Computer generated salary slip."
-- until somebody puts something better here, which is better than printing a
-- placeholder that looks like a mistake.
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description) values
  ('salary_slip_footer', '',
   'The note printed at the foot of a salary slip. Blank prints a plain '
   '"Computer generated salary slip."')
on conflict (key) do update set description = excluded.description;

-- =============================================================================
-- Helpers
-- =============================================================================

-- The day a month's salary falls due, given the day of the month somebody is
-- paid on. Somebody paid on the 31st is due on the 28th of February, not on a
-- date that does not exist.
create or replace function app.salary_due_on(p_month date, p_day smallint)
returns date
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select case
    when p_day is null then null
    else (date_trunc('month', p_month)
          + (least(p_day,
                   extract(day from (date_trunc('month', p_month)
                                     + interval '1 month - 1 day'))::smallint) - 1)
            * interval '1 day')::date
  end;
$fn$;

-- What a payslip has been paid, and therefore what is left on it.
create or replace function app.payslip_paid(p_payslip_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(sum(amount), 0)::numeric(12, 2)
  from public.salary_payments where payslip_id = p_payslip_id;
$fn$;

-- =============================================================================
-- record_salary_payment — hand over money against an agreed payslip
-- =============================================================================

create or replace function public.record_salary_payment(
  p_payslip_id uuid,
  p_amount     numeric,
  p_client_ref uuid,
  p_paid_on    date default current_date,
  p_method     text default null,
  p_remarks    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin   uuid := app.require_admin();
  v_slip    public.payslips;
  v_status  public.payroll_status;
  v_month   date;
  v_name    text;
  v_code    text;
  v_paid    numeric(12, 2);
  v_left    numeric(12, 2);
  v_id      uuid;
begin
  -- Idempotency first, before any validation: a retry of a payment that already
  -- landed must return the same answer, not a complaint about the amount.
  select id into v_id from public.salary_payments where client_ref = p_client_ref;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'duplicate', true,
                              'paid', app.payslip_paid(p_payslip_id));
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'The payment must be greater than zero.',
      detail  = '{"field":"amount"}';
  end if;

  -- Lock the payslip, so two administrators paying the same person at the same
  -- moment cannot both see the same amount outstanding and both pay it.
  select * into v_slip from public.payslips where id = p_payslip_id for update;

  if v_slip.id is null then
    raise exception using
      errcode = 'DP005',
      message = 'That payslip does not exist.',
      detail  = '{"field":"payslip_id"}';
  end if;

  select pp.status, pp.period_month into v_status, v_month
  from public.payroll_periods pp where pp.id = v_slip.payroll_period_id;

  select p.name, p.employee_code into v_name, v_code
  from public.profiles p where p.id = v_slip.profile_id;

  if v_status <> 'FINALISED' then
    raise exception using
      errcode = 'DP005',
      message = format('Payroll for %s has not been finalised yet, so there is '
                       'nothing agreed to pay against. Finalise the month '
                       'first.', to_char(v_month, 'Mon YYYY')),
      detail  = json_build_object('period_month', v_month,
                                  'status', v_status)::text;
  end if;

  v_paid := app.payslip_paid(p_payslip_id);
  v_left := v_slip.net_payable - v_paid;

  if p_amount > v_left then
    raise exception using
      errcode = 'DP013',
      message = format('%s (%s) has %s left on %s, and this payment is %s. '
                       'Pay the remainder or less.',
                       v_name, v_code,
                       to_char(v_left, 'FM999999990.00'),
                       to_char(v_month, 'Mon YYYY'),
                       to_char(p_amount, 'FM999999990.00')),
      detail  = json_build_object('payslip_id', p_payslip_id,
                                  'net_payable', v_slip.net_payable,
                                  'already_paid', v_paid,
                                  'outstanding', v_left)::text;
  end if;

  insert into public.salary_payments
    (payslip_id, amount, paid_on, method, client_ref, created_by, remarks)
  values
    (p_payslip_id, p_amount, coalesce(p_paid_on, current_date),
     nullif(btrim(p_method), ''), p_client_ref, v_admin, p_remarks)
  returning id into v_id;

  v_paid := v_paid + p_amount;

  return jsonb_build_object(
    'id',          v_id,
    'duplicate',   false,
    'profile_id',  v_slip.profile_id,
    'net_payable', v_slip.net_payable,
    'paid',        v_paid,
    'outstanding', v_slip.net_payable - v_paid,
    'settled',     v_slip.net_payable - v_paid <= 0
  );
end;
$fn$;

-- =============================================================================
-- reverse_salary_payment — undo a payment without erasing it
-- =============================================================================

create or replace function public.reverse_salary_payment(
  p_payment_id uuid,
  p_client_ref uuid,
  p_remarks    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_row   public.salary_payments;
  v_id    uuid;
begin
  select id into v_id from public.salary_payments where client_ref = p_client_ref;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;

  select * into v_row from public.salary_payments where id = p_payment_id for update;

  if v_row.id is null then
    raise exception using
      errcode = 'DP005',
      message = 'That payment does not exist.',
      detail  = '{"field":"payment_id"}';
  end if;

  if v_row.amount < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'That row is itself a reversal and cannot be reversed again.',
      detail  = '{"field":"payment_id"}';
  end if;

  if exists (select 1 from public.salary_payments where reverses = p_payment_id) then
    raise exception using
      errcode = 'DP005',
      message = 'That payment has already been reversed.',
      detail  = '{"field":"payment_id"}';
  end if;

  insert into public.salary_payments
    (payslip_id, amount, paid_on, method, reverses, client_ref, created_by, remarks)
  values
    (v_row.payslip_id, -v_row.amount, current_date, v_row.method, p_payment_id,
     p_client_ref, v_admin,
     coalesce(p_remarks, format('Reverses payment of %s on %s',
                                to_char(v_row.amount, 'FM999999990.00'),
                                to_char(v_row.paid_on, 'DD Mon YYYY'))))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'duplicate', false,
                            'reversed', p_payment_id,
                            'amount', -v_row.amount,
                            'paid', app.payslip_paid(v_row.payslip_id));
end;
$fn$;

-- =============================================================================
-- save_worker_profile — one admin action, one transaction
--
-- The profile editor now carries a monthly salary, which lives in an
-- effective-dated table rather than on the row. Doing that as two calls from the
-- app would let the profile save and the salary fail, leaving a worker on the
-- roll at the wrong money with nothing to say why. So it is one function.
--
-- The salary is only touched when p_monthly_salary is supplied and differs from
-- what is already in force. Re-saving a profile without touching the salary
-- field must not write a new salary_structures row — that would litter the
-- history with no-op revisions and make a real raise hard to find.
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
  p_salary_from     date default null
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
      (name, employee_code, role, active, phone, joined_on, salary_day)
    values
      (btrim(p_name), btrim(p_employee_code), p_role, coalesce(p_active, true),
       nullif(btrim(p_phone), ''), p_joined_on, p_salary_day)
    returning id into v_id;
  else
    -- Role, login and employee code are the admin's to change here; what is NOT
    -- touched is auth_user_id, which only link_profile_to_auth_user() may set.
    update public.profiles
    set name          = btrim(p_name),
        employee_code = btrim(p_employee_code),
        role          = p_role,
        active        = coalesce(p_active, active),
        phone         = nullif(btrim(p_phone), ''),
        joined_on     = p_joined_on,
        salary_day    = p_salary_day
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

-- =============================================================================
-- Read models
-- =============================================================================

drop view if exists public.v_salary_payments;
drop view if exists public.v_salary_advances;
drop view if exists public.v_payroll_summary;
drop view if exists public.v_payslips;
drop view if exists public.v_staff_pay;

-- A payslip, and where it stands.
--
-- `advance_recovered` is what the worker already took during the month, so the
-- three figures the factory asked to see — salary, advance, remaining — are
-- monthly_salary, advance_recovered and net_payable. `paid_amount` and
-- `outstanding` carry it the rest of the way to settled.
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
  p.phone,
  p.joined_on,
  p.salary_day,
  app.salary_due_on(pp.period_month, p.salary_day) as salary_due_on,
  s.monthly_salary,
  s.deductions_amount,
  s.advance_recovered,
  s.net_payable,
  coalesce(pay.paid, 0)                   as paid_amount,
  s.net_payable - coalesce(pay.paid, 0)   as outstanding,
  case
    -- A draft is not payable: its figures can still change. Said plainly so a
    -- blank "unpaid" cannot be read as "we owe this and have not paid it".
    when pp.status <> 'FINALISED'                  then 'DRAFT'
    -- Nothing left to hand over. This is also the honest answer when the whole
    -- salary went out as advances during the month: it was paid, just earlier.
    when s.net_payable - coalesce(pay.paid, 0) <= 0 then 'PAID'
    when coalesce(pay.paid, 0) > 0                  then 'PARTIAL'
    else                                                 'UNPAID'
  end as payment_status,
  s.created_at
from public.payslips s
join public.payroll_periods pp on pp.id = s.payroll_period_id
join public.profiles p on p.id = s.profile_id
left join (
  select payslip_id, sum(amount) as paid
  from public.salary_payments group by payslip_id
) pay on pay.payslip_id = s.id;

-- Every payment against a payslip, newest first. The slip prints this, so a
-- reversal has to be visible as a row rather than as an absence.
create view public.v_salary_payments with (security_invoker = on) as
select
  sp.id,
  sp.payslip_id,
  s.profile_id,
  p.employee_code,
  p.name          as staff_name,
  pp.period_month,
  sp.amount,
  sp.paid_on,
  sp.method,
  sp.reverses,
  sp.reverses is not null as is_reversal,
  exists (select 1 from public.salary_payments r where r.reverses = sp.id)
                  as is_reversed,
  sp.remarks,
  sp.created_at
from public.salary_payments sp
join public.payslips s on s.id = sp.payslip_id
join public.payroll_periods pp on pp.id = s.payroll_period_id
join public.profiles p on p.id = s.profile_id;

-- Advances as the slip needs them: one row per advance, with its date, against
-- the month it was taken in. The ledger is signed, so an ISSUED row is a
-- positive and a recovery is not an advance.
create view public.v_salary_advances with (security_invoker = on) as
select
  t.id,
  t.profile_id,
  p.employee_code,
  p.name       as staff_name,
  date_trunc('month', t.entry_date)::date as period_month,
  t.entry_date,
  t.amount,
  t.remarks,
  t.created_at
from public.advance_transactions t
join public.profiles p on p.id = t.profile_id
where t.transaction_type = 'ISSUED';

-- One row per month: what the factory owes, what it has handed over, and
-- whether the month is still open.
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
  coalesce(sum(v.paid_amount), 0)           as paid_total,
  coalesce(sum(v.outstanding), 0)           as outstanding_total,
  count(s.id) filter (where v.payment_status = 'PAID')    as paid_count,
  count(s.id) filter (where v.payment_status = 'PARTIAL') as partial_count,
  count(s.id) filter (where v.payment_status = 'UNPAID')  as unpaid_count,
  pp.finalised_at
from public.payroll_periods pp
left join public.payslips s on s.payroll_period_id = pp.id
left join public.v_payslips v on v.id = s.id
where app.is_admin()
group by pp.id, pp.period_month, pp.status, pp.finalised_at;

-- Everyone with the salary they are on, when they joined, which day they are
-- paid, and what they have drawn against it. One row per person, and the only
-- query the worker roster or the Salaries tab needs.
--
-- Inactive staff are included, and flagged, because an administrator managing
-- profiles has to be able to find somebody they took off the roll. Callers that
-- are about paying people — the Salaries tab, the advance picker — filter to
-- `active` themselves. A second view differing only in that predicate would be
-- one edit away from disagreeing with this one.
--
-- The salary shown is the one in force today, not the latest row on file: a
-- raise dated next month is not what somebody is paid this month. Any such
-- raise is reported separately rather than hidden, so the roster can say both.
--
-- A worker sees only their own row. Under security_invoker alone they would see
-- every colleague listed with a blank salary, since profiles is readable but
-- salary_structures is not: no leak, but a roster that looks like everybody is
-- unpaid.
--
-- `has_login` rather than auth_user_id: the roster needs to show that somebody
-- cannot sign in, which is a different problem from being off the roll. It does
-- not need the id, so it is not handed out.
create view public.v_staff_pay with (security_invoker = on) as
select
  p.id                       as profile_id,
  p.employee_code,
  p.name                     as staff_name,
  p.role,
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
-- At most one open-ended row per person, by unique index.
left join public.salary_structures open
  on open.profile_id = p.id and open.effective_to is null
left join public.staff_advance_balance b
  on b.profile_id = p.id
where app.is_admin() or p.id = app.current_profile_id();

-- =============================================================================
-- Row level security
--
-- Same rule as the rest of payroll: yours, or all of them if you are an
-- administrator. Append-only through the RPCs — no INSERT, UPDATE or DELETE
-- policy exists, so even an administrator cannot rewrite a payment by hand.
-- =============================================================================

alter table public.salary_payments enable row level security;

drop policy if exists salary_payments_read on public.salary_payments;
create policy salary_payments_read on public.salary_payments
  for select to authenticated
  using (
    exists (
      select 1 from public.payslips s
      where s.id = payslip_id
        and (app.is_admin() or s.profile_id = app.current_profile_id())
    )
  );

grant select on public.salary_payments to anon, authenticated, service_role;

-- =============================================================================
-- Grants
-- =============================================================================

grant execute on function
  app.salary_due_on(date, smallint)
to authenticated;

grant execute on function
  public.record_salary_payment(uuid, numeric, uuid, date, text, text),
  public.reverse_salary_payment(uuid, uuid, text),
  public.save_worker_profile(text, text, public.user_role, boolean, uuid, text,
                             date, smallint, numeric, date)
to authenticated;
