-- =============================================================================
-- 0007_manufacturing_schema.sql — the pipe manufacturing loop
--
-- Closes the three gaps between the original schema and how the factory
-- actually runs (docs/04-pipe-manufacturing.md):
--
--   1. A bundle now has a WEIGHT. Raw material goes in as kilograms and product
--      comes out as bundles; without kg-per-bundle the two units never meet and
--      no material balance is possible. `pipe_products.bundle_weight_kg` is the
--      conversion, and every production entry snapshots the weight it used so a
--      later spec change cannot rewrite history.
--
--   2. Shredded pipe IS a raw material. Defective pipe is reground and fed back
--      into the machine alongside virgin material, so it belongs in
--      `raw_material_stock` under a RECYCLED-category material — not in the
--      walled-off reusable inventory, which by design can never enter a mixture.
--
--   3. A machine makes a known set of products. `machine_products` records which
--      diameters and sizes each line can run, so a machine cannot be credited
--      with a product it is physically incapable of producing.
--
-- Requires 0006 to have been run and committed first.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Structured size attributes
--
-- `pipe_sizes` carried a free-text description only ("1/2 inch"). Diameter and
-- length become real columns so they can be sorted, filtered and reported on.
-- Both stay nullable: existing rows are legitimate, and the factory may not have
-- a length spec for every size.
-- -----------------------------------------------------------------------------

alter table public.pipe_sizes
  add column if not exists diameter_mm numeric(8, 2),
  add column if not exists length_m     numeric(8, 2);

do $mig$
begin
  alter table public.pipe_sizes
    add constraint pipe_sizes_diameter_ck check (diameter_mm is null or diameter_mm > 0);
exception when duplicate_object then null;
end
$mig$;

do $mig$
begin
  alter table public.pipe_sizes
    add constraint pipe_sizes_length_ck check (length_m is null or length_m > 0);
exception when duplicate_object then null;
end
$mig$;

-- -----------------------------------------------------------------------------
-- Recycled raw material
--
-- Reground pipe is an ordinary `raw_materials` row: it is measured in kg, it is
-- held in `raw_material_stock`, and `consume_raw_materials()` mixes it with no
-- special case whatsoever. `is_recycled` exists so reports can split virgin from
-- recycled input, and so shredding cannot dump kilograms into a virgin material
-- by mistake.
--
-- The factory keeps one pool per grade or colour — black regrind must not end up
-- in a white pipe — so `pipe_types.recycled_material_id` names the pool that a
-- shredded pipe of that type feeds.
-- -----------------------------------------------------------------------------

insert into public.raw_material_categories (code, name) values
  ('RECYCLED', 'Recycled / Shredded')
on conflict (code) do update set name = excluded.name;

alter table public.raw_materials
  add column if not exists is_recycled boolean not null default false;

create index if not exists raw_materials_recycled_idx
  on public.raw_materials (is_recycled) where is_recycled;

alter table public.pipe_types
  add column if not exists recycled_material_id uuid references public.raw_materials (id);

comment on column public.pipe_types.recycled_material_id is
  'Default recycled-material pool that shredded pipe of this type returns to. '
  'shred_pipe() falls back to this when the caller does not name one explicitly.';

-- -----------------------------------------------------------------------------
-- pipe_products — the (type x size) pair as a product, carrying its weight
--
-- Keyed by the same (pipe_type_id, pipe_size_id) pair every existing table uses,
-- with a UNIQUE on the pair, so this is a 1:1 extension of the product identity
-- already in the schema. Nothing that exists has to change to gain a weight.
-- -----------------------------------------------------------------------------

create table if not exists public.pipe_products (
  id                uuid primary key default gen_random_uuid(),
  pipe_type_id      uuid not null references public.pipe_types (id) on delete restrict,
  pipe_size_id      uuid not null references public.pipe_sizes (id) on delete restrict,
  sku               text not null unique check (length(btrim(sku)) > 0),
  -- The kg <-> bundle conversion. NOT NULL and > 0: a product without a weight
  -- would silently break every material balance it appears in.
  bundle_weight_kg  numeric(10, 3) not null check (bundle_weight_kg > 0),
  pipes_per_bundle  integer check (pipes_per_bundle is null or pipes_per_bundle > 0),
  coil_length_m     numeric(8, 2) check (coil_length_m is null or coil_length_m > 0),
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (pipe_type_id, pipe_size_id)
);

create index if not exists pipe_products_active_idx on public.pipe_products (active);

drop trigger if exists pipe_products_touch on public.pipe_products;
create trigger pipe_products_touch
  before update on public.pipe_products
  for each row execute function app.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Weight is versioned, not overwritten
--
-- Changing a bundle weight silently re-values every historical figure derived
-- from it. Two defences: production entries snapshot the weight they used
-- (below), and every change to the spec is recorded here.
-- -----------------------------------------------------------------------------

create table if not exists public.pipe_product_weight_history (
  id                 uuid primary key default gen_random_uuid(),
  pipe_product_id    uuid not null references public.pipe_products (id) on delete cascade,
  previous_weight_kg numeric(10, 3),
  new_weight_kg      numeric(10, 3) not null,
  changed_by         uuid references public.profiles (id),
  changed_at         timestamptz not null default now()
);

create index if not exists pipe_weight_history_product_idx
  on public.pipe_product_weight_history (pipe_product_id, changed_at desc);

create or replace function app.record_pipe_weight_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if tg_op = 'INSERT' then
    insert into public.pipe_product_weight_history
      (pipe_product_id, previous_weight_kg, new_weight_kg, changed_by)
    values (new.id, null, new.bundle_weight_kg, app.current_profile_id());

  elsif new.bundle_weight_kg is distinct from old.bundle_weight_kg then
    insert into public.pipe_product_weight_history
      (pipe_product_id, previous_weight_kg, new_weight_kg, changed_by)
    values (new.id, old.bundle_weight_kg, new.bundle_weight_kg, app.current_profile_id());
  end if;

  return new;
end;
$fn$;

drop trigger if exists pipe_products_weight_audit on public.pipe_products;
create trigger pipe_products_weight_audit
  after insert or update of bundle_weight_kg on public.pipe_products
  for each row execute function app.record_pipe_weight_change();

-- -----------------------------------------------------------------------------
-- machine_products — which line can run which product
--
-- Enforcement is deliberately opt-in per machine: a machine with no rows here is
-- unconstrained. That way configuring one machine does not stop every other
-- machine from recording production the same afternoon.
-- -----------------------------------------------------------------------------

create table if not exists public.machine_products (
  machine_id      uuid not null references public.machines (id) on delete cascade,
  pipe_product_id uuid not null references public.pipe_products (id) on delete cascade,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  primary key (machine_id, pipe_product_id)
);

create index if not exists machine_products_product_idx
  on public.machine_products (pipe_product_id);

-- -----------------------------------------------------------------------------
-- production_entries gains the weight it was recorded against
--
-- `bundle_weight_kg` is a snapshot, not a lookup. `output_weight_kg` is a STORED
-- generated column, so the kilograms of a historical entry can never drift from
-- the bundles and weight that produced them.
-- -----------------------------------------------------------------------------

alter table public.production_entries
  add column if not exists pipe_product_id  uuid references public.pipe_products (id),
  add column if not exists bundle_weight_kg numeric(10, 3),
  add column if not exists actual_weight_kg numeric(12, 3);

do $mig$
begin
  alter table public.production_entries
    add constraint production_bundle_weight_ck
      check (bundle_weight_kg is null or bundle_weight_kg > 0);
exception when duplicate_object then null;
end
$mig$;

do $mig$
begin
  alter table public.production_entries
    add constraint production_actual_weight_ck
      check (actual_weight_kg is null or actual_weight_kg >= 0);
exception when duplicate_object then null;
end
$mig$;

alter table public.production_entries
  add column if not exists output_weight_kg numeric(14, 3)
    generated always as (bundle_quantity * bundle_weight_kg) stored;

create index if not exists production_product_ref_idx
  on public.production_entries (pipe_product_id);

-- -----------------------------------------------------------------------------
-- shred_entries — the defective-pipe log
--
-- Append-only, like every other entry table. `client_ref` makes a retry safe.
-- The CHECK below is the important one: it makes the two physical events
-- structurally different rows rather than a convention someone has to remember.
-- A FINISHED_BUNDLE shred must say how many bundles came out of stock; a
-- PRODUCTION_REJECT shred must not, because no bundle was ever counted.
-- -----------------------------------------------------------------------------

create table if not exists public.shred_entries (
  id                   uuid primary key default gen_random_uuid(),
  entry_date           date not null default current_date,
  source               public.shred_source not null,
  pipe_type_id         uuid not null references public.pipe_types (id) on delete restrict,
  pipe_size_id         uuid not null references public.pipe_sizes (id) on delete restrict,
  pipe_product_id      uuid references public.pipe_products (id) on delete restrict,
  -- Bundles withdrawn from finished goods. NULL for a reject caught at the machine.
  bundle_quantity      integer check (bundle_quantity is null or bundle_quantity > 0),
  -- Kilograms of regrind actually recovered and weighed back in.
  recovered_kg         numeric(12, 3) not null check (recovered_kg > 0),
  -- Theoretical kg the shredded bundles held, kept for loss reporting.
  expected_kg          numeric(12, 3) check (expected_kg is null or expected_kg > 0),
  recycled_material_id uuid not null references public.raw_materials (id) on delete restrict,
  machine_id           uuid references public.machines (id) on delete restrict,
  operator_id          uuid references public.profiles (id) on delete restrict,
  shift_id             uuid references public.shifts (id) on delete restrict,
  production_entry_id  uuid references public.production_entries (id) on delete restrict,
  client_ref           uuid not null unique,
  created_by           uuid references public.profiles (id),
  created_at           timestamptz not null default now(),
  remarks              text,
  constraint shred_source_shape_ck check (
    (source = 'FINISHED_BUNDLE'   and bundle_quantity is not null)
    or
    (source = 'PRODUCTION_REJECT' and bundle_quantity is null)
  )
);

create index if not exists shred_entries_date_idx on public.shred_entries (entry_date desc);
create index if not exists shred_entries_machine_idx on public.shred_entries (machine_id, entry_date desc);
create index if not exists shred_entries_operator_idx on public.shred_entries (operator_id, entry_date desc);
create index if not exists shred_entries_material_idx on public.shred_entries (recycled_material_id);
create index if not exists shred_entries_product_idx on public.shred_entries (pipe_type_id, pipe_size_id);

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description) values
  ('shred_recovery_tolerance_pct', '20',
   'A bundle shred may not recover more than bundle weight plus this percentage. '
   'Recovering more mass than went in is physically impossible, so this catches '
   'a mistyped weight before it corrupts stock. Raise it if the weight specs are rough.'),
  ('enforce_machine_product', 'true',
   'Refuse production of a product the machine is not configured to run. '
   'Machines with no machine_products rows are unconstrained either way.'),
  ('recycled_input_mode', 'RAW_MATERIAL',
   'Shredded pipe is stocked as a RECYCLED-category raw material and mixed through '
   'consume_raw_materials() like any other input. Supersedes reusable_wastage_mode '
   'for the shredding loop.')
on conflict (key) do update set description = excluded.description;
