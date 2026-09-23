-- =============================================================================
-- 0003_views.sql — read models (§52)
--
-- Every view is created WITH (security_invoker = on). Without it a view runs with
-- its owner's rights and silently bypasses the RLS on the tables underneath —
-- which would defeat §38 entirely.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Inventory read models
-- -----------------------------------------------------------------------------

create view public.v_raw_material_stock with (security_invoker = on) as
select
  m.id            as raw_material_id,
  m.code,
  m.name,
  m.category,
  c.name          as category_name,
  m.unit,
  m.minimum_stock,
  m.active,
  coalesce(s.quantity, 0) as quantity,
  case
    when coalesce(s.quantity, 0) <= 0 then 'OUT'
    when m.minimum_stock > 0 and coalesce(s.quantity, 0) <= m.minimum_stock then 'LOW'
    else 'GOOD'
  end             as status,
  s.updated_at
from public.raw_materials m
join public.raw_material_categories c on c.code = m.category
left join public.raw_material_stock s on s.raw_material_id = m.id;

-- The full type x size matrix (§30), including combinations never produced yet.
create view public.v_finished_goods_stock with (security_invoker = on) as
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
  s.updated_at
from public.pipe_types t
cross join public.pipe_sizes z
left join public.finished_goods_stock s
       on s.pipe_type_id = t.id and s.pipe_size_id = z.id
where t.active and z.active;

create view public.v_reusable_wastage_stock with (security_invoker = on) as
select
  m.id   as raw_material_id,
  m.code,
  m.name,
  m.unit,
  coalesce(s.quantity, 0) as quantity,
  s.updated_at
from public.raw_materials m
left join public.reusable_wastage_stock s on s.raw_material_id = m.id
where m.active;

-- -----------------------------------------------------------------------------
-- Assignments
-- -----------------------------------------------------------------------------

create view public.v_current_machine_assignments with (security_invoker = on) as
select
  a.id            as assignment_id,
  a.operator_id,
  p.name          as operator_name,
  p.employee_code,
  a.machine_id,
  mc.name         as machine_name,
  mc.code         as machine_code,
  mc.status       as machine_status,
  a.shift_id,
  sh.name         as shift_name,
  sh.start_time,
  sh.end_time,
  a.effective_from
from public.machine_assignments a
join public.profiles p  on p.id = a.operator_id
join public.machines mc on mc.id = a.machine_id
left join public.shifts sh on sh.id = a.shift_id
where a.active
  and a.effective_to is null;

-- -----------------------------------------------------------------------------
-- Mixtures — the "wide" shape §36 originally asked for, rebuilt from lines (A4)
-- -----------------------------------------------------------------------------

create view public.v_mixture_entries_wide with (security_invoker = on) as
select
  e.id,
  e.entry_date,
  e.machine_id,
  mc.name  as machine_name,
  e.operator_id,
  p.name   as operator_name,
  e.shift_id,
  sh.name  as shift_name,
  coalesce(sum(l.quantity) filter (where rm.category = 'RAIZIN'), 0)   as raizin_quantity,
  coalesce(sum(l.quantity) filter (where rm.category = 'CHEMICAL'), 0) as chemical_quantity,
  coalesce(sum(l.quantity) filter (where rm.category = 'COLOR'), 0)    as color_quantity,
  coalesce(sum(l.quantity) filter (
    where rm.category not in ('RAIZIN', 'CHEMICAL', 'COLOR')), 0)      as other_quantity,
  e.total_quantity,
  e.remarks,
  e.created_by,
  e.created_at
from public.mixture_entries e
join public.machines mc on mc.id = e.machine_id
join public.profiles p  on p.id = e.operator_id
join public.shifts sh   on sh.id = e.shift_id
left join public.mixture_entry_lines l on l.mixture_entry_id = e.id
left join public.raw_materials rm on rm.id = l.raw_material_id
group by e.id, mc.name, p.name, sh.name;

-- -----------------------------------------------------------------------------
-- Production read models
-- -----------------------------------------------------------------------------

create view public.v_production_entries with (security_invoker = on) as
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
  e.created_at
from public.production_entries e
join public.machines mc  on mc.id = e.machine_id
join public.profiles p   on p.id = e.operator_id
join public.shifts sh    on sh.id = e.shift_id
join public.pipe_types t on t.id = e.pipe_type_id
join public.pipe_sizes z on z.id = e.pipe_size_id;

create view public.v_daily_production_summary with (security_invoker = on) as
select
  entry_date,
  sum(bundle_quantity)  as total_bundles,
  sum(wastage_quantity) as total_wastage,
  count(*)              as entry_count
from public.production_entries
group by entry_date;

create view public.v_machine_production_summary with (security_invoker = on) as
select
  e.entry_date,
  e.machine_id,
  mc.name as machine_name,
  mc.code as machine_code,
  sum(e.bundle_quantity)  as total_bundles,
  sum(e.wastage_quantity) as total_wastage,
  count(*)                as entry_count
from public.production_entries e
join public.machines mc on mc.id = e.machine_id
group by e.entry_date, e.machine_id, mc.name, mc.code;

create view public.v_operator_production_summary with (security_invoker = on) as
select
  e.entry_date,
  e.operator_id,
  p.name          as operator_name,
  p.employee_code,
  sum(e.bundle_quantity)  as total_bundles,
  sum(e.wastage_quantity) as total_wastage,
  count(*)                as entry_count
from public.production_entries e
join public.profiles p on p.id = e.operator_id
group by e.entry_date, e.operator_id, p.name, p.employee_code;

-- -----------------------------------------------------------------------------
-- Dispatch read models
-- -----------------------------------------------------------------------------

create view public.v_dispatch_lines with (security_invoker = on) as
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
  l.bundle_quantity
from public.dispatches d
join public.dispatch_lines l on l.dispatch_id = d.id
join public.pipe_types t on t.id = l.pipe_type_id
join public.pipe_sizes z on z.id = l.pipe_size_id;

create view public.v_daily_dispatch_summary with (security_invoker = on) as
select
  d.dispatch_date,
  sum(l.bundle_quantity)      as total_bundles,
  count(distinct d.id)        as dispatch_count
from public.dispatches d
join public.dispatch_lines l on l.dispatch_id = d.id
group by d.dispatch_date;

-- -----------------------------------------------------------------------------
-- Wastage read model
-- -----------------------------------------------------------------------------

create view public.v_wastage_entries with (security_invoker = on) as
select
  w.id,
  w.entry_date,
  w.machine_id,
  mc.name as machine_name,
  w.operator_id,
  p.name  as operator_name,
  w.shift_id,
  sh.name as shift_name,
  w.raw_material_id,
  rm.name as raw_material_name,
  w.source,
  w.quantity,
  w.unit,
  w.reusable,
  w.remarks,
  w.created_by,
  w.created_at
from public.wastage_entries w
left join public.machines mc on mc.id = w.machine_id
left join public.profiles p  on p.id = w.operator_id
left join public.shifts sh   on sh.id = w.shift_id
join public.raw_materials rm on rm.id = w.raw_material_id;

-- -----------------------------------------------------------------------------
-- Reconciliation (§37) — proves the cached balances agree with the ledgers.
-- Any row with ok = false is a bug worth alerting on.
-- -----------------------------------------------------------------------------

create view public.v_stock_reconciliation with (security_invoker = on) as
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

-- -----------------------------------------------------------------------------
-- Notifications addressed to the caller, with per-person read state (A10).
-- RLS on `notifications` does the filtering; this view only adds `is_read`.
-- -----------------------------------------------------------------------------

create view public.v_my_notifications with (security_invoker = on) as
select
  n.id,
  n.title,
  n.message,
  n.type,
  n.metadata,
  n.created_at,
  exists (
    select 1
    from public.notification_reads r
    where r.notification_id = n.id
      and r.profile_id = app.current_profile_id()
  ) as is_read
from public.notifications n;
