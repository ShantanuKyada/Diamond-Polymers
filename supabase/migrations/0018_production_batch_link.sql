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
