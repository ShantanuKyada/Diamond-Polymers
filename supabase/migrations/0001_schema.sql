-- =============================================================================
-- 0001_schema.sql — enums, tables, constraints, indexes
-- Braided Plastic Pipe Factory Management System
--
-- Design notes that are load-bearing (see docs/01-ambiguities-and-decisions.md):
--   * Ledger tables store `quantity` as a SIGNED delta, so SUM(quantity) over a
--     ledger equals the balance. A CHECK enforces resulting = previous + quantity,
--     which makes a mis-written movement impossible rather than merely unlikely.
--   * Balance tables (*_stock) are a cache AND the row-lock target for concurrent
--     stock movements. They are written only by SECURITY DEFINER functions.
--   * Entry tables carry `client_ref uuid UNIQUE` for idempotent retries (§47).
-- =============================================================================

create extension if not exists pgcrypto;

create schema if not exists app;
comment on schema app is 'Internal helpers and privileged routines. Not exposed to PostgREST.';

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

create type public.user_role as enum ('ADMIN', 'OPERATOR');

create type public.machine_status as enum ('ACTIVE', 'INACTIVE', 'MAINTENANCE');

create type public.raw_txn_type as enum (
  'OPENING_STOCK',
  'STOCK_IN',
  'PRODUCTION_CONSUMPTION',
  'MANUAL_ADJUSTMENT',
  'WASTAGE',
  'RECOVERED_WASTAGE',
  'CORRECTION'
);

create type public.fg_txn_type as enum (
  'OPENING_STOCK',
  'PRODUCTION',
  'DISPATCH',
  'RETURN',
  'ADJUSTMENT',
  'CORRECTION'
);

create type public.reusable_txn_type as enum (
  'OPENING_STOCK',
  'RECOVERED',
  'CONSUMED',
  'ADJUSTMENT',
  'CORRECTION'
);

-- A8: separates material that never entered a mix (deducts raw stock) from scrap
-- generated out of material already consumed (does not deduct again).
create type public.wastage_source as enum ('RAW_MATERIAL_LOSS', 'PRODUCTION_SCRAP');

create type public.notification_type as enum (
  'STOCK_LOW',
  'DISPATCH',
  'PRODUCTION',
  'WASTAGE',
  'SYSTEM'
);

-- -----------------------------------------------------------------------------
-- updated_at trigger
-- -----------------------------------------------------------------------------

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- profiles (A2, A3)
-- -----------------------------------------------------------------------------

create table public.profiles (
  id            uuid primary key default gen_random_uuid(),
  -- Nullable: an operator may exist as a factory record without an app login.
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  name          text not null check (length(btrim(name)) > 0),
  phone         text,
  employee_code text not null unique check (length(btrim(employee_code)) > 0),
  role          public.user_role not null default 'OPERATOR',
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index profiles_role_active_idx on public.profiles (role, active);

create trigger profiles_touch
  before update on public.profiles
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Master data
-- -----------------------------------------------------------------------------

create table public.machines (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (length(btrim(code)) > 0),
  name        text not null check (length(btrim(name)) > 0),
  description text,
  status      public.machine_status not null default 'ACTIVE',
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index machines_active_idx on public.machines (active);

create trigger machines_touch
  before update on public.machines
  for each row execute function app.touch_updated_at();

create table public.shifts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(btrim(name)) > 0),
  start_time time not null,
  end_time   time not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger shifts_touch
  before update on public.shifts
  for each row execute function app.touch_updated_at();

create table public.pipe_types (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (length(btrim(code)) > 0),
  name        text not null check (length(btrim(name)) > 0),
  description text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger pipe_types_touch
  before update on public.pipe_types
  for each row execute function app.touch_updated_at();

create table public.pipe_sizes (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (length(btrim(code)) > 0),
  name        text not null check (length(btrim(name)) > 0),
  description text,
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger pipe_sizes_touch
  before update on public.pipe_sizes
  for each row execute function app.touch_updated_at();

-- Categories live in a table, not an enum, so a new material family does not
-- require a migration (§12).
create table public.raw_material_categories (
  code       text primary key check (length(btrim(code)) > 0),
  name       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.raw_materials (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (length(btrim(code)) > 0),
  name          text not null check (length(btrim(name)) > 0),
  category      text not null references public.raw_material_categories (code),
  unit          text not null default 'kg',
  minimum_stock numeric(14, 3) not null default 0 check (minimum_stock >= 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index raw_materials_category_idx on public.raw_materials (category);
create index raw_materials_active_idx on public.raw_materials (active);

create trigger raw_materials_touch
  before update on public.raw_materials
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- machine_assignments (§10) — assignment changes over time, so it is never
-- embedded in the profile row.
-- -----------------------------------------------------------------------------

create table public.machine_assignments (
  id             uuid primary key default gen_random_uuid(),
  machine_id     uuid not null references public.machines (id) on delete restrict,
  operator_id    uuid not null references public.profiles (id) on delete restrict,
  shift_id       uuid references public.shifts (id) on delete restrict,
  effective_from date not null default current_date,
  effective_to   date,
  active         boolean not null default true,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  constraint machine_assignments_period_ck
    check (effective_to is null or effective_to >= effective_from)
);

-- An operator has at most one open assignment at a time.
create unique index machine_assignments_one_open_per_operator
  on public.machine_assignments (operator_id)
  where effective_to is null and active;

create index machine_assignments_machine_idx on public.machine_assignments (machine_id);
create index machine_assignments_operator_idx on public.machine_assignments (operator_id);

-- -----------------------------------------------------------------------------
-- Raw material inventory
-- -----------------------------------------------------------------------------

create table public.raw_material_stock (
  raw_material_id uuid primary key references public.raw_materials (id) on delete cascade,
  quantity        numeric(14, 3) not null default 0 check (quantity >= 0),
  updated_at      timestamptz not null default now()
);

create table public.raw_material_transactions (
  id               uuid primary key default gen_random_uuid(),
  raw_material_id  uuid not null references public.raw_materials (id) on delete restrict,
  transaction_type public.raw_txn_type not null,
  -- SIGNED delta: negative consumes, positive adds. SUM(quantity) = balance.
  quantity         numeric(14, 3) not null check (quantity <> 0),
  previous_stock   numeric(14, 3) not null check (previous_stock >= 0),
  resulting_stock  numeric(14, 3) not null check (resulting_stock >= 0),
  machine_id       uuid references public.machines (id),
  operator_id      uuid references public.profiles (id),
  reference_id     uuid,
  reference_table  text,
  reverses_id      uuid references public.raw_material_transactions (id),
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  remarks          text,
  constraint raw_txn_balance_ck
    check (resulting_stock = previous_stock + quantity)
);

create index raw_txn_material_created_idx
  on public.raw_material_transactions (raw_material_id, created_at desc);
create index raw_txn_created_idx on public.raw_material_transactions (created_at desc);
create index raw_txn_reference_idx on public.raw_material_transactions (reference_id);
create index raw_txn_machine_idx on public.raw_material_transactions (machine_id);
create index raw_txn_operator_idx on public.raw_material_transactions (operator_id);

-- Admin stock-in and adjustments have no owning entry row to carry client_ref, so
-- the ledger row itself enforces idempotency. Without this, two concurrent retries
-- could both pass a plain "does it exist yet" check and post the stock twice.
create unique index raw_txn_manual_ref_uq
  on public.raw_material_transactions (reference_id)
  where reference_table = 'manual';

-- -----------------------------------------------------------------------------
-- Mixture entries (A4: header + lines, not three fixed columns)
-- -----------------------------------------------------------------------------

create table public.mixture_entries (
  id             uuid primary key default gen_random_uuid(),
  entry_date     date not null default current_date,
  machine_id     uuid not null references public.machines (id) on delete restrict,
  operator_id    uuid not null references public.profiles (id) on delete restrict,
  shift_id       uuid not null references public.shifts (id) on delete restrict,
  total_quantity numeric(14, 3) not null check (total_quantity > 0),
  client_ref     uuid not null unique,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  remarks        text
);

create index mixture_entries_date_idx on public.mixture_entries (entry_date desc);
create index mixture_entries_machine_date_idx on public.mixture_entries (machine_id, entry_date desc);
create index mixture_entries_operator_date_idx on public.mixture_entries (operator_id, entry_date desc);

create table public.mixture_entry_lines (
  id                uuid primary key default gen_random_uuid(),
  mixture_entry_id  uuid not null references public.mixture_entries (id) on delete cascade,
  raw_material_id   uuid not null references public.raw_materials (id) on delete restrict,
  quantity          numeric(14, 3) not null check (quantity > 0),
  unique (mixture_entry_id, raw_material_id)
);

create index mixture_lines_material_idx on public.mixture_entry_lines (raw_material_id);

-- -----------------------------------------------------------------------------
-- Finished goods
-- -----------------------------------------------------------------------------

create table public.finished_goods_stock (
  pipe_type_id     uuid not null references public.pipe_types (id) on delete cascade,
  pipe_size_id     uuid not null references public.pipe_sizes (id) on delete cascade,
  quantity_bundles integer not null default 0 check (quantity_bundles >= 0),
  minimum_stock    integer not null default 0 check (minimum_stock >= 0),
  updated_at       timestamptz not null default now(),
  primary key (pipe_type_id, pipe_size_id)
);

create table public.production_entries (
  id               uuid primary key default gen_random_uuid(),
  entry_date       date not null default current_date,
  machine_id       uuid not null references public.machines (id) on delete restrict,
  operator_id      uuid not null references public.profiles (id) on delete restrict,
  shift_id         uuid not null references public.shifts (id) on delete restrict,
  pipe_type_id     uuid not null references public.pipe_types (id) on delete restrict,
  pipe_size_id     uuid not null references public.pipe_sizes (id) on delete restrict,
  bundle_quantity  integer not null check (bundle_quantity > 0),
  -- A7: kilograms of scrap. Does NOT reduce bundle_quantity.
  wastage_quantity numeric(14, 3) not null default 0 check (wastage_quantity >= 0),
  client_ref       uuid not null unique,
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  remarks          text
);

create index production_date_idx on public.production_entries (entry_date desc);
create index production_machine_date_idx on public.production_entries (machine_id, entry_date desc);
create index production_operator_date_idx on public.production_entries (operator_id, entry_date desc);
create index production_shift_idx on public.production_entries (shift_id);
create index production_product_idx on public.production_entries (pipe_type_id, pipe_size_id);

create table public.finished_goods_transactions (
  id               uuid primary key default gen_random_uuid(),
  pipe_type_id     uuid not null references public.pipe_types (id) on delete restrict,
  pipe_size_id     uuid not null references public.pipe_sizes (id) on delete restrict,
  transaction_type public.fg_txn_type not null,
  -- SIGNED delta in bundles.
  bundle_quantity  integer not null check (bundle_quantity <> 0),
  previous_stock   integer not null check (previous_stock >= 0),
  resulting_stock  integer not null check (resulting_stock >= 0),
  reference_id     uuid,
  reference_table  text,
  reverses_id      uuid references public.finished_goods_transactions (id),
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  remarks          text,
  constraint fg_txn_balance_ck
    check (resulting_stock = previous_stock + bundle_quantity)
);

create index fg_txn_product_created_idx
  on public.finished_goods_transactions (pipe_type_id, pipe_size_id, created_at desc);
create index fg_txn_created_idx on public.finished_goods_transactions (created_at desc);
create index fg_txn_reference_idx on public.finished_goods_transactions (reference_id);

create unique index fg_txn_manual_ref_uq
  on public.finished_goods_transactions (reference_id)
  where reference_table = 'manual';

-- -----------------------------------------------------------------------------
-- Dispatch (A6: header + lines)
-- -----------------------------------------------------------------------------

create table public.dispatches (
  id             uuid primary key default gen_random_uuid(),
  dispatch_date  date not null default current_date,
  customer_name  text not null check (length(btrim(customer_name)) > 0),
  reference      text,
  vehicle_number text,
  client_ref     uuid not null unique,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  remarks        text
);

create index dispatches_date_idx on public.dispatches (dispatch_date desc);

create table public.dispatch_lines (
  id              uuid primary key default gen_random_uuid(),
  dispatch_id     uuid not null references public.dispatches (id) on delete cascade,
  pipe_type_id    uuid not null references public.pipe_types (id) on delete restrict,
  pipe_size_id    uuid not null references public.pipe_sizes (id) on delete restrict,
  bundle_quantity integer not null check (bundle_quantity > 0),
  unique (dispatch_id, pipe_type_id, pipe_size_id)
);

create index dispatch_lines_product_idx on public.dispatch_lines (pipe_type_id, pipe_size_id);

-- -----------------------------------------------------------------------------
-- Wastage and reusable wastage
--
-- Scope decision (A8): wastage is always measured against a raw material.
-- Damaged finished bundles are handled as a finished-goods ADJUSTMENT instead,
-- which keeps "reusable Raizin" semantics clean.
-- -----------------------------------------------------------------------------

create table public.wastage_entries (
  id              uuid primary key default gen_random_uuid(),
  entry_date      date not null default current_date,
  machine_id      uuid references public.machines (id) on delete restrict,
  operator_id     uuid references public.profiles (id) on delete restrict,
  shift_id        uuid references public.shifts (id) on delete restrict,
  raw_material_id uuid not null references public.raw_materials (id) on delete restrict,
  source          public.wastage_source not null,
  quantity        numeric(14, 3) not null check (quantity > 0),
  unit            text not null default 'kg',
  reusable        boolean not null default false,
  reference_id    uuid,
  client_ref      uuid not null unique,
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  remarks         text
);

create index wastage_date_idx on public.wastage_entries (entry_date desc);
create index wastage_material_idx on public.wastage_entries (raw_material_id);
create index wastage_machine_idx on public.wastage_entries (machine_id);
create index wastage_operator_idx on public.wastage_entries (operator_id);

create table public.reusable_wastage_stock (
  raw_material_id uuid primary key references public.raw_materials (id) on delete cascade,
  quantity        numeric(14, 3) not null default 0 check (quantity >= 0),
  updated_at      timestamptz not null default now()
);

create table public.reusable_wastage_transactions (
  id                 uuid primary key default gen_random_uuid(),
  raw_material_id    uuid not null references public.raw_materials (id) on delete restrict,
  transaction_type   public.reusable_txn_type not null,
  -- SIGNED delta.
  quantity           numeric(14, 3) not null check (quantity <> 0),
  previous_quantity  numeric(14, 3) not null check (previous_quantity >= 0),
  resulting_quantity numeric(14, 3) not null check (resulting_quantity >= 0),
  reference_id       uuid,
  reference_table    text,
  created_by         uuid references public.profiles (id),
  created_at         timestamptz not null default now(),
  remarks            text,
  constraint reusable_txn_balance_ck
    check (resulting_quantity = previous_quantity + quantity)
);

create index reusable_txn_material_created_idx
  on public.reusable_wastage_transactions (raw_material_id, created_at desc);

create unique index reusable_txn_manual_ref_uq
  on public.reusable_wastage_transactions (reference_id)
  where reference_table = 'manual';

-- -----------------------------------------------------------------------------
-- Notifications (A10)
-- -----------------------------------------------------------------------------

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  -- Exactly one addressing mode: a specific profile, or a whole role.
  user_id     uuid references public.profiles (id) on delete cascade,
  target_role public.user_role,
  title       text not null,
  message     text not null,
  type        public.notification_type not null default 'SYSTEM',
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint notifications_addressing_ck
    check (user_id is not null or target_role is not null)
);

create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_role_idx on public.notifications (target_role, created_at desc);

-- Read state is per person, so one admin reading a broadcast does not hide it
-- from the others.
create table public.notification_reads (
  notification_id uuid not null references public.notifications (id) on delete cascade,
  profile_id      uuid not null references public.profiles (id) on delete cascade,
  read_at         timestamptz not null default now(),
  primary key (notification_id, profile_id)
);

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

create table public.app_settings (
  key         text primary key,
  value       text not null,
  description text,
  updated_by  uuid references public.profiles (id),
  updated_at  timestamptz not null default now()
);

create trigger app_settings_touch
  before update on public.app_settings
  for each row execute function app.touch_updated_at();
