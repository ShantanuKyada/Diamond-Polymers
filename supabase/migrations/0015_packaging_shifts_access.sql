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
