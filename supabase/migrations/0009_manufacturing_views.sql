-- =============================================================================
-- 0009_manufacturing_views.sql — read models for the manufacturing loop
--
-- Every view is created WITH (security_invoker = on) so it runs with the
-- querying user's rights and the RLS underneath still applies. Without it a view
-- silently becomes a hole in the security model.
--
-- The views added here exist for one reason above all others: now that a bundle
-- has a weight, kilograms in and kilograms out are finally comparable, and the
-- factory can be asked the only question that really matters — where did the
-- material go?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Product catalogue with live stock, in both units
-- -----------------------------------------------------------------------------

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
  s.updated_at
from public.pipe_products p
join public.pipe_types t on t.id = p.pipe_type_id
join public.pipe_sizes z on z.id = p.pipe_size_id
left join public.finished_goods_stock s
       on s.pipe_type_id = p.pipe_type_id
      and s.pipe_size_id = p.pipe_size_id;

-- -----------------------------------------------------------------------------
-- What each machine is set up to run.
--
-- A machine with no rows in machine_products is unconstrained, and that is a
-- meaningful state rather than an empty one, so it is reported explicitly as
-- `unconstrained` instead of simply vanishing from the list.
-- -----------------------------------------------------------------------------

create or replace view public.v_machine_products with (security_invoker = on) as
select
  m.id            as machine_id,
  m.code          as machine_code,
  m.name          as machine_name,
  m.status        as machine_status,
  mp.pipe_product_id,
  p.sku,
  t.name          as pipe_type_name,
  z.name          as pipe_size_name,
  z.diameter_mm,
  p.bundle_weight_kg,
  mp.active       as capability_active,
  not exists (
    select 1 from public.machine_products x
    where x.machine_id = m.id and x.active
  )               as unconstrained
from public.machines m
left join public.machine_products mp on mp.machine_id = m.id
left join public.pipe_products p on p.id = mp.pipe_product_id
left join public.pipe_types t on t.id = p.pipe_type_id
left join public.pipe_sizes z on z.id = p.pipe_size_id
where m.active;

-- -----------------------------------------------------------------------------
-- Recycled stock, split out from virgin material
-- -----------------------------------------------------------------------------

create or replace view public.v_recycled_material_stock with (security_invoker = on) as
select
  m.id                    as raw_material_id,
  m.code,
  m.name,
  m.unit,
  m.minimum_stock,
  coalesce(s.quantity, 0) as quantity,
  coalesce(r.total_recovered, 0) as total_recovered_kg,
  coalesce(c.total_consumed, 0)  as total_consumed_kg,
  s.updated_at
from public.raw_materials m
left join public.raw_material_stock s on s.raw_material_id = m.id
left join (
  select raw_material_id, sum(quantity) as total_recovered
  from public.raw_material_transactions
  where transaction_type = 'SHRED_RETURN'
  group by raw_material_id
) r on r.raw_material_id = m.id
left join (
  select raw_material_id, -sum(quantity) as total_consumed
  from public.raw_material_transactions
  where transaction_type = 'PRODUCTION_CONSUMPTION'
  group by raw_material_id
) c on c.raw_material_id = m.id
where m.is_recycled and m.active;

-- -----------------------------------------------------------------------------
-- The shred log, readable
-- -----------------------------------------------------------------------------

create or replace view public.v_shred_entries with (security_invoker = on) as
select
  e.id,
  e.entry_date,
  e.source,
  e.pipe_type_id,
  t.name                  as pipe_type_name,
  e.pipe_size_id,
  z.name                  as pipe_size_name,
  z.diameter_mm,
  e.bundle_quantity,
  e.recovered_kg,
  e.expected_kg,
  case
    when e.expected_kg is null or e.expected_kg = 0 then null
    else round(e.recovered_kg / e.expected_kg * 100, 2)
  end                     as recovery_pct,
  case
    when e.expected_kg is null then null
    else e.expected_kg - e.recovered_kg
  end                     as lost_kg,
  e.recycled_material_id,
  rm.name                 as recycled_material_name,
  e.machine_id,
  mc.name                 as machine_name,
  e.operator_id,
  o.name                  as operator_name,
  e.shift_id,
  sh.name                 as shift_name,
  e.production_entry_id,
  e.remarks,
  e.created_at
from public.shred_entries e
join public.pipe_types t on t.id = e.pipe_type_id
join public.pipe_sizes z on z.id = e.pipe_size_id
join public.raw_materials rm on rm.id = e.recycled_material_id
left join public.machines mc on mc.id = e.machine_id
left join public.profiles o on o.id = e.operator_id
left join public.shifts sh on sh.id = e.shift_id;

-- -----------------------------------------------------------------------------
-- Material balance per machine per day — the point of all of this
--
-- kilograms consumed  =  kilograms shipped as product
--                      + kilograms reground and returned
--                      + kilograms genuinely lost
--                      + whatever is unaccounted for
--
-- Only PRODUCTION_REJECT shreds count against the day's consumption: they are
-- regrind from the material mixed that day. A FINISHED_BUNDLE shred destroys
-- product made on some earlier day, so folding it in here would credit today's
-- run with material it never consumed. It is reported alongside, not inside.
--
-- `unaccounted_kg` near zero means the day reconciles. A persistent positive
-- figure means material is leaving without being recorded.
-- -----------------------------------------------------------------------------

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

-- -----------------------------------------------------------------------------
-- The same balance rolled up to the whole factory, one row per day
-- -----------------------------------------------------------------------------

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

-- -----------------------------------------------------------------------------
-- Production entries, with the weight each was recorded against.
--
-- 0003 already publishes v_production_entries; this is the weighted companion
-- rather than a replacement, so nothing already reading that view changes shape.
-- -----------------------------------------------------------------------------

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
  e.created_at
from public.production_entries e
join public.machines mc on mc.id = e.machine_id
join public.profiles o on o.id = e.operator_id
join public.shifts sh on sh.id = e.shift_id
join public.pipe_types t on t.id = e.pipe_type_id
join public.pipe_sizes z on z.id = e.pipe_size_id
left join public.pipe_products p on p.id = e.pipe_product_id;
