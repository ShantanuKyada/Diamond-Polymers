-- =============================================================================
-- apply_0015_to_0024.sql — the whole migration window, in one paste
--
-- GENERATED. Do not edit: run supabase/scripts/build_apply_script.py to
-- rebuild it from migrations/, and supabase/tests/go_live.test.mjs checks that
-- what is here is what is there.
--
-- A live project that was set up before the change request is at 0014. This
-- brings it to 0024 in one go.
--
--   HOW      Supabase Dashboard -> SQL Editor -> New query -> paste the whole
--            file -> Run. It is ten migrations concatenated in order; none of
--            them adds an enum value, which is the one thing that cannot share
--            a transaction with its own use, so they can travel together.
--
--   FIRST    Take a backup. Dashboard -> Database -> Backups.
--            Then run checks/0015_preflight.sql and read every row.
--
--   AFTER    Run the verify scripts in checks/, and the reconciliation:
--              select * from public.v_stock_reconciliation where not ok;
--            Zero rows is correct.
--
--   SAFE TO RE-RUN. Every migration in here is written to be, and the whole
--   file has been applied twice in a row to a database with history on it.
--
-- Nothing is lost: supabase/tests/go_live.test.mjs builds a database shaped
-- like the live one, applies this, and checks every production entry, both
-- stock balances, the ledgers and the administrator's login afterwards.
-- =============================================================================



-- -----------------------------------------------------------------------------
-- 0015_packaging_shifts_access.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0015_packaging_shifts_access.sql
--
-- The September 2026 change request (docs/08-packaging-shifts-access.md):
--
--   1. Bags alongside bundles — a packaging mapping on each product, a bag
--      balance beside the bundle balance, and both on production and dispatch.
--   2. Exactly two shifts, Morning and Night, enforced in the database.
--   3. "Wastage material used" on a production entry.
--   4. Material entry is admin-only.
--   5. A person can edit their own name and phone, and nothing else.
--
-- Backward compatibility is the constraint that shapes most of this file: every
-- existing production entry, dispatch and ledger row must keep meaning exactly
-- what it meant before. New columns default to the old behaviour (packaging
-- BUNDLE, zero bags, wastage not used), and constraints that fire on history
-- are relaxed rather than tightened.
--
-- Requires 0001–0014.
-- =============================================================================


-- =============================================================================
-- 1. PACKAGING MAPPING (A24, A26)
-- =============================================================================

alter table public.pipe_products
  add column if not exists pipes_per_bag integer;

do $mig$
begin
  alter table public.pipe_products
    add constraint pipe_products_pipes_per_bag_ck
      check (pipes_per_bag is null or pipes_per_bag > 0);
exception when duplicate_object then null;
end
$mig$;

comment on column public.pipe_products.pipes_per_bag is
  'How many individual pipes make one bag. Bags cannot be produced or '
  'dispatched for this product until this and pipes_per_bundle are both set.';

comment on column public.pipe_products.pipes_per_bundle is
  'How many individual pipes make one bundle.';

-- The weight of one bag, derived from the bundle weight through the pipe
-- counts. NULL when the mapping is incomplete — which is exactly the condition
-- under which bags are refused.
create or replace function app.bag_weight_kg(p public.pipe_products)
returns numeric
language sql
immutable
as $fn$
  select case
    when p.pipes_per_bag is not null and p.pipes_per_bundle is not null
    then round(p.bundle_weight_kg * p.pipes_per_bag / p.pipes_per_bundle, 3)
  end;
$fn$;

-- upsert_pipe_product gains the bag count. Dropped and recreated rather than
-- replaced: a changed signature would otherwise leave two overloads behind and
-- make the PostgREST call ambiguous.
drop function if exists public.upsert_pipe_product(
  uuid, uuid, text, numeric, integer, numeric, boolean
);

create or replace function public.upsert_pipe_product(
  p_pipe_type_id     uuid,
  p_pipe_size_id     uuid,
  p_sku              text,
  p_bundle_weight_kg numeric,
  p_pipes_per_bundle integer default null,
  p_coil_length_m    numeric default null,
  p_active           boolean default true,
  p_pipes_per_bag    integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_id    uuid;
  v_prev  numeric(10, 3);
begin
  if p_bundle_weight_kg is null or p_bundle_weight_kg <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Bundle weight must be greater than zero.',
      detail  = '{"field":"bundle_weight_kg"}';
  end if;

  if p_sku is null or length(btrim(p_sku)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A product code is required.',
      detail  = '{"field":"sku"}';
  end if;

  if p_pipes_per_bundle is not null and p_pipes_per_bundle <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Pipes per bundle must be greater than zero.',
      detail  = '{"field":"pipes_per_bundle"}';
  end if;

  if p_pipes_per_bag is not null and p_pipes_per_bag <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Pipes per bag must be greater than zero.',
      detail  = '{"field":"pipes_per_bag"}';
  end if;

  -- A bag weight is derived through the bundle's pipe count, so a bag count on
  -- its own would be a mapping that can never be used.
  if p_pipes_per_bag is not null and p_pipes_per_bundle is null then
    raise exception using
      errcode = 'DP005',
      message = 'Set pipes per bundle as well — bag weight is worked out from it.',
      detail  = '{"field":"pipes_per_bundle"}';
  end if;

  select id, bundle_weight_kg into v_id, v_prev
  from public.pipe_products
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  insert into public.pipe_products (
    pipe_type_id, pipe_size_id, sku, bundle_weight_kg,
    pipes_per_bundle, pipes_per_bag, coil_length_m, active
  )
  values (
    p_pipe_type_id, p_pipe_size_id, btrim(p_sku), p_bundle_weight_kg,
    p_pipes_per_bundle, p_pipes_per_bag, p_coil_length_m, coalesce(p_active, true)
  )
  on conflict (pipe_type_id, pipe_size_id) do update
    set sku              = excluded.sku,
        bundle_weight_kg = excluded.bundle_weight_kg,
        pipes_per_bundle = excluded.pipes_per_bundle,
        pipes_per_bag    = excluded.pipes_per_bag,
        coil_length_m    = excluded.coil_length_m,
        active           = excluded.active
  returning id into v_id;

  insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles)
  values (p_pipe_type_id, p_pipe_size_id, 0)
  on conflict (pipe_type_id, pipe_size_id) do nothing;

  return jsonb_build_object(
    'id', v_id,
    'previous_weight_kg', v_prev,
    'bundle_weight_kg', p_bundle_weight_kg,
    'weight_changed', v_prev is distinct from p_bundle_weight_kg
  );
end;
$fn$;


-- =============================================================================
-- 2. BAG STOCK AND ITS LEDGER (A25)
-- =============================================================================

do $mig$
begin
  create type public.fg_packaging as enum ('BUNDLE', 'BAG');
exception when duplicate_object then null;
end
$mig$;

alter table public.finished_goods_stock
  add column if not exists quantity_bags integer not null default 0;

do $mig$
begin
  alter table public.finished_goods_stock
    add constraint finished_goods_stock_bags_ck check (quantity_bags >= 0);
exception when duplicate_object then null;
end
$mig$;

-- Which balance a ledger row moved. Every existing row moved bundles, which is
-- what the default records. `bundle_quantity` keeps its name for compatibility
-- and holds the signed delta in units of `packaging`.
alter table public.finished_goods_transactions
  add column if not exists packaging public.fg_packaging not null default 'BUNDLE';

comment on column public.finished_goods_transactions.bundle_quantity is
  'Signed delta in units of `packaging` — bundles for BUNDLE rows, bags for BAG rows.';

create index if not exists fg_txn_product_packaging_idx
  on public.finished_goods_transactions (pipe_type_id, pipe_size_id, packaging, created_at desc);

-- The direct-write guard now covers the bag balance as well.
create or replace function app.guard_fg_stock_quantity()
returns trigger
language plpgsql
as $$
begin
  if (new.quantity_bundles is distinct from old.quantity_bundles
      or new.quantity_bags is distinct from old.quantity_bags)
     and current_user not in ('postgres', 'supabase_admin')
  then
    raise exception using
      errcode = 'DP004',
      message = 'Stock quantities can only be changed through a stock movement.',
      detail  = '{"reason":"direct_quantity_update"}';
  end if;
  return new;
end;
$$;

-- The bag twin of app.apply_fg_movement: lock the balance row, refuse to go
-- negative, write the ledger row.
create or replace function app.apply_fg_bag_movement(
  p_pipe_type_id    uuid,
  p_pipe_size_id    uuid,
  p_type            public.fg_txn_type,
  p_delta           integer,
  p_created_by      uuid,
  p_reference_id    uuid default null,
  p_reference_table text default null,
  p_remarks         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_prev  integer;
  v_next  integer;
  v_txn   uuid;
  v_label text;
begin
  if p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A stock movement cannot be zero.',
      detail  = '{"field":"bag_quantity"}';
  end if;

  insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles)
  values (p_pipe_type_id, p_pipe_size_id, 0)
  on conflict (pipe_type_id, pipe_size_id) do nothing;

  select quantity_bags into v_prev
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id
    and pipe_size_id = p_pipe_size_id
  for update;

  v_next := v_prev + p_delta;

  if v_next < 0 then
    select t.name || ' — ' || s.name into v_label
    from public.pipe_types t, public.pipe_sizes s
    where t.id = p_pipe_type_id and s.id = p_pipe_size_id;

    raise exception using
      errcode = 'DP002',
      message = format('Insufficient bag stock for %s. Available: %s bags.',
                       coalesce(v_label, 'this product'), v_prev),
      detail  = json_build_object(
                  'pipe_type_id', p_pipe_type_id,
                  'pipe_size_id', p_pipe_size_id,
                  'packaging', 'BAG',
                  'label', v_label,
                  'available', v_prev,
                  'requested', abs(p_delta)
                )::text;
  end if;

  update public.finished_goods_stock
  set quantity_bags = v_next, updated_at = now()
  where pipe_type_id = p_pipe_type_id
    and pipe_size_id = p_pipe_size_id;

  insert into public.finished_goods_transactions (
    pipe_type_id, pipe_size_id, transaction_type, packaging, bundle_quantity,
    previous_stock, resulting_stock,
    reference_id, reference_table, created_by, remarks
  )
  values (
    p_pipe_type_id, p_pipe_size_id, p_type, 'BAG', p_delta,
    v_prev, v_next,
    p_reference_id, p_reference_table, p_created_by, p_remarks
  )
  returning id into v_txn;

  return v_txn;
end;
$fn$;

-- Reconciliation, split by packaging. Without the filter, the first bag
-- movement would make every bundle balance look wrong.
create or replace view public.v_stock_reconciliation with (security_invoker = on) as
select
  'RAW_MATERIAL'::text                     as ledger,
  m.id::text                               as key,
  m.name                                   as label,
  coalesce(s.quantity, 0)                  as balance,
  coalesce(l.ledger_total, 0)              as ledger_total,
  coalesce(s.quantity, 0) = coalesce(l.ledger_total, 0) as ok
from public.raw_materials m
left join public.raw_material_stock s on s.raw_material_id = m.id
left join (
  select raw_material_id, sum(quantity) as ledger_total
  from public.raw_material_transactions
  group by raw_material_id
) l on l.raw_material_id = m.id

union all

select
  'FINISHED_GOODS',
  s.pipe_type_id::text || ':' || s.pipe_size_id::text,
  t.name || ' ' || z.name,
  s.quantity_bundles,
  coalesce(l.ledger_total, 0),
  s.quantity_bundles = coalesce(l.ledger_total, 0)
from public.finished_goods_stock s
join public.pipe_types t on t.id = s.pipe_type_id
join public.pipe_sizes z on z.id = s.pipe_size_id
left join (
  select pipe_type_id, pipe_size_id, sum(bundle_quantity) as ledger_total
  from public.finished_goods_transactions
  where packaging = 'BUNDLE'
  group by pipe_type_id, pipe_size_id
) l on l.pipe_type_id = s.pipe_type_id and l.pipe_size_id = s.pipe_size_id

union all

select
  'FINISHED_GOODS_BAGS',
  s.pipe_type_id::text || ':' || s.pipe_size_id::text,
  t.name || ' ' || z.name,
  s.quantity_bags,
  coalesce(l.ledger_total, 0),
  s.quantity_bags = coalesce(l.ledger_total, 0)
from public.finished_goods_stock s
join public.pipe_types t on t.id = s.pipe_type_id
join public.pipe_sizes z on z.id = s.pipe_size_id
left join (
  select pipe_type_id, pipe_size_id, sum(bundle_quantity) as ledger_total
  from public.finished_goods_transactions
  where packaging = 'BAG'
  group by pipe_type_id, pipe_size_id
) l on l.pipe_type_id = s.pipe_type_id and l.pipe_size_id = s.pipe_size_id

union all

select
  'REUSABLE_WASTAGE',
  s.raw_material_id::text,
  m.name,
  s.quantity,
  coalesce(l.ledger_total, 0),
  s.quantity = coalesce(l.ledger_total, 0)
from public.reusable_wastage_stock s
join public.raw_materials m on m.id = s.raw_material_id
left join (
  select raw_material_id, sum(quantity) as ledger_total
  from public.reusable_wastage_transactions
  group by raw_material_id
) l on l.raw_material_id = s.raw_material_id;

-- The stock matrix the Inventory screen reads gains the bag balance.
create or replace view public.v_finished_goods_stock with (security_invoker = on) as
select
  t.id  as pipe_type_id,
  t.name as pipe_type_name,
  t.code as pipe_type_code,
  z.id  as pipe_size_id,
  z.name as pipe_size_name,
  z.code as pipe_size_code,
  z.sort_order,
  coalesce(s.quantity_bundles, 0) as quantity_bundles,
  coalesce(s.minimum_stock, 0)    as minimum_stock,
  case
    when coalesce(s.quantity_bundles, 0) <= 0 then 'OUT'
    when coalesce(s.minimum_stock, 0) > 0
     and coalesce(s.quantity_bundles, 0) <= s.minimum_stock then 'LOW'
    else 'GOOD'
  end   as status,
  s.updated_at,
  coalesce(s.quantity_bags, 0)    as quantity_bags
from public.pipe_types t
cross join public.pipe_sizes z
left join public.finished_goods_stock s
       on s.pipe_type_id = t.id and s.pipe_size_id = z.id
where t.active and z.active;

-- The bundle report keeps its shape and now counts bundles only.
create or replace function public.finished_goods_report(
  p_from date,
  p_to   date
)
returns table (
  pipe_type_id      uuid,
  pipe_size_id      uuid,
  sku               text,
  product_label     text,
  diameter_mm       numeric,
  bundle_weight_kg  numeric,
  opening_bundles   integer,
  produced_bundles  integer,
  dispatched_bundles integer,
  shredded_bundles  integer,
  returned_bundles  integer,
  adjustment_bundles integer,
  closing_bundles   integer,
  closing_weight_kg numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin  uuid := app.require_admin();
  v_window tstzrange := app.report_window(p_from, p_to);
begin
  return query
  select
    t.id,
    z.id,
    p.sku,
    t.name || ' — ' || z.name,
    z.diameter_mm,
    p.bundle_weight_kg,
    coalesce(o.opening, 0)::integer,
    coalesce(w.produced, 0)::integer,
    coalesce(w.dispatched, 0)::integer,
    coalesce(w.shredded, 0)::integer,
    coalesce(w.returned, 0)::integer,
    coalesce(w.adjustment, 0)::integer,
    (coalesce(o.opening, 0) + coalesce(w.net, 0))::integer,
    (coalesce(o.opening, 0) + coalesce(w.net, 0)) * coalesce(p.bundle_weight_kg, 0)
  from public.pipe_types t
  cross join public.pipe_sizes z
  left join public.pipe_products p
         on p.pipe_type_id = t.id and p.pipe_size_id = z.id
  left join (
    select f.pipe_type_id, f.pipe_size_id, sum(f.bundle_quantity) as opening
    from public.finished_goods_transactions f
    where f.created_at < lower(v_window)
      and f.packaging = 'BUNDLE'
    group by f.pipe_type_id, f.pipe_size_id
  ) o on o.pipe_type_id = t.id and o.pipe_size_id = z.id
  left join (
    select
      f.pipe_type_id,
      f.pipe_size_id,
      sum(f.bundle_quantity)                                                as net,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type in ('OPENING_STOCK', 'PRODUCTION')), 0)    as produced,
      coalesce(-sum(f.bundle_quantity) filter (
        where f.transaction_type = 'DISPATCH'), 0)                          as dispatched,
      coalesce(-sum(f.bundle_quantity) filter (
        where f.transaction_type = 'SHRED'), 0)                             as shredded,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type = 'RETURN'), 0)                            as returned,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type in ('ADJUSTMENT', 'CORRECTION')), 0)       as adjustment
    from public.finished_goods_transactions f
    where f.created_at <@ v_window
      and f.packaging = 'BUNDLE'
    group by f.pipe_type_id, f.pipe_size_id
  ) w on w.pipe_type_id = t.id and w.pipe_size_id = z.id
  where t.active and z.active
  order by t.name, z.sort_order;
end;
$fn$;

-- The product view gains the mapping and the bag balance, appended so existing
-- readers see the same columns in the same places.
create or replace view public.v_pipe_products with (security_invoker = on) as
select
  p.id                    as pipe_product_id,
  p.sku,
  p.pipe_type_id,
  t.code                  as pipe_type_code,
  t.name                  as pipe_type_name,
  p.pipe_size_id,
  z.code                  as pipe_size_code,
  z.name                  as pipe_size_name,
  z.diameter_mm,
  z.length_m,
  z.sort_order,
  p.bundle_weight_kg,
  p.pipes_per_bundle,
  p.coil_length_m,
  p.active,
  coalesce(s.quantity_bundles, 0)                     as quantity_bundles,
  coalesce(s.quantity_bundles, 0) * p.bundle_weight_kg as stock_weight_kg,
  coalesce(s.minimum_stock, 0)                        as minimum_stock,
  case
    when coalesce(s.quantity_bundles, 0) <= 0 then 'OUT'
    when coalesce(s.minimum_stock, 0) > 0
     and coalesce(s.quantity_bundles, 0) <= s.minimum_stock then 'LOW'
    else 'GOOD'
  end                     as status,
  s.updated_at,
  p.pipes_per_bag,
  coalesce(s.quantity_bags, 0)                        as quantity_bags,
  case
    when p.pipes_per_bag is not null and p.pipes_per_bundle is not null
    then round(p.bundle_weight_kg * p.pipes_per_bag / p.pipes_per_bundle, 3)
  end                                                  as bag_weight_kg
from public.pipe_products p
join public.pipe_types t on t.id = p.pipe_type_id
join public.pipe_sizes z on z.id = p.pipe_size_id
left join public.finished_goods_stock s
       on s.pipe_type_id = p.pipe_type_id
      and s.pipe_size_id = p.pipe_size_id;


-- =============================================================================
-- 3. PRODUCTION: BAGS AND WASTAGE USED (A27, A28)
-- =============================================================================

alter table public.production_entries
  add column if not exists bag_quantity    integer not null default 0,
  add column if not exists bag_weight_kg   numeric(10, 3),
  add column if not exists wastage_used    boolean not null default false,
  add column if not exists wastage_used_kg numeric(12, 3);

-- bundle_quantity was "> 0". An entry may now be bags only, so each quantity
-- only has to be non-negative and the pair has to be positive. Every existing
-- row satisfies both.
do $mig$
declare
  r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.production_entries'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%bundle_quantity > 0%'
  loop
    execute format('alter table public.production_entries drop constraint %I', r.conname);
  end loop;
end
$mig$;

do $mig$
begin
  alter table public.production_entries
    add constraint production_quantities_ck
      check (bundle_quantity >= 0 and bag_quantity >= 0
             and bundle_quantity + bag_quantity > 0);
exception when duplicate_object then null;
end
$mig$;

do $mig$
begin
  alter table public.production_entries
    add constraint production_bag_weight_ck
      check (bag_weight_kg is null or bag_weight_kg > 0);
exception when duplicate_object then null;
end
$mig$;

-- "No" means no quantity; "Yes" means a positive one. Existing rows are
-- (false, null) and satisfy this.
do $mig$
begin
  alter table public.production_entries
    add constraint production_wastage_used_ck
      check ((not wastage_used and wastage_used_kg is null)
          or (wastage_used and wastage_used_kg > 0));
exception when duplicate_object then null;
end
$mig$;

comment on column public.production_entries.wastage_used_kg is
  'Recycled material this run consumed. Recorded for analysis only; stock moves '
  'through material entry, so recording it here does not deduct it again (A28).';

-- output_weight_kg now counts bag output as well. It is a stored generated
-- column, so it is dropped and re-added; the three views that read it are
-- recreated verbatim from 0009 below.
--
-- Guarded, because "safe to re-run" has to hold on a database that has gone
-- past this migration and not only on one that has just reached it. 0018 adds
-- v_batch_yield over this same column, so a second run of 0015 on a database
-- at 0024 met a dependency it has no business knowing about and stopped at:
--
--   cannot drop column output_weight_kg of table production_entries because
--   other objects depend on it
--
-- Checking whether the column already counts bags answers that without 0015
-- having to keep a list of every view a later migration might add.
do $mig$
begin
  if exists (
    select 1
    from pg_attrdef d
    join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'public.production_entries'::regclass
      and a.attname = 'output_weight_kg'
      and pg_get_expr(d.adbin, d.adrelid) like '%bag_weight_kg%'
  ) then
    raise notice 'output_weight_kg already counts bags; leaving it alone.';
    return;
  end if;

  drop view if exists public.v_daily_material_balance;
  drop view if exists public.v_production_material_balance;
  drop view if exists public.v_production_entries_weighted;

  alter table public.production_entries drop column if exists output_weight_kg;

  alter table public.production_entries
    add column output_weight_kg numeric(14, 3)
      generated always as (
        case
          when bundle_weight_kg is null and bag_weight_kg is null then null
          else coalesce(bundle_quantity * bundle_weight_kg, 0)
             + coalesce(bag_quantity * bag_weight_kg, 0)
        end
      ) stored;
end
$mig$;

create or replace view public.v_production_material_balance with (security_invoker = on) as
with keys as (
  select entry_date, machine_id from public.mixture_entries
  union
  select entry_date, machine_id from public.production_entries
  union
  select entry_date, machine_id from public.shred_entries where machine_id is not null
),
mix as (
  select entry_date, machine_id,
         sum(total_quantity) as consumed_kg,
         count(*)            as mixture_count
  from public.mixture_entries
  group by entry_date, machine_id
),
recycled_in as (
  select e.entry_date, e.machine_id,
         sum(l.quantity) as recycled_consumed_kg
  from public.mixture_entries e
  join public.mixture_entry_lines l on l.mixture_entry_id = e.id
  join public.raw_materials m on m.id = l.raw_material_id
  where m.is_recycled
  group by e.entry_date, e.machine_id
),
prod as (
  select entry_date, machine_id,
         sum(bundle_quantity)                  as bundles_produced,
         sum(coalesce(output_weight_kg, 0))    as produced_kg,
         sum(coalesce(actual_weight_kg, 0))    as weighed_kg,
         sum(wastage_quantity)                 as wastage_kg,
         count(*)                              as entry_count
  from public.production_entries
  group by entry_date, machine_id
),
shred as (
  select entry_date, machine_id,
         coalesce(sum(recovered_kg) filter (where source = 'PRODUCTION_REJECT'), 0) as reject_shred_kg,
         coalesce(sum(recovered_kg) filter (where source = 'FINISHED_BUNDLE'), 0)   as bundle_shred_kg,
         coalesce(sum(bundle_quantity) filter (where source = 'FINISHED_BUNDLE'), 0) as bundles_shredded
  from public.shred_entries
  where machine_id is not null
  group by entry_date, machine_id
)
select
  k.entry_date,
  k.machine_id,
  mc.code                                as machine_code,
  mc.name                                as machine_name,
  coalesce(mix.consumed_kg, 0)           as consumed_kg,
  coalesce(ri.recycled_consumed_kg, 0)   as recycled_consumed_kg,
  coalesce(mix.consumed_kg, 0) - coalesce(ri.recycled_consumed_kg, 0) as virgin_consumed_kg,
  coalesce(mix.mixture_count, 0)         as mixture_count,
  coalesce(prod.bundles_produced, 0)     as bundles_produced,
  coalesce(prod.produced_kg, 0)          as produced_kg,
  nullif(coalesce(prod.weighed_kg, 0), 0) as weighed_kg,
  coalesce(prod.wastage_kg, 0)           as wastage_kg,
  coalesce(prod.entry_count, 0)          as production_count,
  coalesce(shred.reject_shred_kg, 0)     as reject_shred_kg,
  coalesce(shred.bundle_shred_kg, 0)     as bundle_shred_kg,
  coalesce(shred.bundles_shredded, 0)    as bundles_shredded,
  coalesce(mix.consumed_kg, 0)
    - coalesce(prod.produced_kg, 0)
    - coalesce(prod.wastage_kg, 0)
    - coalesce(shred.reject_shred_kg, 0) as unaccounted_kg,
  case
    when coalesce(mix.consumed_kg, 0) > 0
    then round(coalesce(prod.produced_kg, 0) / mix.consumed_kg * 100, 2)
  end                                    as yield_pct
from keys k
join public.machines mc on mc.id = k.machine_id
left join mix        on mix.entry_date   = k.entry_date and mix.machine_id   = k.machine_id
left join recycled_in ri on ri.entry_date = k.entry_date and ri.machine_id   = k.machine_id
left join prod       on prod.entry_date  = k.entry_date and prod.machine_id  = k.machine_id
left join shred      on shred.entry_date = k.entry_date and shred.machine_id = k.machine_id;

create or replace view public.v_daily_material_balance with (security_invoker = on) as
select
  entry_date,
  sum(consumed_kg)          as consumed_kg,
  sum(recycled_consumed_kg) as recycled_consumed_kg,
  sum(virgin_consumed_kg)   as virgin_consumed_kg,
  sum(bundles_produced)     as bundles_produced,
  sum(produced_kg)          as produced_kg,
  sum(wastage_kg)           as wastage_kg,
  sum(reject_shred_kg)      as reject_shred_kg,
  sum(bundle_shred_kg)      as bundle_shred_kg,
  sum(bundles_shredded)     as bundles_shredded,
  sum(unaccounted_kg)       as unaccounted_kg,
  case
    when sum(consumed_kg) > 0
    then round(sum(produced_kg) / sum(consumed_kg) * 100, 2)
  end                       as yield_pct
from public.v_production_material_balance
group by entry_date;

create or replace view public.v_production_entries_weighted with (security_invoker = on) as
select
  e.id,
  e.entry_date,
  e.machine_id,
  mc.code                as machine_code,
  mc.name                as machine_name,
  e.operator_id,
  o.name                 as operator_name,
  e.shift_id,
  sh.name                as shift_name,
  e.pipe_type_id,
  t.name                 as pipe_type_name,
  e.pipe_size_id,
  z.name                 as pipe_size_name,
  z.diameter_mm,
  e.pipe_product_id,
  p.sku,
  e.bundle_quantity,
  e.bundle_weight_kg,
  e.output_weight_kg,
  e.actual_weight_kg,
  case
    when e.actual_weight_kg is null or e.output_weight_kg is null
      or e.output_weight_kg = 0 then null
    else round((e.actual_weight_kg - e.output_weight_kg) / e.output_weight_kg * 100, 2)
  end                    as weight_variance_pct,
  e.wastage_quantity     as wastage_kg,
  e.remarks,
  e.created_at,
  e.bag_quantity,
  e.bag_weight_kg
from public.production_entries e
join public.machines mc on mc.id = e.machine_id
join public.profiles o on o.id = e.operator_id
join public.shifts sh on sh.id = e.shift_id
join public.pipe_types t on t.id = e.pipe_type_id
join public.pipe_sizes z on z.id = e.pipe_size_id
left join public.pipe_products p on p.id = e.pipe_product_id;

-- v_production_entries gains the new fields at the end.
create or replace view public.v_production_entries with (security_invoker = on) as
select
  e.id,
  e.entry_date,
  e.machine_id,
  mc.name as machine_name,
  mc.code as machine_code,
  e.operator_id,
  p.name  as operator_name,
  e.shift_id,
  sh.name as shift_name,
  e.pipe_type_id,
  t.name  as pipe_type_name,
  e.pipe_size_id,
  z.name  as pipe_size_name,
  e.bundle_quantity,
  e.wastage_quantity,
  e.remarks,
  e.created_by,
  e.created_at,
  e.bag_quantity,
  e.wastage_used,
  e.wastage_used_kg
from public.production_entries e
join public.machines mc  on mc.id = e.machine_id
join public.profiles p   on p.id = e.operator_id
join public.shifts sh    on sh.id = e.shift_id
join public.pipe_types t on t.id = e.pipe_type_id
join public.pipe_sizes z on z.id = e.pipe_size_id;

create or replace view public.v_daily_production_summary with (security_invoker = on) as
select
  entry_date,
  sum(bundle_quantity)  as total_bundles,
  sum(wastage_quantity) as total_wastage,
  count(*)              as entry_count,
  sum(bag_quantity)                    as total_bags,
  coalesce(sum(wastage_used_kg), 0)    as total_wastage_used_kg
from public.production_entries
group by entry_date;

drop function if exists public.record_production(
  uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text, numeric
);

create or replace function public.record_production(
  p_machine_id       uuid,
  p_shift_id         uuid,
  p_pipe_type_id     uuid,
  p_pipe_size_id     uuid,
  p_bundle_quantity  integer,
  p_client_ref       uuid,
  p_operator_id      uuid default null,
  p_entry_date       date default current_date,
  p_wastage_quantity numeric default 0,
  p_remarks          text default null,
  p_actual_weight_kg numeric default null,
  p_bag_quantity     integer default 0,
  p_wastage_used     boolean default false,
  p_wastage_used_kg  numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller     uuid;
  v_operator   uuid;
  v_existing   uuid;
  v_entry      uuid;
  v_product    public.pipe_products;
  v_bundles    integer := coalesce(p_bundle_quantity, 0);
  v_bags       integer := coalesce(p_bag_quantity, 0);
  v_bag_weight numeric(10, 3);
  v_used_kg    numeric(12, 3);
  v_resulting  integer;
  v_res_bags   integer;
  v_output_kg  numeric(14, 3);
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());
  v_caller   := app.assert_can_record(v_operator, p_machine_id);

  select id into v_existing from public.production_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if v_bundles < 0 or v_bags < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Quantities cannot be negative.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  if v_bundles + v_bags = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter the bundles or bags produced.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  if coalesce(p_wastage_quantity, 0) < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Wastage cannot be negative.',
      detail  = '{"field":"wastage_quantity"}';
  end if;

  -- A28: "Yes" needs a positive quantity; "No" must not carry one.
  if coalesce(p_wastage_used, false) then
    if p_wastage_used_kg is null or p_wastage_used_kg <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Enter how many kilograms of wastage material were used.',
        detail  = '{"field":"wastage_used_kg"}';
    end if;
    v_used_kg := p_wastage_used_kg;
  else
    if coalesce(p_wastage_used_kg, 0) <> 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Wastage material used is set to No, so no quantity can be entered.',
        detail  = '{"field":"wastage_used_kg"}';
    end if;
    v_used_kg := null;
  end if;

  if p_actual_weight_kg is not null and p_actual_weight_kg < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Weighed output cannot be negative.',
      detail  = '{"field":"actual_weight_kg"}';
  end if;

  if not exists (select 1 from public.pipe_types where id = p_pipe_type_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe type is no longer available.',
      detail  = '{"field":"pipe_type_id"}';
  end if;

  if not exists (select 1 from public.pipe_sizes where id = p_pipe_size_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe size is no longer available.',
      detail  = '{"field":"pipe_size_id"}';
  end if;

  v_product := app.resolve_pipe_product(p_pipe_type_id, p_pipe_size_id);
  perform app.assert_machine_can_make(p_machine_id, v_product.id);

  -- A26: bags are only possible once the mapping exists to weigh them.
  if v_bags > 0 then
    v_bag_weight := app.bag_weight_kg(v_product);
    if v_bag_weight is null then
      raise exception using
        errcode = 'DP005',
        message = format('Bag packing is not set up for %s. Set pipes per bag '
                         'and pipes per bundle for this product first.', v_product.sku),
        detail  = '{"field":"bag_quantity"}';
    end if;
  end if;

  insert into public.production_entries (
    entry_date, machine_id, operator_id, shift_id,
    pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, bundle_weight_kg, bag_quantity, bag_weight_kg,
    actual_weight_kg, wastage_quantity, wastage_used, wastage_used_kg,
    client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    p_pipe_type_id, p_pipe_size_id, v_product.id,
    v_bundles, v_product.bundle_weight_kg, v_bags, v_bag_weight,
    p_actual_weight_kg, coalesce(p_wastage_quantity, 0),
    coalesce(p_wastage_used, false), v_used_kg,
    p_client_ref, v_caller, p_remarks
  )
  returning id, output_weight_kg into v_entry, v_output_kg;

  if v_bundles > 0 then
    perform app.apply_fg_movement(
      p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', v_bundles, v_caller,
      v_entry, 'production_entries', p_remarks
    );
  end if;

  if v_bags > 0 then
    perform app.apply_fg_bag_movement(
      p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', v_bags, v_caller,
      v_entry, 'production_entries', p_remarks
    );
  end if;

  select quantity_bundles, quantity_bags into v_resulting, v_res_bags
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  return jsonb_build_object(
    'id',               v_entry,
    'duplicate',        false,
    'bundle_quantity',  v_bundles,
    'bag_quantity',     v_bags,
    'bundle_weight_kg', v_product.bundle_weight_kg,
    'bag_weight_kg',    v_bag_weight,
    'output_weight_kg', v_output_kg,
    'wastage_used_kg',  v_used_kg,
    'resulting_stock',  v_resulting,
    'resulting_bags',   v_res_bags
  );
end;
$fn$;

-- production_report gains bags and wastage used. The return type changes, so
-- it is dropped and recreated.
drop function if exists public.production_report(date, date, uuid, uuid, uuid, uuid);

create or replace function public.production_report(
  p_from         date,
  p_to           date,
  p_machine_id   uuid default null,
  p_operator_id  uuid default null,
  p_pipe_type_id uuid default null,
  p_pipe_size_id uuid default null
)
returns table (
  entry_date       date,
  machine_id       uuid,
  machine_name     text,
  operator_id      uuid,
  operator_name    text,
  shift_name       text,
  pipe_type_name   text,
  pipe_size_name   text,
  sku              text,
  entries          bigint,
  bundles          bigint,
  output_kg        numeric,
  wastage_kg       numeric,
  bags             bigint,
  wastage_used_kg  numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
begin
  if p_to < p_from then
    raise exception using
      errcode = 'DP005',
      message = 'The end date is before the start date.',
      detail  = '{"field":"date_range"}';
  end if;

  return query
  select
    e.entry_date,
    e.machine_id,
    mc.name,
    e.operator_id,
    o.name,
    sh.name,
    tp.name,
    sz.name,
    pp.sku,
    count(*),
    sum(e.bundle_quantity)::bigint,
    sum(coalesce(e.output_weight_kg, 0)),
    sum(e.wastage_quantity),
    sum(e.bag_quantity)::bigint,
    coalesce(sum(e.wastage_used_kg), 0)
  from public.production_entries e
  join public.machines mc on mc.id = e.machine_id
  join public.profiles o on o.id = e.operator_id
  join public.shifts sh on sh.id = e.shift_id
  join public.pipe_types tp on tp.id = e.pipe_type_id
  join public.pipe_sizes sz on sz.id = e.pipe_size_id
  left join public.pipe_products pp on pp.id = e.pipe_product_id
  where e.entry_date between p_from and p_to
    and (p_machine_id   is null or e.machine_id   = p_machine_id)
    and (p_operator_id  is null or e.operator_id  = p_operator_id)
    and (p_pipe_type_id is null or e.pipe_type_id = p_pipe_type_id)
    and (p_pipe_size_id is null or e.pipe_size_id = p_pipe_size_id)
  group by e.entry_date, e.machine_id, mc.name, e.operator_id, o.name,
           sh.name, tp.name, sz.name, pp.sku
  order by e.entry_date desc, mc.name, o.name;
end;
$fn$;


-- =============================================================================
-- 4. DISPATCH: BUYER, VEHICLE, BUNDLES AND BAGS (A25, A27)
-- =============================================================================

alter table public.dispatch_lines
  add column if not exists bag_quantity integer not null default 0;

do $mig$
declare
  r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.dispatch_lines'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%bundle_quantity > 0%'
  loop
    execute format('alter table public.dispatch_lines drop constraint %I', r.conname);
  end loop;
end
$mig$;

do $mig$
begin
  alter table public.dispatch_lines
    add constraint dispatch_lines_quantities_ck
      check (bundle_quantity >= 0 and bag_quantity >= 0
             and bundle_quantity + bag_quantity > 0);
exception when duplicate_object then null;
end
$mig$;

comment on column public.dispatches.customer_name is 'The buyer the goods were dispatched to.';

create or replace view public.v_dispatch_lines with (security_invoker = on) as
select
  d.id            as dispatch_id,
  d.dispatch_date,
  d.customer_name,
  d.reference,
  d.vehicle_number,
  d.remarks,
  d.created_by,
  d.created_at,
  l.id            as line_id,
  l.pipe_type_id,
  t.name          as pipe_type_name,
  l.pipe_size_id,
  z.name          as pipe_size_name,
  l.bundle_quantity,
  l.bag_quantity
from public.dispatches d
join public.dispatch_lines l on l.dispatch_id = d.id
join public.pipe_types t on t.id = l.pipe_type_id
join public.pipe_sizes z on z.id = l.pipe_size_id;

create or replace view public.v_daily_dispatch_summary with (security_invoker = on) as
select
  d.dispatch_date,
  sum(l.bundle_quantity)      as total_bundles,
  count(distinct d.id)        as dispatch_count,
  sum(l.bag_quantity)         as total_bags
from public.dispatches d
join public.dispatch_lines l on l.dispatch_id = d.id
group by d.dispatch_date;

-- Same signature as before: bags travel inside the existing p_lines payload as
-- `bag_quantity`, so callers that send bundles only are unaffected.
create or replace function public.create_dispatch(
  p_customer_name  text,
  p_lines          jsonb,
  p_client_ref     uuid,
  p_dispatch_date  date default current_date,
  p_reference      text default null,
  p_vehicle_number text default null,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin      uuid := app.require_admin();
  v_existing   uuid;
  v_dispatch   uuid;
  v_vehicle    text;
  v_bundles    integer := 0;
  v_bags       integer := 0;
  v_product    public.pipe_products;
  r            record;
begin
  select id into v_existing from public.dispatches where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_customer_name is null or length(btrim(p_customer_name)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter the buyer name.',
      detail  = '{"field":"customer_name"}';
  end if;

  -- Stored without spaces or hyphens and in capitals, so "gj 01-ab 1234" and
  -- "GJ01AB1234" are the same vehicle in every report.
  v_vehicle := upper(regexp_replace(coalesce(p_vehicle_number, ''), '[[:space:]-]', '', 'g'));

  if v_vehicle = '' then
    raise exception using
      errcode = 'DP005',
      message = 'Enter the vehicle number.',
      detail  = '{"field":"vehicle_number"}';
  end if;

  if v_vehicle !~ '^[A-Z0-9]{4,15}$' then
    raise exception using
      errcode = 'DP005',
      message = 'Enter a valid vehicle number, for example GJ01AB1234.',
      detail  = '{"field":"vehicle_number"}';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Add at least one product to dispatch.',
      detail  = '{"field":"lines"}';
  end if;

  insert into public.dispatches (
    dispatch_date, customer_name, reference, vehicle_number,
    client_ref, created_by, remarks
  )
  values (
    p_dispatch_date, btrim(p_customer_name), p_reference, v_vehicle,
    p_client_ref, v_admin, p_remarks
  )
  returning id into v_dispatch;

  -- Ordered so concurrent dispatches lock products in the same sequence (A14).
  -- Any failure below rolls back the dispatch and every line before it.
  for r in
    select (e->>'pipe_type_id')::uuid                     as type_id,
           (e->>'pipe_size_id')::uuid                     as size_id,
           coalesce((e->>'bundle_quantity')::int, 0)      as bundles,
           coalesce((e->>'bag_quantity')::int, 0)         as bags
    from jsonb_array_elements(p_lines) e
    order by 1, 2
  loop
    if r.bundles < 0 or r.bags < 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Dispatch quantities cannot be negative.',
        detail  = '{"field":"bundle_quantity"}';
    end if;

    if r.bundles + r.bags = 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Every product on a dispatch needs bundles or bags.',
        detail  = '{"field":"bundle_quantity"}';
    end if;

    if r.bags > 0 then
      select * into v_product
      from public.pipe_products
      where pipe_type_id = r.type_id and pipe_size_id = r.size_id;

      if not found or app.bag_weight_kg(v_product) is null then
        raise exception using
          errcode = 'DP005',
          message = 'Bag packing is not set up for that product. Set pipes per '
                    'bag and pipes per bundle first.',
          detail  = json_build_object('field', 'bag_quantity',
                                      'pipe_type_id', r.type_id,
                                      'pipe_size_id', r.size_id)::text;
      end if;
    end if;

    insert into public.dispatch_lines
      (dispatch_id, pipe_type_id, pipe_size_id, bundle_quantity, bag_quantity)
    values (v_dispatch, r.type_id, r.size_id, r.bundles, r.bags);

    -- Each raises DP002 and rolls back the whole dispatch if that balance is
    -- short (§22).
    if r.bundles > 0 then
      perform app.apply_fg_movement(
        r.type_id, r.size_id, 'DISPATCH', -r.bundles, v_admin,
        v_dispatch, 'dispatches', p_remarks
      );
    end if;

    if r.bags > 0 then
      perform app.apply_fg_bag_movement(
        r.type_id, r.size_id, 'DISPATCH', -r.bags, v_admin,
        v_dispatch, 'dispatches', p_remarks
      );
    end if;

    v_bundles := v_bundles + r.bundles;
    v_bags    := v_bags + r.bags;
  end loop;

  -- §23: one notification per line, carrying what remains of each packaging.
  for r in
    select l.pipe_type_id, l.pipe_size_id, l.bundle_quantity, l.bag_quantity,
           t.name as type_name, z.name as size_name,
           s.quantity_bundles as bundles_left,
           s.quantity_bags    as bags_left
    from public.dispatch_lines l
    join public.pipe_types t on t.id = l.pipe_type_id
    join public.pipe_sizes z on z.id = l.pipe_size_id
    join public.finished_goods_stock s
      on s.pipe_type_id = l.pipe_type_id and s.pipe_size_id = l.pipe_size_id
    where l.dispatch_id = v_dispatch
  loop
    perform app.notify_role(
      'ADMIN',
      'Dispatch completed',
      format('%s %s — dispatched %s to %s. Remaining stock: %s bundles, %s bags.',
             r.type_name, r.size_name,
             concat_ws(' and ',
               case when r.bundle_quantity > 0 then r.bundle_quantity || ' bundles' end,
               case when r.bag_quantity    > 0 then r.bag_quantity    || ' bags'    end),
             btrim(p_customer_name), r.bundles_left, r.bags_left),
      'DISPATCH',
      json_build_object('dispatch_id',  v_dispatch,
                        'pipe_type_id', r.pipe_type_id,
                        'pipe_size_id', r.pipe_size_id,
                        'bundles',      r.bundle_quantity,
                        'bags',         r.bag_quantity,
                        'bundles_left', r.bundles_left,
                        'bags_left',    r.bags_left)::jsonb
    );

    perform app.check_low_fg_stock(r.pipe_type_id, r.pipe_size_id);
  end loop;

  return jsonb_build_object(
    'id',            v_dispatch,
    'duplicate',     false,
    'total_bundles', v_bundles,
    'total_bags',    v_bags
  );
end;
$fn$;


-- =============================================================================
-- 5. EXACTLY TWO SHIFTS (A29)
-- =============================================================================

create or replace function app.is_allowed_shift_name(p_name text)
returns boolean
language sql
immutable
as $fn$
  select lower(btrim(coalesce(p_name, ''))) in ('morning', 'night');
$fn$;

-- Data first, trigger second: the guard below would otherwise refuse the very
-- updates that bring an existing database into line.
insert into public.shifts (id, name, start_time, end_time, active)
select '22222222-2222-4222-8222-000000000001', 'Morning', '06:00', '18:00', true
where not exists (select 1 from public.shifts where lower(name) = 'morning')
on conflict (id) do nothing;

insert into public.shifts (id, name, start_time, end_time, active)
select '22222222-2222-4222-8222-000000000003', 'Night', '18:00', '06:00', true
where not exists (select 1 from public.shifts where lower(name) = 'night')
on conflict (id) do nothing;

update public.shifts set active = true where app.is_allowed_shift_name(name);

-- Two shifts must cover the day. Only the original seeded defaults are moved;
-- anything an administrator has already tuned is left alone.
update public.shifts
set start_time = '06:00', end_time = '18:00'
where lower(name) = 'morning' and start_time = '06:00' and end_time = '14:00';

update public.shifts
set start_time = '18:00', end_time = '06:00'
where lower(name) = 'night' and start_time = '22:00' and end_time = '06:00';

-- Assignments on a retired shift lose the shift, not the machine, and an
-- administrator is told how many need a new one.
do $mig$
declare
  v_count integer;
begin
  update public.machine_assignments a
  set shift_id = null
  from public.shifts s
  where s.id = a.shift_id
    and not app.is_allowed_shift_name(s.name)
    and a.active
    and a.effective_to is null;

  get diagnostics v_count = row_count;

  if v_count > 0 then
    perform app.notify_role(
      'ADMIN',
      'Shift assignments need attention',
      format('%s operator %s on a shift that no longer exists. Assign them to '
             'Morning or Night.',
             v_count, case when v_count = 1 then 'was' else 'were' end),
      'SYSTEM',
      json_build_object('unassigned', v_count)::jsonb
    );
  end if;
end
$mig$;

-- Retired shifts are switched off, never deleted: past entries still point at
-- them and must keep resolving.
update public.shifts set active = false where not app.is_allowed_shift_name(name);

create or replace function app.guard_shift_master()
returns trigger
language plpgsql
as $fn$
begin
  if tg_op = 'INSERT' then
    if not app.is_allowed_shift_name(new.name) then
      raise exception using
        errcode = 'DP005',
        message = 'Only the Morning and Night shifts are supported.',
        detail  = '{"field":"name"}';
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.name is distinct from old.name then
      raise exception using
        errcode = 'DP005',
        message = 'Shift names cannot be changed.',
        detail  = '{"field":"name"}';
    end if;

    if new.active and not app.is_allowed_shift_name(new.name) then
      raise exception using
        errcode = 'DP005',
        message = 'Only the Morning and Night shifts can be in use.',
        detail  = '{"field":"active"}';
    end if;

    if old.active and not new.active and app.is_allowed_shift_name(new.name) then
      raise exception using
        errcode = 'DP005',
        message = 'The Morning and Night shifts cannot be switched off.',
        detail  = '{"field":"active"}';
    end if;

    return new;
  end if;

  -- DELETE
  if app.is_allowed_shift_name(old.name) then
    raise exception using
      errcode = 'DP005',
      message = 'The Morning and Night shifts cannot be deleted.',
      detail  = '{"field":"id"}';
  end if;
  return old;
end;
$fn$;

drop trigger if exists shifts_guard on public.shifts;
create trigger shifts_guard
  before insert or update or delete on public.shifts
  for each row execute function app.guard_shift_master();

-- New entries may only name a shift that is in use. Insert-only, so history
-- recorded against a retired shift is untouched.
create or replace function app.guard_entry_shift()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if new.shift_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.shifts s
    where s.id = new.shift_id
      and s.active
      and app.is_allowed_shift_name(s.name)
  ) then
    raise exception using
      errcode = 'DP005',
      message = 'Choose the Morning or Night shift.',
      detail  = '{"field":"shift_id"}';
  end if;

  return new;
end;
$fn$;

drop trigger if exists production_entries_shift_guard on public.production_entries;
create trigger production_entries_shift_guard
  before insert on public.production_entries
  for each row execute function app.guard_entry_shift();

drop trigger if exists mixture_entries_shift_guard on public.mixture_entries;
create trigger mixture_entries_shift_guard
  before insert on public.mixture_entries
  for each row execute function app.guard_entry_shift();

drop trigger if exists wastage_entries_shift_guard on public.wastage_entries;
create trigger wastage_entries_shift_guard
  before insert on public.wastage_entries
  for each row execute function app.guard_entry_shift();

drop trigger if exists shred_entries_shift_guard on public.shred_entries;
create trigger shred_entries_shift_guard
  before insert on public.shred_entries
  for each row execute function app.guard_entry_shift();

drop trigger if exists attendance_days_shift_guard on public.attendance_days;
create trigger attendance_days_shift_guard
  before insert on public.attendance_days
  for each row execute function app.guard_entry_shift();


-- =============================================================================
-- 6. MATERIAL ENTRY IS ADMIN-ONLY (A30)
-- =============================================================================

create or replace function public.consume_raw_materials(
  p_machine_id  uuid,
  p_shift_id    uuid,
  p_lines       jsonb,
  p_client_ref  uuid,
  p_operator_id uuid default null,
  p_entry_date  date default current_date,
  p_remarks     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller   uuid;
  v_operator uuid;
  v_existing uuid;
  v_entry    uuid;
  v_total    numeric(14, 3) := 0;
  v_ids      uuid[];
  v_mat      uuid;
  r          record;
begin
  -- A30: recording material is an administrator's job. Operators are refused
  -- here, not merely hidden from the screen.
  v_caller := app.require_admin();

  if p_operator_id is not null then
    if not exists (
      select 1 from public.profiles where id = p_operator_id and active
    ) then
      raise exception using
        errcode = 'DP005',
        message = 'That operator is not active.',
        detail  = '{"field":"operator_id"}';
    end if;
    v_operator := p_operator_id;
  else
    -- Credited to whoever runs the machine, preferring the operator assigned to
    -- this shift; the administrator only when the machine has nobody.
    select a.operator_id into v_operator
    from public.machine_assignments a
    where a.machine_id = p_machine_id
      and a.active
      and a.effective_to is null
    order by (a.shift_id = p_shift_id) desc nulls last, a.effective_from desc
    limit 1;

    v_operator := coalesce(v_operator, v_caller);
  end if;

  -- Idempotent retry (§47).
  select id into v_existing from public.mixture_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter at least one material quantity.',
      detail  = '{"field":"lines"}';
  end if;

  -- Reject duplicate materials rather than silently summing them.
  if (select count(*) from jsonb_array_elements(p_lines) e)
     <> (select count(distinct (e->>'raw_material_id')) from jsonb_array_elements(p_lines) e)
  then
    raise exception using
      errcode = 'DP005',
      message = 'The same material appears twice in this mixture.',
      detail  = '{"field":"lines"}';
  end if;

  -- Deterministic lock order across the whole basket (A14).
  select array_agg(distinct (e->>'raw_material_id')::uuid)
  into v_ids
  from jsonb_array_elements(p_lines) e;

  perform app.lock_raw_materials(v_ids);

  select sum((e->>'quantity')::numeric)
  into v_total
  from jsonb_array_elements(p_lines) e;

  if v_total is null or v_total <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Total mixture quantity must be greater than zero.',
      detail  = '{"field":"total_quantity"}';
  end if;

  insert into public.mixture_entries (
    entry_date, machine_id, operator_id, shift_id,
    total_quantity, client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    v_total, p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  for r in
    select (e->>'raw_material_id')::uuid as material_id,
           (e->>'quantity')::numeric      as quantity
    from jsonb_array_elements(p_lines) e
    order by 1
  loop
    if r.quantity is null or r.quantity <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Every material quantity must be greater than zero.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    if not exists (select 1 from public.raw_materials where id = r.material_id and active) then
      raise exception using
        errcode = 'DP005',
        message = 'That material is no longer available.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    insert into public.mixture_entry_lines (mixture_entry_id, raw_material_id, quantity)
    values (v_entry, r.material_id, r.quantity);

    -- Raises DP001 and rolls the whole entry back if stock is short (§16).
    perform app.apply_raw_movement(
      r.material_id, 'PRODUCTION_CONSUMPTION', -r.quantity, v_caller,
      p_machine_id, v_operator, v_entry, 'mixture_entries', p_remarks
    );
  end loop;

  -- Alerts are raised after the basket succeeds, so a failed attempt never
  -- leaves a misleading notification behind.
  foreach v_mat in array v_ids loop
    perform app.check_low_raw_stock(v_mat);
  end loop;

  return jsonb_build_object(
    'id', v_entry,
    'duplicate', false,
    'total_quantity', v_total,
    'entry_date', p_entry_date
  );
end;
$$;


-- =============================================================================
-- 7. SELF-SERVICE PROFILE (A31)
--
-- A function, not a policy. An UPDATE policy on profiles would let a person
-- write any column of their own row — including `role`.
-- =============================================================================

create or replace function public.update_my_profile(
  p_name  text,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_me    uuid := app.require_profile();
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
begin
  if length(v_name) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter your name.',
      detail  = '{"field":"name"}';
  end if;

  if length(v_name) > 80 then
    raise exception using
      errcode = 'DP005',
      message = 'That name is too long — keep it under 80 characters.',
      detail  = '{"field":"name"}';
  end if;

  if v_phone = '' then
    v_phone := null;
  elsif v_phone !~ '^\+?[0-9]{10,15}$' then
    raise exception using
      errcode = 'DP005',
      message = 'Enter a valid phone number — 10 to 15 digits.',
      detail  = '{"field":"phone"}';
  end if;

  update public.profiles
  set name = v_name, phone = v_phone
  where id = v_me;

  return jsonb_build_object('id', v_me, 'name', v_name, 'phone', v_phone);
end;
$fn$;


-- =============================================================================
-- 8. PRIVILEGES
--
-- New app.* functions default to EXECUTE for PUBLIC. The privileged ones are
-- reached only from SECURITY DEFINER functions and are revoked; the ones a
-- trigger or a security_invoker view calls on the user's behalf are granted.
-- =============================================================================

revoke execute on function
  app.apply_fg_bag_movement(uuid, uuid, public.fg_txn_type, integer, uuid, uuid, text, text),
  app.guard_entry_shift()
from public;

grant execute on function
  app.bag_weight_kg(public.pipe_products),
  app.is_allowed_shift_name(text),
  app.guard_shift_master(),
  app.guard_entry_shift(),
  app.guard_fg_stock_quantity()
to authenticated;

grant execute on function
  public.upsert_pipe_product(uuid, uuid, text, numeric, integer, numeric, boolean, integer),
  public.record_production(uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text, numeric, integer, boolean, numeric),
  public.production_report(date, date, uuid, uuid, uuid, uuid),
  public.create_dispatch(text, jsonb, uuid, date, text, text, text),
  public.consume_raw_materials(uuid, uuid, jsonb, uuid, uuid, date, text),
  public.update_my_profile(text, text)
to authenticated;


-- -----------------------------------------------------------------------------
-- 0016_operator_material_entry.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0016_operator_material_entry.sql — operators record their own material (A34)
--
-- Reverses A30, at the factory's request. A30 moved Material Entry to
-- administrators on the reasoning that drawing down raw stock is an
-- administrative act. In practice every operator has their own machine and is
-- the person physically loading it, so making them walk to an administrator to
-- record what they just poured in produced late entries, not safer ones.
--
-- What changes: exactly one block of consume_raw_materials(). Administrators
-- keep every power they had. Operators gain the ability to record a batch for
-- THEIR OWN assigned machine and nothing else, enforced by the same
-- app.assert_can_record() that already governs record_production():
--
--   * recording for another person      -> DP004
--   * recording for another machine     -> DP006
--
-- Everything else is untouched: there is still no INSERT policy on the mixture
-- tables, so this function remains the only write path; the basket is still
-- validated whole before anything is deducted; and the client reference still
-- makes a retry safe.
--
-- Safe to re-run.
-- =============================================================================

create or replace function public.consume_raw_materials(
  p_machine_id  uuid,
  p_shift_id    uuid,
  p_lines       jsonb,
  p_client_ref  uuid,
  p_operator_id uuid default null,
  p_entry_date  date default current_date,
  p_remarks     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller   uuid;
  v_operator uuid;
  v_existing uuid;
  v_entry    uuid;
  v_total    numeric(14, 3) := 0;
  v_ids      uuid[];
  v_mat      uuid;
  r          record;
begin
  -- A34 (reverses A30): the operator loads their own machine, so the operator
  -- records what went into it. Administrators keep the wider power they had.
  --
  -- The split below is the whole of the change. An administrator may still name
  -- any operator and any machine. Anybody else goes through
  -- app.assert_can_record(), which refuses to let them record for someone else
  -- (DP004) or for a machine they are not currently assigned to (DP006) — the
  -- same guard record_production() has always used, so material and production
  -- are now governed by one rule rather than two.
  if not app.is_admin() then
    v_operator := coalesce(p_operator_id, app.current_profile_id());
    v_caller   := app.assert_can_record(v_operator, p_machine_id);
  elsif p_operator_id is not null then
    v_caller := app.require_admin();
    if not exists (
      select 1 from public.profiles where id = p_operator_id and active
    ) then
      raise exception using
        errcode = 'DP005',
        message = 'That operator is not active.',
        detail  = '{"field":"operator_id"}';
    end if;
    v_operator := p_operator_id;
  else
    v_caller := app.require_admin();
    -- Credited to whoever runs the machine, preferring the operator assigned to
    -- this shift; the administrator only when the machine has nobody.
    select a.operator_id into v_operator
    from public.machine_assignments a
    where a.machine_id = p_machine_id
      and a.active
      and a.effective_to is null
    order by (a.shift_id = p_shift_id) desc nulls last, a.effective_from desc
    limit 1;

    v_operator := coalesce(v_operator, v_caller);
  end if;

  -- Idempotent retry (§47).
  select id into v_existing from public.mixture_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter at least one material quantity.',
      detail  = '{"field":"lines"}';
  end if;

  -- Reject duplicate materials rather than silently summing them.
  if (select count(*) from jsonb_array_elements(p_lines) e)
     <> (select count(distinct (e->>'raw_material_id')) from jsonb_array_elements(p_lines) e)
  then
    raise exception using
      errcode = 'DP005',
      message = 'The same material appears twice in this mixture.',
      detail  = '{"field":"lines"}';
  end if;

  -- Deterministic lock order across the whole basket (A14).
  select array_agg(distinct (e->>'raw_material_id')::uuid)
  into v_ids
  from jsonb_array_elements(p_lines) e;

  perform app.lock_raw_materials(v_ids);

  select sum((e->>'quantity')::numeric)
  into v_total
  from jsonb_array_elements(p_lines) e;

  if v_total is null or v_total <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Total mixture quantity must be greater than zero.',
      detail  = '{"field":"total_quantity"}';
  end if;

  insert into public.mixture_entries (
    entry_date, machine_id, operator_id, shift_id,
    total_quantity, client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    v_total, p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  for r in
    select (e->>'raw_material_id')::uuid as material_id,
           (e->>'quantity')::numeric      as quantity
    from jsonb_array_elements(p_lines) e
    order by 1
  loop
    if r.quantity is null or r.quantity <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Every material quantity must be greater than zero.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    if not exists (select 1 from public.raw_materials where id = r.material_id and active) then
      raise exception using
        errcode = 'DP005',
        message = 'That material is no longer available.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    insert into public.mixture_entry_lines (mixture_entry_id, raw_material_id, quantity)
    values (v_entry, r.material_id, r.quantity);

    -- Raises DP001 and rolls the whole entry back if stock is short (§16).
    perform app.apply_raw_movement(
      r.material_id, 'PRODUCTION_CONSUMPTION', -r.quantity, v_caller,
      p_machine_id, v_operator, v_entry, 'mixture_entries', p_remarks
    );
  end loop;

  -- Alerts are raised after the basket succeeds, so a failed attempt never
  -- leaves a misleading notification behind.
  foreach v_mat in array v_ids loop
    perform app.check_low_raw_stock(v_mat);
  end loop;

  return jsonb_build_object(
    'id', v_entry,
    'duplicate', false,
    'total_quantity', v_total,
    'entry_date', p_entry_date
  );
end;
$$;


-- -----------------------------------------------------------------------------
-- 0017_factory_identity.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0017_factory_identity.sql — the factory's own details, for paperwork
--
-- A delivery challan travels with the goods and has to say who sent them. Until
-- now the only thing the database knew about the factory was its name.
--
-- These are `app_settings` rows rather than a table because there is exactly one
-- factory, and a one-row table is a table you have to remember to populate. They
-- are editable from Configuration like every other setting, so the address on
-- the paperwork is never a literal compiled into an APK.
--
-- Deliberately blank by default. A challan printed with an empty address looks
-- unfinished, which is the correct signal — better than shipping a placeholder
-- that reads as real and travels out to a buyer.
--
-- Safe to re-run: existing values are never overwritten.
-- =============================================================================

insert into public.app_settings (key, value, description) values
  ('factory_address', '',
   'Postal address of the factory, shown on delivery challans. Line breaks are '
   'kept as typed.'),
  ('factory_phone', '',
   'Contact number shown on delivery challans.'),
  ('factory_gstin', '',
   'GSTIN shown on delivery challans. Leave blank if not registered — the line '
   'is omitted rather than printed empty.'),
  ('challan_prefix', 'DC',
   'Prefix for the delivery challan number, e.g. DC-20260926-4F2A. The suffix '
   'is derived from the dispatch itself, so the number is stable and traceable '
   'back to the record without a separate counter.'),
  ('challan_footer', '',
   'Optional line printed at the foot of a challan — terms, a declaration, or '
   'nothing at all.')
on conflict (key) do update
  -- The description may improve; a value the factory has typed must not be
  -- clobbered by a re-run.
  set description = excluded.description;


-- -----------------------------------------------------------------------------
-- 0018_production_batch_link.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0018_production_batch_link.sql — a production run belongs to a batch (A37)
--
-- Answers A12, which the original design deliberately left open:
--
--   "The factory has not defined a recipe, a batch yield, or whether one mix
--    feeds several entries. production_entries.mixture_entry_id is deliberately
--    NOT added, because that column would encode a guess about the process."
--
-- The factory has now described the process: the operator charges the machine
-- and records the material, then records the output when the run finishes.
-- Those are two halves of one run, so the second now points at the first.
--
-- What this buys: yield for THIS batch rather than an average over a machine-day.
-- v_batch_yield below puts kilograms in against kilograms out per batch, which
-- is the number that tells an operator whether the run went well.
--
-- Shape (the factory's answers):
--   * one batch may feed several runs -- not enforced, because a batch that
--     yields two sizes is two entries by A11; the screen treats one as normal
--     and warns when a batch already has production against it;
--   * production without a batch is REFUSED (DP012), configurable through
--     production_requires_batch for corrections and back-filling;
--   * the batch need only be on the same machine. Same-shift would refuse a
--     machine charged at the end of one shift and run out in the next, which
--     the Night shift does every time it crosses midnight.
--
-- The column is NULLABLE: production recorded before this migration has no
-- batch, and inventing one would be worse than admitting the gap. v_batch_yield
-- simply does not see those runs, and the daily material balance still does.
--
-- Safe to re-run.
-- =============================================================================

alter table public.production_entries
  add column if not exists mixture_entry_id uuid
    references public.mixture_entries (id) on delete restrict;

create index if not exists production_mixture_idx
  on public.production_entries (mixture_entry_id);

insert into public.app_settings (key, value, description) values
  ('production_requires_batch', 'true',
   'Refuse a production entry that is not linked to the material batch it came '
   'out of (A37). Turn it off only to back-fill or correct history.')
on conflict (key) do update set description = excluded.description;

-- The signature gains a parameter, and "create or replace" with a different
-- argument list makes a SECOND function rather than replacing the first.
-- PostgREST binds by name and cannot choose between two overloads, so the old
-- one has to go before the new one is created -- and its grant goes with it.
drop function if exists public.record_production(uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text, numeric, integer, boolean, numeric);

create or replace function public.record_production(
  p_machine_id       uuid,
  p_shift_id         uuid,
  p_pipe_type_id     uuid,
  p_pipe_size_id     uuid,
  p_bundle_quantity  integer,
  p_client_ref       uuid,
  p_operator_id      uuid default null,
  p_entry_date       date default current_date,
  p_wastage_quantity numeric default 0,
  p_remarks          text default null,
  p_actual_weight_kg numeric default null,
  p_bag_quantity     integer default 0,
  p_wastage_used     boolean default false,
  p_wastage_used_kg  numeric default null,
  -- A12, finally answered: the batch this run came out of.
  p_mixture_entry_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller     uuid;
  v_operator   uuid;
  v_existing   uuid;
  v_entry      uuid;
  v_product    public.pipe_products;
  v_bundles    integer := coalesce(p_bundle_quantity, 0);
  v_bags       integer := coalesce(p_bag_quantity, 0);
  v_bag_weight numeric(10, 3);
  v_used_kg    numeric(12, 3);
  v_resulting  integer;
  v_res_bags   integer;
  v_output_kg  numeric(14, 3);
  v_batch      public.mixture_entries;
  v_require    boolean;
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());
  v_caller   := app.assert_can_record(v_operator, p_machine_id);

  -- ---------------------------------------------------------------------------
  -- A37: a production run belongs to the batch that fed it.
  --
  -- A12 deferred this because the factory had not said whether one mix feeds
  -- one run or several. It has now: the operator charges the machine, records
  -- it, and records the output when the run finishes. Linking the two is what
  -- turns yield from a daily average into a figure for THIS batch.
  --
  -- The batch only has to be on the same machine. Constraining it to the same
  -- shift or date would refuse the ordinary case of a machine charged near the
  -- end of a shift and run out in the next -- which the Night shift, crossing
  -- midnight, does routinely.
  -- ---------------------------------------------------------------------------
  v_require := coalesce(app.setting('production_requires_batch', 'true'), 'true') = 'true';

  if p_mixture_entry_id is not null then
    select * into v_batch
    from public.mixture_entries where id = p_mixture_entry_id;

    if v_batch.id is null then
      raise exception using
        errcode = 'DP005',
        message = 'That material batch does not exist.',
        detail  = '{"field":"mixture_entry_id"}';
    end if;

    if v_batch.machine_id <> p_machine_id then
      raise exception using
        errcode = 'DP005',
        message = 'That material batch was charged into a different machine.',
        detail  = json_build_object('mixture_entry_id', p_mixture_entry_id,
                                    'batch_machine_id', v_batch.machine_id,
                                    'machine_id', p_machine_id)::text;
    end if;
  elsif v_require then
    -- Distinct code so the screen can offer to record material rather than
    -- just colouring a field red.
    raise exception using
      errcode = 'DP012',
      message = 'Record the material that went into the machine first, then '
                'link this production to it.',
      detail  = '{"field":"mixture_entry_id"}';
  end if;

  select id into v_existing from public.production_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if v_bundles < 0 or v_bags < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Quantities cannot be negative.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  if v_bundles + v_bags = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter the bundles or bags produced.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  if coalesce(p_wastage_quantity, 0) < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Wastage cannot be negative.',
      detail  = '{"field":"wastage_quantity"}';
  end if;

  -- A28: "Yes" needs a positive quantity; "No" must not carry one.
  if coalesce(p_wastage_used, false) then
    if p_wastage_used_kg is null or p_wastage_used_kg <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Enter how many kilograms of wastage material were used.',
        detail  = '{"field":"wastage_used_kg"}';
    end if;
    v_used_kg := p_wastage_used_kg;
  else
    if coalesce(p_wastage_used_kg, 0) <> 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Wastage material used is set to No, so no quantity can be entered.',
        detail  = '{"field":"wastage_used_kg"}';
    end if;
    v_used_kg := null;
  end if;

  if p_actual_weight_kg is not null and p_actual_weight_kg < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Weighed output cannot be negative.',
      detail  = '{"field":"actual_weight_kg"}';
  end if;

  if not exists (select 1 from public.pipe_types where id = p_pipe_type_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe type is no longer available.',
      detail  = '{"field":"pipe_type_id"}';
  end if;

  if not exists (select 1 from public.pipe_sizes where id = p_pipe_size_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe size is no longer available.',
      detail  = '{"field":"pipe_size_id"}';
  end if;

  v_product := app.resolve_pipe_product(p_pipe_type_id, p_pipe_size_id);
  perform app.assert_machine_can_make(p_machine_id, v_product.id);

  -- A26: bags are only possible once the mapping exists to weigh them.
  if v_bags > 0 then
    v_bag_weight := app.bag_weight_kg(v_product);
    if v_bag_weight is null then
      raise exception using
        errcode = 'DP005',
        message = format('Bag packing is not set up for %s. Set pipes per bag '
                         'and pipes per bundle for this product first.', v_product.sku),
        detail  = '{"field":"bag_quantity"}';
    end if;
  end if;

  insert into public.production_entries (
    entry_date, machine_id, operator_id, shift_id,
    pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, bundle_weight_kg, bag_quantity, bag_weight_kg,
    actual_weight_kg, wastage_quantity, wastage_used, wastage_used_kg,
    client_ref, created_by, remarks, mixture_entry_id
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    p_pipe_type_id, p_pipe_size_id, v_product.id,
    v_bundles, v_product.bundle_weight_kg, v_bags, v_bag_weight,
    p_actual_weight_kg, coalesce(p_wastage_quantity, 0),
    coalesce(p_wastage_used, false), v_used_kg,
    p_client_ref, v_caller, p_remarks, p_mixture_entry_id
  )
  returning id, output_weight_kg into v_entry, v_output_kg;

  if v_bundles > 0 then
    perform app.apply_fg_movement(
      p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', v_bundles, v_caller,
      v_entry, 'production_entries', p_remarks
    );
  end if;

  if v_bags > 0 then
    perform app.apply_fg_bag_movement(
      p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', v_bags, v_caller,
      v_entry, 'production_entries', p_remarks
    );
  end if;

  select quantity_bundles, quantity_bags into v_resulting, v_res_bags
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  return jsonb_build_object(
    'id',               v_entry,
    'duplicate',        false,
    'bundle_quantity',  v_bundles,
    'bag_quantity',     v_bags,
    'bundle_weight_kg', v_product.bundle_weight_kg,
    'bag_weight_kg',    v_bag_weight,
    'output_weight_kg', v_output_kg,
    'wastage_used_kg',  v_used_kg,
    'resulting_stock',  v_resulting,
    'resulting_bags',   v_res_bags
  );
end;
$fn$;

grant execute on function
  public.record_production(uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text, numeric, integer, boolean, numeric, uuid)
to authenticated;

-- =============================================================================
-- v_batch_yield — kilograms in against kilograms out, for one batch
--
-- The reason the link was worth adding. v_production_material_balance answers
-- "did this machine balance today"; this answers "did THIS run go well", which
-- is the question an operator can still do something about.
--
-- Runs recorded before 0018 have no batch and simply do not appear here. The
-- daily balance still counts them, so nothing goes missing -- it is just not
-- attributable to a batch.
-- =============================================================================

create or replace view public.v_batch_yield with (security_invoker = on) as
select
  m.id                                   as mixture_entry_id,
  m.entry_date,
  m.machine_id,
  mc.code                                as machine_code,
  mc.name                                as machine_name,
  m.shift_id,
  sh.name                                as shift_name,
  m.operator_id,
  op.name                                as operator_name,
  m.total_quantity                       as charged_kg,
  coalesce(p.runs, 0)                    as runs,
  coalesce(p.bundles, 0)                 as bundles,
  coalesce(p.bags, 0)                    as bags,
  coalesce(p.produced_kg, 0)             as produced_kg,
  coalesce(p.wastage_kg, 0)              as wastage_kg,
  -- What went in, less what came out and what was declared as scrap. A batch
  -- still running shows most of its weight here, so this is only meaningful
  -- once the run is finished -- which is what a runs count of 0 tells you.
  m.total_quantity - coalesce(p.produced_kg, 0) - coalesce(p.wastage_kg, 0)
                                         as unaccounted_kg,
  case
    when m.total_quantity > 0 and coalesce(p.runs, 0) > 0
    then round(coalesce(p.produced_kg, 0) / m.total_quantity * 100, 2)
  end                                    as yield_pct,
  m.created_at
from public.mixture_entries m
join public.machines mc on mc.id = m.machine_id
join public.shifts sh on sh.id = m.shift_id
join public.profiles op on op.id = m.operator_id
left join (
  select
    mixture_entry_id,
    count(*)                                as runs,
    sum(bundle_quantity)                    as bundles,
    sum(coalesce(bag_quantity, 0))          as bags,
    sum(coalesce(output_weight_kg, 0))      as produced_kg,
    sum(coalesce(wastage_quantity, 0))      as wastage_kg
  from public.production_entries
  where mixture_entry_id is not null
  group by mixture_entry_id
) p on p.mixture_entry_id = m.id;


-- -----------------------------------------------------------------------------
-- 0019_simple_payroll.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0019_simple_payroll.sql — payroll is a salary, less what was taken (A38)
--
-- How the factory actually pays people, in their words:
--
--   "Every worker is assigned some salary — say worker A has 1000 for the
--    month. He gets that at the end of the month. If he needs some of it
--    mid-month he asks, we give him 300, and we reduce it from his monthly
--    salary. Just like this."
--
-- So:
--
--     net payable = monthly salary − advances taken − any deduction entered
--
-- and nothing else. What 0012–0014 built was an engine for a factory that
-- prorates pay by attendance and pays statutory overtime. This one does
-- neither. Every part of that engine the factory does not use is removed here
-- rather than switched off, because a dormant rule is one somebody later
-- assumes is running.
--
-- REMOVED
--   * attendance proration — a month's pay does not move with days present
--   * overtime — no hours, no multiplier, no derived hourly rate
--   * bonuses and incentives — nothing adds to a salary
--   * the payroll_* settings that drove all of the above
--
-- KEPT
--   * advances, ledgered exactly as before. This is the point of the module
--     and the part that has to be right.
--   * a deduction entered by hand for one worker in one month — how a long
--     absence is handled: judged case by case rather than computed from a
--     register. Asked and confirmed, not assumed; see A38.
--   * draft / finalise, because advance recovery must post once and only once.
--
-- ATTENDANCE IS NOT DELETED. punch_in, punch_out and set_attendance stay, and
-- the register still records who was in. It simply no longer decides pay; the
-- two were coupled, and the factory says they are not.
--
-- THIS MIGRATION DESTROYS DATA IF THERE IS ANY. Every drop is guarded against
-- erroring twice, which is not the same as being safe: dropping a column takes
-- what was in it. On a database with payslips already issued, the figures
-- behind them — the basic, the overtime, the day counts — are gone, and a
-- payslip reprinted afterwards would be a different document from the one that
-- was paid.
--
-- Run supabase/checks/0019_preflight.sql first. It refuses if there is anything
-- to lose. Here there was not: no payslip, salary structure, advance,
-- adjustment or attendance row existed on the live project, so the module was
-- rebuilt rather than converted.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The read models go first
--
-- Both select columns that are about to disappear, and Postgres will refuse to
-- drop a column a view depends on. They are rebuilt at the foot of this file.
-- -----------------------------------------------------------------------------

drop view if exists public.v_payroll_summary;
drop view if exists public.v_payslips;

-- -----------------------------------------------------------------------------
-- A salary is a number, not a structure of rates
-- -----------------------------------------------------------------------------

alter table public.salary_structures
  drop column if exists overtime_rate_per_hour,
  drop column if exists standard_hours_per_day;

-- -----------------------------------------------------------------------------
-- A payslip carries four figures
--
-- The CHECK constraints go before the columns they mention, so nothing is left
-- referring to something that no longer exists.
-- -----------------------------------------------------------------------------

alter table public.payslips
  drop constraint if exists payslip_gross_ck,
  drop constraint if exists payslip_net_ck;

alter table public.payslips
  drop column if exists overtime_rate_per_hour,
  drop column if exists calendar_days,
  drop column if exists present_days,
  drop column if exists absent_days,
  drop column if exists payable_days,
  drop column if exists overtime_hours,
  drop column if exists overtime_amount,
  drop column if exists additions_amount,
  drop column if exists basic_amount,
  drop column if exists gross_amount;

-- What is left: the salary, what was deducted, what was recovered, what is
-- paid. The arithmetic stays enforced rather than merely intended — a payslip
-- that does not add up cannot be stored at all.
alter table public.payslips
  add constraint payslip_net_ck
    check (net_payable = monthly_salary - deductions_amount - advance_recovered);

-- -----------------------------------------------------------------------------
-- An adjustment can only subtract
--
-- BONUS and INCENTIVE remain in the enum — removing a value from a Postgres
-- enum means rebuilding the type — but nothing may be stored as one. A bonus
-- row that run_payroll silently ignored would be worse than no bonus at all.
-- -----------------------------------------------------------------------------

alter table public.staff_adjustments
  drop constraint if exists staff_adjustment_type_ck;

alter table public.staff_adjustments
  add constraint staff_adjustment_type_ck check (component_type = 'DEDUCTION');

-- -----------------------------------------------------------------------------
-- Settings that no longer mean anything
--
-- Deleted rather than left sitting at a default. A setting nobody reads is a
-- promise the system has quietly stopped keeping.
-- -----------------------------------------------------------------------------

delete from public.app_settings
where key in (
  'payroll_unmarked_day_policy',
  'payroll_proration_basis',
  'payroll_fixed_days',
  'payroll_overtime_multiplier'
);

-- =============================================================================
-- run_payroll — the entire calculation
-- =============================================================================

create or replace function public.run_payroll(
  p_period_month date,
  p_remarks      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin       uuid := app.require_admin();
  v_month       date := date_trunc('month', p_period_month)::date;
  v_period      public.payroll_periods;
  v_recover     boolean := coalesce(app.setting('payroll_recover_advances', 'true'), 'true') = 'true';
  r             record;
  v_deductions  numeric(12, 2);
  v_recovery    numeric(12, 2);
  v_outstanding numeric(12, 2);
  v_net         numeric(12, 2);
  v_payslip     uuid;
  v_count       integer := 0;
  v_total       numeric(14, 2) := 0;
begin
  select * into v_period from public.payroll_periods where period_month = v_month;

  if v_period.id is null then
    insert into public.payroll_periods (period_month, status, created_by, remarks)
    values (v_month, 'DRAFT', v_admin, p_remarks)
    returning * into v_period;
  elsif v_period.status <> 'DRAFT' then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised and cannot be '
                       'recalculated.', to_char(v_month, 'Mon YYYY')),
      detail  = json_build_object('period_id', v_period.id,
                                  'status', v_period.status)::text;
  end if;

  -- Lock the period so two admins cannot compute it into each other.
  perform 1 from public.payroll_periods where id = v_period.id for update;

  -- A draft is rebuilt from scratch. Nothing outside this table has been
  -- written — recovery posts on finalise — so there is nothing to unwind.
  delete from public.payslips where payroll_period_id = v_period.id;

  for r in
    select p.id as profile_id, p.name, p.employee_code,
           s.id as structure_id, s.monthly_salary
    from public.profiles p
    join lateral (
      -- The salary in force during this month: the latest one that had started
      -- by month end and had not ended before month start.
      select st.*
      from public.salary_structures st
      where st.profile_id = p.id
        and st.effective_from <= (v_month + interval '1 month - 1 day')::date
        and (st.effective_to is null or st.effective_to >= v_month)
      order by st.effective_from desc
      limit 1
    ) s on true
    where p.active
    order by p.employee_code
  loop
    -- Entered by hand for this person in this month. This is how a long absence
    -- is handled now that days present no longer move the figure.
    select coalesce(sum(amount), 0)
    into v_deductions
    from public.staff_adjustments
    where profile_id = r.profile_id
      and period_month = v_month
      and component_type = 'DEDUCTION';

    if v_deductions > r.monthly_salary then
      raise exception using
        errcode = 'DP005',
        message = format('Deductions for %s (%s) come to %s, more than the '
                         'monthly salary of %s. Reduce them before calculating '
                         'the payroll.',
                         r.name, r.employee_code,
                         to_char(v_deductions, 'FM999999990.00'),
                         to_char(r.monthly_salary, 'FM999999990.00')),
        detail  = json_build_object('profile_id', r.profile_id,
                                    'deductions', v_deductions,
                                    'monthly_salary', r.monthly_salary)::text;
    end if;

    -- Capped, so a payslip can never come out negative. Somebody who has drawn
    -- more than a month's pay carries the remainder forward to the next one.
    v_recovery := 0;
    if v_recover then
      select coalesce(outstanding, 0) into v_outstanding
      from public.staff_advance_balance where profile_id = r.profile_id;

      v_recovery := least(coalesce(v_outstanding, 0),
                          r.monthly_salary - v_deductions);
    end if;

    v_net := r.monthly_salary - v_deductions - v_recovery;

    insert into public.payslips (
      payroll_period_id, profile_id, salary_structure_id,
      monthly_salary, deductions_amount, advance_recovered, net_payable,
      created_by
    )
    values (
      v_period.id, r.profile_id, r.structure_id,
      r.monthly_salary, v_deductions, v_recovery, v_net,
      v_admin
    )
    returning id into v_payslip;

    -- The itemised lines, signed so that adding them up gives net_payable.
    insert into public.payslip_components
      (payslip_id, component_type, label, amount, sort_order)
    values (v_payslip, 'BASIC', 'Monthly salary', r.monthly_salary, 1);

    insert into public.payslip_components
      (payslip_id, component_type, label, amount, sort_order)
    select v_payslip, 'DEDUCTION', label, -amount, 2
    from public.staff_adjustments
    where profile_id = r.profile_id
      and period_month = v_month
      and component_type = 'DEDUCTION';

    if v_recovery > 0 then
      insert into public.payslip_components
        (payslip_id, component_type, label, amount, sort_order)
      values (v_payslip, 'ADVANCE_RECOVERY', 'Advance already taken',
              -v_recovery, 3);
    end if;

    v_count := v_count + 1;
    v_total := v_total + v_net;
  end loop;

  return jsonb_build_object(
    'period_id',    v_period.id,
    'period_month', v_month,
    'status',       v_period.status,
    'payslips',     v_count,
    'net_total',    v_total
  );
end;
$fn$;

-- =============================================================================
-- set_salary_structure — without the rate fields it no longer carries
--
-- Dropped before it is recreated: PostgREST binds arguments by name, and the
-- old six-argument form left in place would make an overload it cannot choose
-- between.
-- =============================================================================

drop function if exists public.set_salary_structure(uuid, numeric, date, numeric, numeric, text);

create or replace function public.set_salary_structure(
  p_profile_id     uuid,
  p_monthly_salary numeric,
  p_effective_from date default current_date,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_open  public.salary_structures;
  v_id    uuid;
begin
  if p_monthly_salary is null or p_monthly_salary <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Monthly salary must be greater than zero.',
      detail  = '{"field":"monthly_salary"}';
  end if;

  if not exists (select 1 from public.profiles where id = p_profile_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That staff member does not exist or is inactive.',
      detail  = '{"field":"profile_id"}';
  end if;

  -- Lock the person, so two admins granting a raise at the same moment cannot
  -- both close the open period and leave two open rows behind.
  perform 1 from public.profiles where id = p_profile_id for update;

  select * into v_open
  from public.salary_structures
  where profile_id = p_profile_id and effective_to is null;

  if v_open.id is not null then
    if p_effective_from <= v_open.effective_from then
      raise exception using
        errcode = 'DP005',
        message = format('A salary effective %s is already on record. A change '
                         'must start after it.',
                         to_char(v_open.effective_from, 'DD Mon YYYY')),
        detail  = json_build_object('effective_from', v_open.effective_from)::text;
    end if;

    -- The previous rate ends the day before the new one starts. A raise is a
    -- new row, never an edit, so a past payslip keeps the rate it was paid at.
    update public.salary_structures
    set effective_to = p_effective_from - 1
    where id = v_open.id;
  end if;

  insert into public.salary_structures
    (profile_id, effective_from, monthly_salary, created_by, remarks)
  values
    (p_profile_id, p_effective_from, p_monthly_salary, v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'profile_id', p_profile_id,
                            'monthly_salary', p_monthly_salary,
                            'effective_from', p_effective_from,
                            'previous_closed', v_open.id);
end;
$fn$;

grant execute on function
  public.set_salary_structure(uuid, numeric, date, text)
to authenticated;

-- =============================================================================
-- add_staff_adjustment — deductions only
--
-- The signature is unchanged, so PostgREST sees the same function; what it
-- accepts is not.
-- =============================================================================

create or replace function public.add_staff_adjustment(
  p_profile_id     uuid,
  p_period_month   date,
  p_component_type public.payslip_component_type,
  p_label          text,
  p_amount         numeric,
  p_client_ref     uuid,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_month date := date_trunc('month', p_period_month)::date;
  v_id    uuid;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'The amount must be greater than zero. A deduction is entered '
                'as a positive number.',
      detail  = '{"field":"amount"}';
  end if;

  if p_component_type <> 'DEDUCTION' then
    raise exception using
      errcode = 'DP005',
      message = 'Only a deduction can be added to a payslip. Nothing adds to a '
                'monthly salary.',
      detail  = '{"field":"component_type"}';
  end if;

  select id into v_id from public.staff_adjustments where client_ref = p_client_ref;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'duplicate', true);
  end if;

  if exists (select 1 from public.payroll_periods
             where period_month = v_month and status <> 'DRAFT') then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised.',
                       to_char(v_month, 'Mon YYYY')),
      detail  = '{"field":"period_month"}';
  end if;

  insert into public.staff_adjustments
    (profile_id, period_month, component_type, label, amount, client_ref,
     created_by, remarks)
  values
    (p_profile_id, v_month, 'DEDUCTION', btrim(p_label), p_amount,
     p_client_ref, v_admin, p_remarks)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$fn$;

-- =============================================================================
-- remove_staff_adjustment — the undo the deduction never had
--
-- A deduction is now the only manual lever in the whole module, and a mistyped
-- one that exceeds the salary stops the month's payroll dead. Before this there
-- was no way to take one back: staff_adjustments is admin-readable and has no
-- write path but add_staff_adjustment.
--
-- Deleting is honest here rather than lossy. A draft's payslips are rebuilt
-- from scratch on every run, and a finalised month is refused outright, so
-- nothing that has been paid can be rewritten by this.
-- =============================================================================

create or replace function public.remove_staff_adjustment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_row   public.staff_adjustments;
begin
  select * into v_row from public.staff_adjustments where id = p_id;

  -- Already gone. Saying so beats raising at an admin who pressed twice.
  if v_row.id is null then
    return jsonb_build_object('id', p_id, 'removed', false);
  end if;

  if exists (select 1 from public.payroll_periods
             where period_month = v_row.period_month and status <> 'DRAFT') then
    raise exception using
      errcode = 'DP011',
      message = format('Payroll for %s is already finalised, so its deductions '
                       'can no longer be changed.',
                       to_char(v_row.period_month, 'Mon YYYY')),
      detail  = json_build_object('period_month', v_row.period_month)::text;
  end if;

  delete from public.staff_adjustments where id = p_id;

  return jsonb_build_object('id', p_id, 'removed', true,
                            'profile_id', v_row.profile_id,
                            'period_month', v_row.period_month,
                            'amount', v_row.amount);
end;
$fn$;

grant execute on function public.remove_staff_adjustment(uuid) to authenticated;

-- =============================================================================
-- The read models, rebuilt to match what a payslip now says
--
-- security_invoker = on, so the policies on payslips still apply through the
-- view. Without it the view would run as its owner and hand every worker the
-- whole payroll.
-- =============================================================================

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
  s.monthly_salary,
  s.deductions_amount,
  s.advance_recovered,
  s.net_payable,
  s.created_at
from public.payslips s
join public.payroll_periods pp on pp.id = s.payroll_period_id
join public.profiles p on p.id = s.profile_id;

-- Everyone on the payroll with the salary they are on and what they have drawn
-- against it — the two numbers the factory works from day to day.
--
-- The salary shown is the one in force today, not the latest row on file: a
-- raise dated next month is not what somebody is paid this month. Any such raise
-- is reported separately rather than hidden, so the roster can say both.
--
-- A worker sees only their own row. Under security_invoker alone they would see
-- every colleague listed with a blank salary, since profiles is readable but
-- salary_structures is not: no leak, but a roster that looks like everybody is
-- unpaid.
drop view if exists public.v_staff_pay;
create view public.v_staff_pay with (security_invoker = on) as
select
  p.id                       as profile_id,
  p.employee_code,
  p.name                     as staff_name,
  p.role,
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
where p.active
  and (app.is_admin() or p.id = app.current_profile_id());

-- Deductions waiting to land on a payslip. Administrators only, which the
-- policy on staff_adjustments already says; the view inherits it.
drop view if exists public.v_staff_deductions;
create view public.v_staff_deductions with (security_invoker = on) as
select
  a.id,
  a.profile_id,
  p.employee_code,
  p.name         as staff_name,
  a.period_month,
  a.label,
  a.amount,
  a.remarks,
  a.created_at
from public.staff_adjustments a
join public.profiles p on p.id = a.profile_id
where a.component_type = 'DEDUCTION';

-- One row per month: what the factory owes, and whether it is still editable.
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
  pp.finalised_at
from public.payroll_periods pp
left join public.payslips s on s.payroll_period_id = pp.id
where app.is_admin()
group by pp.id, pp.period_month, pp.status, pp.finalised_at;


-- -----------------------------------------------------------------------------
-- 0020_worker_profiles_and_salary_payments.sql
-- -----------------------------------------------------------------------------

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


-- -----------------------------------------------------------------------------
-- 0021_employee_types_and_any_machine.sql
-- -----------------------------------------------------------------------------

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


-- -----------------------------------------------------------------------------
-- 0022_employee_roles_master.sql
-- -----------------------------------------------------------------------------

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


-- -----------------------------------------------------------------------------
-- 0023_retire_unread_setting.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0023_retire_unread_setting.sql — a setting nothing reads (A42)
--
-- `recycled_input_mode` was written in 0007 to record a decision: shredded pipe
-- is stocked as a RECYCLED-category raw material and mixed through
-- consume_raw_materials() like any other input.
--
-- That decision holds. What never existed is any code that reads the setting —
-- not a migration, not an RPC, not the app. Changing it would do nothing at
-- all, which is the worst kind of switch to leave on a configuration screen.
--
-- The same reasoning retired four payroll settings in 0019: a setting nobody
-- reads is a promise the system has stopped keeping. The decision it recorded
-- stays, in the comment on shred_pipe() and in docs/04-pipe-manufacturing.md,
-- where a decision belongs.
-- =============================================================================

delete from public.app_settings where key = 'recycled_input_mode';

-- low_stock_banner_enabled is the same thing, found by the same check. It was
-- seeded with "Show the low-stock banner on the admin dashboard", and the
-- dashboard shows that banner whenever something is actually low, regardless of
-- this value. Turning it off did nothing then and does nothing now.
delete from public.app_settings where key = 'low_stock_banner_enabled';

-- -----------------------------------------------------------------------------
-- While we are here: say what the two live switches actually do
--
-- The Configuration screen shows each setting's description beneath its name,
-- so these are what an administrator reads before changing a rule. Both were
-- written for whoever was reading the migration, not for them.
-- -----------------------------------------------------------------------------

update public.app_settings
set description =
  'Refuse production of a product the machine is not set up to run. Machines '
  'with no products configured are unconstrained either way, so this only '
  'binds once somebody has said which machine runs what.'
where key = 'enforce_machine_product';

update public.app_settings
set description =
  'A shred may not recover more than the bundle weighed plus this percentage. '
  'Recovering more mass than went in is impossible, so this catches a mistyped '
  'weight before it corrupts stock. Raise it if the weight specs are rough.'
where key = 'shred_recovery_tolerance_pct';


-- -----------------------------------------------------------------------------
-- 0024_entry_dates_and_wastage_access.sql
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 0024_entry_dates_and_wastage_access.sql — two holes found in the audit
--
--   A45. consume_reusable_wastage() was the one stock-moving write any signed-in
--        person could call. Every other one is admin-only or goes through
--        app.assert_can_record(). Now it is admin-only too.
--
--   A46. An entry's date was limited by the date picker and by nothing else.
--        The rule now lives in the database, where it applies to every path.
--
-- Both are enforcement, not behaviour: nothing that was allowed through the app
-- stops being allowed. Safe to re-run. Requires 0001–0023.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A46. How far back an entry may be dated
--
-- The production form has always offered the last 30 days and no future, which
-- is the right rule and was in the wrong place: the UI. "Do not rely only on
-- hiding the button" is the standard the rest of this schema is held to, and a
-- date that moves stock is exactly the kind of field that deserves it.
--
-- A setting rather than a constant, because a factory that closes its books
-- monthly wants a different window from one that does not — and because the
-- Configuration screen is where that decision belongs.
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description)
values (
  'entry_backdating_days',
  '30',
  'How many days back an entry may be dated. 0 means today only. '
  'Future dates are never allowed.'
)
on conflict (key) do nothing;

create or replace function app.assert_entry_date(
  p_date  date,
  p_field text default 'entry_date'
)
returns date
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  v_days  integer := greatest(
    coalesce(nullif(app.setting('entry_backdating_days', '30'), '')::integer, 30),
    0);
  -- The factory's today, not the server's. Reports bucket by the factory
  -- timezone, so the window an entry is measured against has to use the same
  -- clock or the two disagree for five and a half hours every night.
  v_today date := (now() at time zone
                   app.setting('factory_timezone', 'Asia/Kolkata'))::date;
begin
  if p_date is null then
    return v_today;
  end if;

  if p_date > v_today then
    raise exception using
      errcode = 'DP005',
      message = 'An entry cannot be dated in the future.',
      detail  = json_build_object('field', p_field,
                                  'date', p_date,
                                  'today', v_today)::text;
  end if;

  if p_date < v_today - v_days then
    raise exception using
      errcode = 'DP005',
      message = format('An entry cannot be dated more than %s days back. '
                       'Change "How many days back an entry may be dated" '
                       'in Settings if the factory needs longer.', v_days),
      detail  = json_build_object('field', p_field,
                                  'date', p_date,
                                  'earliest', v_today - v_days)::text;
  end if;

  return p_date;
end;
$fn$;

comment on function app.assert_entry_date(date, text) is
  'A46: refuses a future date, or one older than entry_backdating_days.';

-- Triggers rather than edits to five RPC bodies.
--
-- The RPCs are the only write path today — these tables have no INSERT policy —
-- but a rule about what a row may contain belongs on the table, where a
-- migration that adds a sixth write path inherits it instead of forgetting it.
-- Only INSERT: history is not re-judged by a window that moved under it.

create or replace function app.check_entry_date()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fn$
begin
  if tg_argv[0] = 'dispatch_date' then
    perform app.assert_entry_date(new.dispatch_date, 'dispatch_date');
  else
    perform app.assert_entry_date(new.entry_date, 'entry_date');
  end if;
  return new;
end;
$fn$;

do $mig$
declare
  r record;
begin
  for r in
    select * from (values
      ('production_entries', 'entry_date'),
      ('mixture_entries',    'entry_date'),
      ('wastage_entries',    'entry_date'),
      ('shred_entries',      'entry_date'),
      ('dispatches',         'dispatch_date')
    ) as t(tbl, col)
  loop
    execute format(
      'drop trigger if exists %I on public.%I', r.tbl || '_entry_date_ck', r.tbl);
    execute format(
      'create trigger %I before insert on public.%I '
      'for each row execute function app.check_entry_date(%L)',
      r.tbl || '_entry_date_ck', r.tbl, r.col);
  end loop;
end
$mig$;

-- -----------------------------------------------------------------------------
-- A45. Consuming recycled stock is an administrator's act
--
-- It moves a factory-wide balance that belongs to nobody's machine, so there is
-- no "their own" for app.assert_can_record() to check — which is why it had no
-- guard at all rather than the wrong one. Admin-only is the answer the rest of
-- the stock maintenance functions already use.
--
-- The body below is unchanged except for that first line.
-- -----------------------------------------------------------------------------

create or replace function public.consume_reusable_wastage(
  p_raw_material_id uuid,
  p_quantity        numeric,
  p_client_ref      uuid,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller uuid := app.require_admin();   -- A45: was app.require_profile()
  v_mode   text := app.setting('reusable_wastage_mode', 'SEPARATE');
  v_txn    uuid;
  v_left   numeric(14, 3);
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Quantity must be greater than zero.',
      detail  = '{"field":"quantity"}';
  end if;

  if v_mode <> 'SEPARATE' then
    -- A9: the substitution ratio is a business rule the factory has not
    -- defined. Failing loudly beats inventing arithmetic that corrupts stock.
    raise exception using
      errcode = 'DP007',
      message = 'Reusable-wastage substitution is not configured yet.',
      detail  = json_build_object('mode', v_mode)::text;
  end if;

  if exists (select 1 from public.reusable_wastage_transactions
             where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_reusable_movement(
    p_raw_material_id, 'CONSUMED', -p_quantity, v_caller,
    p_client_ref, 'manual', p_remarks
  );

  select quantity into v_left
  from public.reusable_wastage_stock
  where raw_material_id = p_raw_material_id;

  return jsonb_build_object('transaction_id', v_txn,
                            'duplicate', false,
                            'remaining', v_left);
end;
$fn$;

grant execute on function public.consume_reusable_wastage(uuid, numeric, uuid, text)
  to authenticated;
grant execute on function app.assert_entry_date(date, text) to authenticated;

