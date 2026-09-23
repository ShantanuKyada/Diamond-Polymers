-- =============================================================================
-- seed_manufacturing.sql — the shredding loop, demonstrated once
--
-- Run AFTER 0006..0010 and AFTER seed.sql.
--
-- The manufacturing master data — size diameters, regrind pools, the eight
-- products and their bundle weights, machine capabilities — lives in seed.sql,
-- not here. It has to: seed.sql sizes its mixtures from the bundle weights so a
-- batch and the bundles it yields are physically consistent, which is only
-- possible if the weights already exist when those movements are posted.
--
-- What is left here is the part that has no equivalent in the original seed:
-- defective pipe becoming raw material again.
--
--   1. pipe rejected at the machine, before it was ever counted as a bundle
--   2. bundles pulled back out of stock and shredded
--   3. a mixture that feeds the resulting regrind back into the machine
--
-- Safe to re-run: the block is skipped once any shred exists, so stock is never
-- double-posted.
--
-- Posted through the same app.apply_* helpers the RPCs use, so the balances and
-- the ledgers agree by construction. The helpers are used directly rather than
-- calling shred_pipe(), because the SQL editor has no auth.uid() and the RPC
-- correctly refuses an unauthenticated caller.
-- =============================================================================

do $seed$
declare
  v_op1       uuid := '66666666-6666-4666-8666-000000000002';
  v_m1        uuid := '11111111-1111-4111-8111-000000000001';
  v_shift1    uuid := '22222222-2222-4222-8222-000000000001';
  v_type_a    uuid := '33333333-3333-4333-8333-000000000001';
  v_size_1    uuid := '44444444-4444-4444-8444-000000000001';
  v_prod_a1   uuid := '88888888-8888-4888-8888-000000000001';
  v_regrind_a uuid := '55555555-5555-4555-8555-000000000004';
  v_raizin    uuid := '55555555-5555-4555-8555-000000000001';
  v_chem      uuid := '55555555-5555-4555-8555-000000000002';
  v_weight    numeric(10, 3);
  v_bundles   integer := 2;
  v_expected  numeric(12, 3);
  v_shred     uuid;
  v_mix       uuid;
  v_regrind_q numeric := 10.000;
  v_raizin_q  numeric := 20.000;
  v_chem_q    numeric := 4.000;
begin
  if exists (select 1 from public.shred_entries) then
    raise notice 'Manufacturing seed already present — skipping.';
    return;
  end if;

  select bundle_weight_kg into v_weight
  from public.pipe_products where id = v_prod_a1;

  -- ---------------------------------------------------------------------------
  -- 1. Pipe rejected at the machine, before it was ever counted as a bundle.
  --    Finished goods are untouched; only the regrind enters stock.
  -- ---------------------------------------------------------------------------

  insert into public.shred_entries (
    entry_date, source, pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, recovered_kg, expected_kg, recycled_material_id,
    machine_id, operator_id, shift_id, client_ref, created_by, remarks
  )
  values (
    current_date, 'PRODUCTION_REJECT', v_type_a, v_size_1, v_prod_a1,
    null, 8.500, null, v_regrind_a,
    v_m1, v_op1, v_shift1, gen_random_uuid(), v_op1,
    'Off-spec run at start-up, shredded on the line'
  )
  returning id into v_shred;

  perform app.apply_raw_movement(
    v_regrind_a, 'SHRED_RETURN', 8.500, v_op1,
    v_m1, v_op1, v_shred, 'shred_entries', 'Start-up rejects'
  );

  -- ---------------------------------------------------------------------------
  -- 2. Bundles already counted into stock, later found defective. The bundles
  --    come out of finished goods and the regrind goes in, together.
  --    Two bundles at 18.5 kg hold 37 kg; 35.2 kg came back, so 1.8 kg was lost
  --    as dust and trim — which is exactly what recovery_pct is for.
  -- ---------------------------------------------------------------------------

  v_expected := v_bundles * v_weight;

  insert into public.shred_entries (
    entry_date, source, pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, recovered_kg, expected_kg, recycled_material_id,
    machine_id, operator_id, shift_id, client_ref, created_by, remarks
  )
  values (
    current_date, 'FINISHED_BUNDLE', v_type_a, v_size_1, v_prod_a1,
    v_bundles, 35.200, v_expected, v_regrind_a,
    v_m1, v_op1, v_shift1, gen_random_uuid(), v_op1,
    'Wall thickness out of tolerance, pulled from stock'
  )
  returning id into v_shred;

  -- Lock order: finished goods first, then raw material.
  perform app.apply_fg_movement(
    v_type_a, v_size_1, 'SHRED', -v_bundles, v_op1,
    v_shred, 'shred_entries', 'Defective bundles shredded'
  );

  perform app.apply_raw_movement(
    v_regrind_a, 'SHRED_RETURN', 35.200, v_op1,
    v_m1, v_op1, v_shred, 'shred_entries', 'Defective bundles shredded'
  );

  -- ---------------------------------------------------------------------------
  -- 3. The loop closes: the next mixture feeds 10 kg of that regrind back into
  --    the machine alongside virgin material. No special case — regrind is just
  --    another line on the mixture.
  --
  --    This batch is deliberately small and posts no production against itself,
  --    so it shows up in the balance as material still in the machine.
  -- ---------------------------------------------------------------------------

  insert into public.mixture_entries (
    entry_date, machine_id, operator_id, shift_id,
    total_quantity, client_ref, created_by, remarks
  )
  values (
    current_date, v_m1, v_op1, v_shift1,
    v_raizin_q + v_chem_q + v_regrind_q, gen_random_uuid(), v_op1,
    'Batch with 10 kg regrind'
  )
  returning id into v_mix;

  insert into public.mixture_entry_lines (mixture_entry_id, raw_material_id, quantity) values
    (v_mix, v_raizin,    v_raizin_q),
    (v_mix, v_chem,      v_chem_q),
    (v_mix, v_regrind_a, v_regrind_q);

  perform app.apply_raw_movement(v_raizin, 'PRODUCTION_CONSUMPTION', -v_raizin_q,
            v_op1, v_m1, v_op1, v_mix, 'mixture_entries', null);
  perform app.apply_raw_movement(v_chem, 'PRODUCTION_CONSUMPTION', -v_chem_q,
            v_op1, v_m1, v_op1, v_mix, 'mixture_entries', null);
  perform app.apply_raw_movement(v_regrind_a, 'PRODUCTION_CONSUMPTION', -v_regrind_q,
            v_op1, v_m1, v_op1, v_mix, 'mixture_entries', null);

  perform app.notify_role(
    'ADMIN', 'Bundles shredded — Type A Size 1',
    '2 bundles were shredded, recovering 35.2 kg of regrind.',
    'WASTAGE', '{}'::jsonb
  );

  raise notice 'Manufacturing seed posted.';
end
$seed$;

-- =============================================================================
-- Verify
--
--   select * from public.v_stock_reconciliation where not ok;   -- expect 0 rows
--   select * from public.v_pipe_products order by sku;
--   select * from public.v_production_material_balance order by entry_date desc;
--   select * from public.v_shred_entries;
--   select * from public.v_recycled_material_stock;
-- =============================================================================
