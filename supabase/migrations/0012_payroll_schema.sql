-- =============================================================================
-- 0012_payroll_schema.sql — Phase 8: attendance and payroll
--
-- The second of the two modules the factory asked for, and the only phase with
-- no database behind it until now.
--
-- SHAPE OF THE PROBLEM
--   * staff are on a MONTHLY salary, prorated by attendance;
--   * attendance is captured as a punch in and a punch out per day;
--   * overtime, advances, deductions and bonuses all apply.
--
-- THE RULES THAT ARE ASSUMPTIONS, NOT FACTS
--
--   1. UNMARKED DAYS ARE PAID. A day with no attendance row counts as worked.
--      Small factories mark exceptions — absence, leave — and say nothing about
--      an ordinary day. The opposite default would silently halve somebody's pay
--      the first month attendance is not filled in diligently, and underpaying a
--      worker is a worse failure than overpaying one. Configurable:
--      `payroll_unmarked_day_policy`.
--
--   2. PRORATION IS BY CALENDAR DAYS. Basic = monthly x payable days / days in
--      the month, so a fully present month pays exactly the monthly salary.
--      Configurable: `payroll_proration_basis`.
--
--   3. OVERTIME IS TWICE THE ORDINARY HOURLY RATE, derived as
--      monthly / 26 / standard hours per day, unless a per-person rate is set.
--      Twice is the statutory factory rate in India. Configurable.
--
-- Every one of these is read in exactly one place, `run_payroll()`, so the
-- factory can correct any of them without touching the schema.
--
-- MONEY IS LEDGERED THE SAME WAY STOCK IS. Advances get a balance row that is
-- the lock target and an append-only transaction table carrying previous and
-- resulting outstanding, with a CHECK that they agree. An advance cannot be
-- recovered twice by two concurrent payroll runs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

do $mig$ begin
  create type public.attendance_status as enum (
    'PRESENT',      -- a full day worked
    'HALF_DAY',     -- counts as 0.5 of a payable day
    'ABSENT',       -- not paid
    'PAID_LEAVE',   -- paid
    'UNPAID_LEAVE', -- not paid
    'HOLIDAY',      -- paid, factory closed
    'WEEKLY_OFF'    -- paid
  );
exception when duplicate_object then null; end $mig$;

do $mig$ begin
  create type public.payroll_status as enum ('DRAFT', 'FINALISED', 'PAID');
exception when duplicate_object then null; end $mig$;

do $mig$ begin
  create type public.payslip_component_type as enum (
    'BASIC', 'OVERTIME', 'BONUS', 'INCENTIVE', 'DEDUCTION', 'ADVANCE_RECOVERY');
exception when duplicate_object then null; end $mig$;

do $mig$ begin
  create type public.advance_txn_type as enum (
    'ISSUED', 'RECOVERED', 'WRITTEN_OFF', 'CORRECTION');
exception when duplicate_object then null; end $mig$;

-- -----------------------------------------------------------------------------
-- salary_structures — effective-dated pay
--
-- A raise is a new row, never an edit. `payslips` additionally snapshot the
-- figures they used, so reprinting an old payslip cannot produce a different
-- number from the one that was paid.
-- -----------------------------------------------------------------------------

create table if not exists public.salary_structures (
  id                     uuid primary key default gen_random_uuid(),
  profile_id             uuid not null references public.profiles (id) on delete restrict,
  effective_from         date not null,
  effective_to           date,
  monthly_salary         numeric(12, 2) not null check (monthly_salary > 0),
  -- Null means "derive it": see payroll_overtime_multiplier.
  overtime_rate_per_hour numeric(10, 2) check (overtime_rate_per_hour is null
                                               or overtime_rate_per_hour >= 0),
  standard_hours_per_day numeric(4, 2) not null default 8
                         check (standard_hours_per_day > 0 and standard_hours_per_day <= 24),
  created_by             uuid references public.profiles (id),
  created_at             timestamptz not null default now(),
  remarks                text,
  constraint salary_period_ck check (effective_to is null or effective_to >= effective_from)
);

-- One open-ended structure per person. Overlap of closed periods is prevented in
-- set_salary_structure(), which is the only write path — an exclusion constraint
-- would need btree_gist, and the RPC has to validate anyway.
create unique index if not exists salary_structures_one_open
  on public.salary_structures (profile_id) where effective_to is null;

create index if not exists salary_structures_profile_idx
  on public.salary_structures (profile_id, effective_from desc);

-- -----------------------------------------------------------------------------
-- attendance_days — one row per person per working day
--
-- Punches are timestamptz, not times, so a night shift that starts at 22:00 and
-- ends at 06:00 the next morning is one row on its own date rather than two
-- halves that have to be stitched together (A16).
--
-- `worked_hours` is GENERATED from the punch pair, so it can never disagree with
-- the times it is supposed to summarise. Overtime is NOT derived: how much of a
-- long day counts as overtime is a decision, not arithmetic.
-- -----------------------------------------------------------------------------

create table if not exists public.attendance_days (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete restrict,
  work_date      date not null,
  shift_id       uuid references public.shifts (id) on delete restrict,
  status         public.attendance_status not null default 'PRESENT',
  punch_in_at    timestamptz,
  punch_out_at   timestamptz,
  worked_hours   numeric(6, 2)
                 generated always as (
                   case
                     when punch_in_at is null or punch_out_at is null then null
                     else round((extract(epoch from (punch_out_at - punch_in_at)) / 3600.0)::numeric, 2)
                   end
                 ) stored,
  overtime_hours numeric(6, 2) not null default 0 check (overtime_hours >= 0),
  client_ref     uuid unique,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  remarks        text,
  unique (profile_id, work_date),
  constraint attendance_punch_order_ck
    check (punch_in_at is null or punch_out_at is null or punch_out_at > punch_in_at),
  -- A day nobody attended cannot also have been clocked into.
  constraint attendance_absent_has_no_punches_ck
    check (status not in ('ABSENT', 'UNPAID_LEAVE', 'PAID_LEAVE')
           or (punch_in_at is null and punch_out_at is null))
);

create index if not exists attendance_date_idx on public.attendance_days (work_date desc);
create index if not exists attendance_profile_date_idx
  on public.attendance_days (profile_id, work_date desc);

drop trigger if exists attendance_touch on public.attendance_days;
create trigger attendance_touch
  before update on public.attendance_days
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Salary advances — money out now, recovered from a later payslip
--
-- Ledgered exactly as stock is: a balance row that is the row-lock target, and
-- an append-only transaction table where every row carries the previous and
-- resulting outstanding with a CHECK that they agree. Two payroll runs cannot
-- recover the same advance twice.
-- -----------------------------------------------------------------------------

create table if not exists public.staff_advance_balance (
  profile_id  uuid primary key references public.profiles (id) on delete cascade,
  outstanding numeric(12, 2) not null default 0 check (outstanding >= 0),
  updated_at  timestamptz not null default now()
);

create table if not exists public.advance_transactions (
  id                    uuid primary key default gen_random_uuid(),
  profile_id            uuid not null references public.profiles (id) on delete restrict,
  transaction_type      public.advance_txn_type not null,
  -- SIGNED: positive issues an advance, negative recovers or writes one off.
  amount                numeric(12, 2) not null check (amount <> 0),
  previous_outstanding  numeric(12, 2) not null check (previous_outstanding >= 0),
  resulting_outstanding numeric(12, 2) not null check (resulting_outstanding >= 0),
  entry_date            date not null default current_date,
  reference_id          uuid,
  reference_table       text,
  client_ref            uuid unique,
  created_by            uuid references public.profiles (id),
  created_at            timestamptz not null default now(),
  remarks               text,
  constraint advance_balance_ck
    check (resulting_outstanding = previous_outstanding + amount)
);

create index if not exists advance_txn_profile_idx
  on public.advance_transactions (profile_id, created_at desc);
create index if not exists advance_txn_reference_idx
  on public.advance_transactions (reference_id);

-- -----------------------------------------------------------------------------
-- staff_adjustments — a bonus or a deduction for one person in one month
--
-- Entered before payroll runs and picked up by it. Kept apart from the payslip
-- so re-running a draft does not lose them.
-- -----------------------------------------------------------------------------

create table if not exists public.staff_adjustments (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete restrict,
  period_month   date not null,
  component_type public.payslip_component_type not null,
  label          text not null check (length(btrim(label)) > 0),
  -- Always a positive magnitude. Whether it adds or subtracts comes from the
  -- type, so a deduction can never be typed as a negative bonus by accident.
  amount         numeric(12, 2) not null check (amount > 0),
  client_ref     uuid unique,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  remarks        text,
  constraint staff_adjustment_month_ck check (extract(day from period_month) = 1),
  constraint staff_adjustment_type_ck
    check (component_type in ('BONUS', 'INCENTIVE', 'DEDUCTION'))
);

create index if not exists staff_adjustments_period_idx
  on public.staff_adjustments (period_month, profile_id);

-- -----------------------------------------------------------------------------
-- payroll_periods — one calendar month
--
-- DRAFT can be recomputed as often as you like. FINALISED is frozen and is the
-- point at which advance recoveries actually hit the advance ledger, so
-- recomputing a draft can never recover the same advance twice.
-- -----------------------------------------------------------------------------

create table if not exists public.payroll_periods (
  id            uuid primary key default gen_random_uuid(),
  period_month  date not null unique,
  status        public.payroll_status not null default 'DRAFT',
  finalised_at  timestamptz,
  finalised_by  uuid references public.profiles (id),
  paid_at       timestamptz,
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now(),
  remarks       text,
  constraint payroll_period_month_ck check (extract(day from period_month) = 1)
);

-- -----------------------------------------------------------------------------
-- payslips — what one person is owed for one month
--
-- Every figure the calculation depended on is snapshotted: the salary, the
-- overtime rate, the day counts. Reprinting a payslip from 2019 must produce the
-- number that was paid in 2019, not the number today's master data implies.
-- -----------------------------------------------------------------------------

create table if not exists public.payslips (
  id                     uuid primary key default gen_random_uuid(),
  payroll_period_id      uuid not null references public.payroll_periods (id) on delete cascade,
  profile_id             uuid not null references public.profiles (id) on delete restrict,
  salary_structure_id    uuid references public.salary_structures (id),
  -- Snapshots
  monthly_salary         numeric(12, 2) not null check (monthly_salary >= 0),
  overtime_rate_per_hour numeric(10, 2) not null default 0 check (overtime_rate_per_hour >= 0),
  calendar_days          integer not null check (calendar_days between 28 and 31),
  present_days           numeric(6, 2) not null default 0 check (present_days >= 0),
  absent_days            numeric(6, 2) not null default 0 check (absent_days >= 0),
  payable_days           numeric(6, 2) not null check (payable_days >= 0),
  overtime_hours         numeric(8, 2) not null default 0 check (overtime_hours >= 0),
  -- Money
  basic_amount           numeric(12, 2) not null default 0 check (basic_amount >= 0),
  overtime_amount        numeric(12, 2) not null default 0 check (overtime_amount >= 0),
  additions_amount       numeric(12, 2) not null default 0 check (additions_amount >= 0),
  deductions_amount      numeric(12, 2) not null default 0 check (deductions_amount >= 0),
  advance_recovered      numeric(12, 2) not null default 0 check (advance_recovered >= 0),
  gross_amount           numeric(12, 2) not null check (gross_amount >= 0),
  net_payable            numeric(12, 2) not null check (net_payable >= 0),
  created_by             uuid references public.profiles (id),
  created_at             timestamptz not null default now(),
  unique (payroll_period_id, profile_id),
  -- The arithmetic is enforced, not merely intended. A payslip that does not add
  -- up cannot be stored at all.
  constraint payslip_gross_ck
    check (gross_amount = basic_amount + overtime_amount + additions_amount),
  constraint payslip_net_ck
    check (net_payable = gross_amount - deductions_amount - advance_recovered)
);

create index if not exists payslips_period_idx on public.payslips (payroll_period_id);
create index if not exists payslips_profile_idx on public.payslips (profile_id, created_at desc);

-- -----------------------------------------------------------------------------
-- payslip_components — the itemised lines behind the totals
-- -----------------------------------------------------------------------------

create table if not exists public.payslip_components (
  id             uuid primary key default gen_random_uuid(),
  payslip_id     uuid not null references public.payslips (id) on delete cascade,
  component_type public.payslip_component_type not null,
  label          text not null,
  -- Signed: earnings positive, deductions and recoveries negative, so the lines
  -- sum to net_payable and a payslip can be checked by adding it up.
  amount         numeric(12, 2) not null,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now()
);

create index if not exists payslip_components_payslip_idx
  on public.payslip_components (payslip_id, sort_order);

-- -----------------------------------------------------------------------------
-- Settings — every assumption in the calculation, in one place
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description) values
  ('payroll_unmarked_day_policy', 'PAYABLE',
   'PAYABLE: a day with no attendance row counts as worked, so only exceptions '
   'need marking. UNPAID: only days explicitly marked count. PAYABLE is the '
   'default because underpaying a worker is worse than overpaying one.'),
  ('payroll_proration_basis', 'CALENDAR_DAYS',
   'CALENDAR_DAYS: basic = monthly x payable days / days in the month, so a full '
   'month pays exactly the monthly salary. FIXED_DAYS: divides by '
   'payroll_fixed_days instead.'),
  ('payroll_fixed_days', '26',
   'Divisor when payroll_proration_basis is FIXED_DAYS, and the divisor used to '
   'derive an hourly rate for overtime.'),
  ('payroll_overtime_multiplier', '2.0',
   'Overtime is this multiple of the ordinary hourly rate when a person has no '
   'explicit rate. Two times is the statutory factory rate in India.'),
  ('payroll_recover_advances', 'true',
   'Recover outstanding advances from a payslip. Recovery is capped so net pay '
   'can never fall below zero, and only happens when a period is finalised.')
on conflict (key) do update set description = excluded.description;
