-- =============================================================================
-- seed.sql — development / demo data (§57)
--
-- Safe to re-run: master rows are upserted on fixed UUIDs, and the movement
-- section is skipped once any ledger row exists, so balances are never
-- double-posted.
--
-- Run AFTER 0001..0005. Every movement goes through the same app.apply_*
-- helpers the application uses, so the seeded balances and the seeded ledger
-- agree by construction — v_stock_reconciliation should come back all-true.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Settings (A7, A9)
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description) values
  ('factory_name', 'Diamond Polymers',
   'Displayed in the app header and on reports.'),
  ('production_wastage_unit', 'kg',
   'A7: unit for production_entries.wastage_quantity.'),
  ('reusable_wastage_mode', 'SEPARATE',
   'A9: SEPARATE keeps reusable wastage out of raw-material stock. SUBSTITUTE is not implemented.'),
  ('currency_symbol', '₹',
   'Currency shown on payroll screens.'),
  ('low_stock_banner_enabled', 'true',
   'Show the low-stock banner on the admin dashboard.')
on conflict (key) do update set description = excluded.description;

-- -----------------------------------------------------------------------------
-- Master data
-- -----------------------------------------------------------------------------

insert into public.raw_material_categories (code, name) values
  ('RAIZIN',   'Raizin'),
  ('CHEMICAL', 'Chemical'),
  ('COLOR',    'Color')
on conflict (code) do update set name = excluded.name;

-- Thresholds are set so the demo shows one material LOW and the rest healthy
-- after three days of running: see the opening-stock figures further down.
insert into public.raw_materials (id, code, name, category, unit, minimum_stock, is_recycled) values
  ('55555555-5555-4555-8555-000000000001', 'RM-RAIZIN', 'Raizin',   'RAIZIN',   'kg', 2000, false),
  ('55555555-5555-4555-8555-000000000002', 'RM-CHEM',   'Chemical', 'CHEMICAL', 'kg',  400, false),
  ('55555555-5555-4555-8555-000000000003', 'RM-COLOR',  'Color',    'COLOR',    'kg',  100, false),
  -- Regrind: shredded pipe, held as an ordinary raw material (A20). One pool per
  -- pipe type, because heavy-duty regrind must not go into a standard pipe.
  -- No minimum: running out of regrind is normal, not a problem worth alerting on.
  ('55555555-5555-4555-8555-000000000004', 'RM-REGRIND-A', 'Regrind — Standard',
   'RECYCLED', 'kg', 0, true),
  ('55555555-5555-4555-8555-000000000005', 'RM-REGRIND-B', 'Regrind — Heavy Duty',
   'RECYCLED', 'kg', 0, true)
on conflict (id) do update
  set name          = excluded.name,
      category      = excluded.category,
      minimum_stock = excluded.minimum_stock,
      is_recycled   = excluded.is_recycled;

insert into public.machines (id, code, name, description, status) values
  ('11111111-1111-4111-8111-000000000001', 'M1', 'Machine 1', 'Braiding line 1', 'ACTIVE'),
  ('11111111-1111-4111-8111-000000000002', 'M2', 'Machine 2', 'Braiding line 2', 'ACTIVE'),
  ('11111111-1111-4111-8111-000000000003', 'M3', 'Machine 3', 'Braiding line 3', 'ACTIVE'),
  ('11111111-1111-4111-8111-000000000004', 'M4', 'Machine 4', 'Braiding head service due', 'MAINTENANCE')
on conflict (id) do update
  set name = excluded.name, status = excluded.status;

-- Exactly two shifts (A29). They cover the whole day between them.
insert into public.shifts (id, name, start_time, end_time) values
  ('22222222-2222-4222-8222-000000000001', 'Morning', '06:00', '18:00'),
  ('22222222-2222-4222-8222-000000000003', 'Night',   '18:00', '06:00')
on conflict (id) do update
  set start_time = excluded.start_time, end_time = excluded.end_time;

insert into public.pipe_types (id, code, name, description) values
  ('33333333-3333-4333-8333-000000000001', 'TA', 'Type A', 'Standard braided'),
  ('33333333-3333-4333-8333-000000000002', 'TB', 'Type B', 'Heavy-duty braided')
on conflict (id) do update set name = excluded.name;

insert into public.pipe_sizes (id, code, name, description, sort_order, diameter_mm, length_m) values
  ('44444444-4444-4444-8444-000000000001', 'S1', 'Size 1', '1/2 inch',  1, 12.70, 100),
  ('44444444-4444-4444-8444-000000000002', 'S2', 'Size 2', '3/4 inch',  2, 19.05, 100),
  ('44444444-4444-4444-8444-000000000003', 'S3', 'Size 3', '1 inch',    3, 25.40,  50),
  ('44444444-4444-4444-8444-000000000004', 'S4', 'Size 4', '1.25 inch', 4, 31.75,  50)
on conflict (id) do update
  set name        = excluded.name,
      sort_order  = excluded.sort_order,
      diameter_mm = excluded.diameter_mm,
      length_m    = excluded.length_m;

-- Which regrind pool each pipe type's shredded output returns to (A20).
update public.pipe_types set recycled_material_id = '55555555-5555-4555-8555-000000000004'
  where id = '33333333-3333-4333-8333-000000000001';
update public.pipe_types set recycled_material_id = '55555555-5555-4555-8555-000000000005'
  where id = '33333333-3333-4333-8333-000000000002';

-- -----------------------------------------------------------------------------
-- Products and their bundle weights (A21)
--
-- The kg <-> bundle conversion, and therefore the number every material balance
-- below rests on. Weight rises with diameter, and a heavy-duty wall is heavier
-- than a standard one at the same diameter. In production these must come from
-- the factory, not from here.
--
-- These live in seed.sql rather than the manufacturing seed for one reason: the
-- movement block further down sizes its mixtures from these weights, so a batch
-- and the bundles it yields are physically consistent. That is only possible if
-- the weights already exist when the movements are posted.
-- -----------------------------------------------------------------------------

insert into public.pipe_products
  (id, pipe_type_id, pipe_size_id, sku, bundle_weight_kg, pipes_per_bundle,
   coil_length_m, pipes_per_bag)
values
  ('88888888-8888-4888-8888-000000000001', '33333333-3333-4333-8333-000000000001',
   '44444444-4444-4444-8444-000000000001', 'TA-S1', 18.500, 10, 100, 20),
  ('88888888-8888-4888-8888-000000000002', '33333333-3333-4333-8333-000000000001',
   '44444444-4444-4444-8444-000000000002', 'TA-S2', 24.000,  8, 100, 16),
  ('88888888-8888-4888-8888-000000000003', '33333333-3333-4333-8333-000000000001',
   '44444444-4444-4444-8444-000000000003', 'TA-S3', 31.500,  6,  50, 12),
  ('88888888-8888-4888-8888-000000000004', '33333333-3333-4333-8333-000000000001',
   '44444444-4444-4444-8444-000000000004', 'TA-S4', 40.000,  5,  50, null),
  ('88888888-8888-4888-8888-000000000005', '33333333-3333-4333-8333-000000000002',
   '44444444-4444-4444-8444-000000000001', 'TB-S1', 22.000, 10, 100, 20),
  ('88888888-8888-4888-8888-000000000006', '33333333-3333-4333-8333-000000000002',
   '44444444-4444-4444-8444-000000000002', 'TB-S2', 28.500,  8, 100, 16),
  ('88888888-8888-4888-8888-000000000007', '33333333-3333-4333-8333-000000000002',
   '44444444-4444-4444-8444-000000000003', 'TB-S3', 37.000,  6,  50, 12),
  ('88888888-8888-4888-8888-000000000008', '33333333-3333-4333-8333-000000000002',
   '44444444-4444-4444-8444-000000000004', 'TB-S4', 47.500,  5,  50, null)
on conflict (id) do update
  set sku              = excluded.sku,
      bundle_weight_kg = excluded.bundle_weight_kg,
      pipes_per_bundle = excluded.pipes_per_bundle,
      pipes_per_bag    = excluded.pipes_per_bag,
      coil_length_m    = excluded.coil_length_m;

-- Machine capabilities (A23). M1 to M3 run everything, which keeps them
-- consistent with the production posted below. M4 is deliberately left with no
-- rows, to exercise the other half of the rule: a machine with nothing
-- configured is unconstrained.
--
--   To restrict a line later:
--     select public.set_machine_products('<machine uuid>', array['<product uuid>']::uuid[]);
insert into public.machine_products (machine_id, pipe_product_id)
select m.id, p.id
from public.machines m
cross join public.pipe_products p
where m.code in ('M1', 'M2', 'M3')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- People
--
-- Profiles exist independently of auth logins (A3). Linking a login is the
-- separate step at the bottom of this file.
-- -----------------------------------------------------------------------------

insert into public.profiles (id, name, employee_code, role, phone) values
  ('66666666-6666-4666-8666-000000000001', 'Factory Admin',  'EMP-001', 'ADMIN',    null),
  ('66666666-6666-4666-8666-000000000002', 'Ravi Kumar',     'EMP-101', 'OPERATOR', null),
  ('66666666-6666-4666-8666-000000000003', 'Suresh Patel',   'EMP-102', 'OPERATOR', null),
  ('66666666-6666-4666-8666-000000000004', 'Imran Shaikh',   'EMP-103', 'OPERATOR', null),
  ('66666666-6666-4666-8666-000000000005', 'Ganesh Jadhav',  'EMP-104', 'OPERATOR', null)
on conflict (id) do update
  set name = excluded.name, role = excluded.role;

insert into public.machine_assignments (id, machine_id, operator_id, shift_id, created_by) values
  ('77777777-7777-4777-8777-000000000001',
   '11111111-1111-4111-8111-000000000001',
   '66666666-6666-4666-8666-000000000002',
   '22222222-2222-4222-8222-000000000001',
   '66666666-6666-4666-8666-000000000001'),
  ('77777777-7777-4777-8777-000000000002',
   '11111111-1111-4111-8111-000000000002',
   '66666666-6666-4666-8666-000000000003',
   '22222222-2222-4222-8222-000000000001',
   '66666666-6666-4666-8666-000000000001'),
  ('77777777-7777-4777-8777-000000000003',
   '11111111-1111-4111-8111-000000000003',
   '66666666-6666-4666-8666-000000000004',
   '22222222-2222-4222-8222-000000000003',
   '66666666-6666-4666-8666-000000000001'),
  ('77777777-7777-4777-8777-000000000004',
   '11111111-1111-4111-8111-000000000004',
   '66666666-6666-4666-8666-000000000005',
   '22222222-2222-4222-8222-000000000003',
   '66666666-6666-4666-8666-000000000001')
on conflict (id) do nothing;

-- Finished-goods reorder thresholds (§13, §23).
insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles, minimum_stock)
select t.id, z.id, 0, 15
from public.pipe_types t cross join public.pipe_sizes z
on conflict (pipe_type_id, pipe_size_id) do update
  set minimum_stock = excluded.minimum_stock;

-- =============================================================================
-- Movements. Skipped entirely if anything has already been posted, so re-running
-- this file never double-counts stock.
-- =============================================================================

do $seed$
declare
  v_admin   uuid := '66666666-6666-4666-8666-000000000001';
  v_raizin  uuid := '55555555-5555-4555-8555-000000000001';
  v_chem    uuid := '55555555-5555-4555-8555-000000000002';
  v_color   uuid := '55555555-5555-4555-8555-000000000003';
  v_type_a  uuid := '33333333-3333-4333-8333-000000000001';
  v_type_b  uuid := '33333333-3333-4333-8333-000000000002';
  v_ops     uuid[] := array[
              '66666666-6666-4666-8666-000000000002',
              '66666666-6666-4666-8666-000000000003',
              '66666666-6666-4666-8666-000000000004',
              '66666666-6666-4666-8666-000000000005'];
  v_machines uuid[] := array[
              '11111111-1111-4111-8111-000000000001',
              '11111111-1111-4111-8111-000000000002',
              '11111111-1111-4111-8111-000000000003',
              '11111111-1111-4111-8111-000000000004'];
  v_shifts  uuid[] := array[
              '22222222-2222-4222-8222-000000000001',
              '22222222-2222-4222-8222-000000000003'];
  v_sizes   uuid[] := array[
              '44444444-4444-4444-8444-000000000001',
              '44444444-4444-4444-8444-000000000002',
              '44444444-4444-4444-8444-000000000003',
              '44444444-4444-4444-8444-000000000004'];
  d          date;
  i          int;
  v_op       uuid;
  v_machine  uuid;
  v_shift    uuid;
  v_entry    uuid;
  v_mix      uuid;
  v_raizin_q numeric;
  v_chem_q   numeric;
  v_color_q  numeric;
  v_dispatch uuid;
  v_size     uuid;
  -- The production plan for one machine-day, decided before the mixture is
  -- sized so the batch and the bundles it yields are physically consistent.
  v_types    uuid[];
  v_szs      uuid[];
  v_bundles  int[];
  v_weights  numeric[];
  v_out_kg   numeric;       -- kilograms of good product from the plan
  v_consumed numeric;       -- kilograms the batch has to contain to yield it
  k          int;
  -- 96% yield: the missing 4% is purge, offcuts and trim, recorded as wastage on
  -- the entries so consumed - produced - wastage comes out at zero.
  c_yield    constant numeric := 0.96;
begin
  if exists (select 1 from public.raw_material_transactions) then
    raise notice 'Seed movements already present — skipping.';
    return;
  end if;

  -- Opening raw-material stock ------------------------------------------------
  --
  -- Derived, not guessed. The block below runs the same plan the movement loop
  -- will run, totals the kilograms it needs, and opens stock to cover it. Change
  -- the bundle counts or the weights and the opening stock follows; a hand-typed
  -- figure would silently start failing with DP001 half way through the seed.
  -- gj / gk rather than j / k: those names are plpgsql variables in this block,
  -- and Postgres refuses a query where a column reference could mean either.
  select sum(plan.bundles * p.bundle_weight_kg) / c_yield
  into   v_consumed
  from (
    select 18 + ((gj * gk * 7) % 15) as bundles,
           case when (gj + gk) % 2 = 0 then v_type_a else v_type_b end as type_id,
           v_sizes[1 + ((gj + gk) % 4)] as size_id
    from generate_series(0, 2) gi,
         generate_series(1, 4) gj,
         generate_series(1, 2) gk
  ) plan
  join public.pipe_products p
    on p.pipe_type_id = plan.type_id and p.pipe_size_id = plan.size_id;

  -- Raizin and Color open with 15% headroom so they finish healthy. Chemical
  -- opens with only 350 kg to spare, so it ends just under its 400 kg threshold
  -- and the dashboard has a genuine LOW to show.
  perform app.apply_raw_movement(v_raizin, 'OPENING_STOCK',
            ceil(v_consumed * 25 / 32.0 * 1.15), v_admin,
            null, null, null, 'seed', 'Opening stock');
  perform app.apply_raw_movement(v_chem,   'OPENING_STOCK',
            ceil(v_consumed * 5 / 32.0) + 350, v_admin,
            null, null, null, 'seed', 'Opening stock');
  perform app.apply_raw_movement(v_color,  'OPENING_STOCK',
            ceil(v_consumed * 2 / 32.0 * 1.15), v_admin,
            null, null, null, 'seed', 'Opening stock');

  -- Opening finished goods ----------------------------------------------------
  foreach v_size in array v_sizes loop
    perform app.apply_fg_movement(v_type_a, v_size, 'OPENING_STOCK', 40, v_admin,
              null, 'seed', 'Opening stock');
    perform app.apply_fg_movement(v_type_b, v_size, 'OPENING_STOCK', 25, v_admin,
              null, 'seed', 'Opening stock');
  end loop;

  -- Three days of activity, today last ---------------------------------------
  for i in 0..2 loop
    d := current_date - i;

    for j in 1..4 loop
      v_op      := v_ops[j];
      v_machine := v_machines[j];
      v_shift   := v_shifts[1 + (j % 2)];

      -- Decide the shift's output first ---------------------------------------
      --
      -- The mixture is then sized to yield it. Doing it the other way round is
      -- what made the original demo data impossible: a 32 kg batch cannot
      -- produce twenty 31 kg bundles, and before bundles carried a weight there
      -- was no arithmetic that would say so.
      v_types   := array[]::uuid[];
      v_szs     := array[]::uuid[];
      v_bundles := array[]::int[];
      v_weights := array[]::numeric[];
      v_out_kg  := 0;

      for k in 1..2 loop
        v_types   := v_types   || (case when (j + k) % 2 = 0 then v_type_a else v_type_b end);
        v_szs     := v_szs     || v_sizes[1 + ((j + k) % 4)];
        v_bundles := v_bundles || (18 + ((j * k * 7) % 15));

        v_weights := v_weights || (
          select bundle_weight_kg from public.pipe_products
          where pipe_type_id = v_types[k] and pipe_size_id = v_szs[k]
        );

        v_out_kg := v_out_kg + v_bundles[k] * v_weights[k];
      end loop;

      -- Batch: the 25 / 5 / 2 recipe from the original seed, now scaled to the
      -- kilograms the shift actually needs.
      v_consumed := round(v_out_kg / c_yield, 3);
      v_raizin_q := round(v_consumed * 25 / 32.0, 3);
      v_chem_q   := round(v_consumed *  5 / 32.0, 3);
      -- Colour takes the remainder so the three lines sum to the batch exactly.
      v_color_q  := v_consumed - v_raizin_q - v_chem_q;

      insert into public.mixture_entries (
        entry_date, machine_id, operator_id, shift_id,
        total_quantity, client_ref, created_by, remarks
      )
      values (
        d, v_machine, v_op, v_shift,
        v_raizin_q + v_chem_q + v_color_q, gen_random_uuid(), v_op, 'Seed batch'
      )
      returning id into v_mix;

      insert into public.mixture_entry_lines (mixture_entry_id, raw_material_id, quantity) values
        (v_mix, v_raizin, v_raizin_q),
        (v_mix, v_chem,   v_chem_q),
        (v_mix, v_color,  v_color_q);

      perform app.apply_raw_movement(v_raizin, 'PRODUCTION_CONSUMPTION', -v_raizin_q,
                v_op, v_machine, v_op, v_mix, 'mixture_entries', null);
      perform app.apply_raw_movement(v_chem, 'PRODUCTION_CONSUMPTION', -v_chem_q,
                v_op, v_machine, v_op, v_mix, 'mixture_entries', null);
      perform app.apply_raw_movement(v_color, 'PRODUCTION_CONSUMPTION', -v_color_q,
                v_op, v_machine, v_op, v_mix, 'mixture_entries', null);

      -- Production: the two entries planned above, each carrying the bundle
      -- weight it was made at (A21) so output_weight_kg is fixed at recording.
      for k in 1..2 loop
        insert into public.production_entries (
          entry_date, machine_id, operator_id, shift_id,
          pipe_type_id, pipe_size_id, pipe_product_id,
          bundle_quantity, bundle_weight_kg, wastage_quantity,
          client_ref, created_by, remarks
        )
        values (
          d, v_machine, v_op, v_shift,
          v_types[k], v_szs[k],
          (select id from public.pipe_products
            where pipe_type_id = v_types[k] and pipe_size_id = v_szs[k]),
          v_bundles[k], v_weights[k],
          -- The shift's loss, split across its entries in proportion to output,
          -- so consumed - produced - wastage lands on zero.
          round(v_bundles[k] * v_weights[k] * (1 / c_yield - 1), 3),
          gen_random_uuid(), v_op, null
        )
        returning id into v_entry;

        perform app.apply_fg_movement(v_types[k], v_szs[k], 'PRODUCTION', v_bundles[k],
                  v_op, v_entry, 'production_entries', null);
      end loop;
    end loop;
  end loop;

  -- Wastage: one reusable scrap record and one genuine material loss (A8) -----
  insert into public.wastage_entries (
    entry_date, machine_id, operator_id, shift_id, raw_material_id,
    source, quantity, unit, reusable, client_ref, created_by, remarks
  )
  values (
    current_date, v_machines[1], v_ops[1], v_shifts[1], v_raizin,
    'PRODUCTION_SCRAP', 12.5, 'kg', true, gen_random_uuid(), v_ops[1],
    'Purge and offcuts, collected for reuse'
  )
  returning id into v_entry;

  -- PRODUCTION_SCRAP does not deduct raw stock; it only fills the reusable bin.
  perform app.apply_reusable_movement(v_raizin, 'RECOVERED', 12.5, v_ops[1],
            v_entry, 'wastage_entries', 'Collected for reuse');

  insert into public.wastage_entries (
    entry_date, machine_id, operator_id, shift_id, raw_material_id,
    source, quantity, unit, reusable, client_ref, created_by, remarks
  )
  values (
    current_date, v_machines[2], v_ops[2], v_shifts[1], v_chem,
    'RAW_MATERIAL_LOSS', 3.0, 'kg', false, gen_random_uuid(), v_ops[2],
    'Spillage during charging'
  )
  returning id into v_entry;

  -- RAW_MATERIAL_LOSS never entered a mixture, so it does come off raw stock.
  perform app.apply_raw_movement(v_chem, 'WASTAGE', -3.0, v_ops[2],
            v_machines[2], v_ops[2], v_entry, 'wastage_entries', 'Spillage');

  -- A dispatch from yesterday -------------------------------------------------
  insert into public.dispatches (
    dispatch_date, customer_name, reference, vehicle_number,
    client_ref, created_by, remarks
  )
  values (
    current_date - 1, 'Shree Traders', 'DN-1042', 'MH-12-AB-4471',
    gen_random_uuid(), v_admin, 'Monthly order'
  )
  returning id into v_dispatch;

  insert into public.dispatch_lines (dispatch_id, pipe_type_id, pipe_size_id, bundle_quantity) values
    (v_dispatch, v_type_a, v_sizes[2], 30),
    (v_dispatch, v_type_b, v_sizes[3], 20);

  perform app.apply_fg_movement(v_type_a, v_sizes[2], 'DISPATCH', -30, v_admin,
            v_dispatch, 'dispatches', 'Monthly order');
  perform app.apply_fg_movement(v_type_b, v_sizes[3], 'DISPATCH', -20, v_admin,
            v_dispatch, 'dispatches', 'Monthly order');

  perform app.notify_role(
    'ADMIN', 'Dispatch completed',
    'Type A Size 2 — dispatched 30 bundles to Shree Traders.',
    'DISPATCH',
    json_build_object('dispatch_id', v_dispatch)::jsonb
  );

  perform app.notify_role(
    'ADMIN', 'Welcome',
    'Demo data has been loaded. Figures on the dashboard are seeded, not real production.',
    'SYSTEM', '{}'::jsonb
  );

  raise notice 'Seed movements posted.';
end
$seed$;

-- =============================================================================
-- Linking logins to profiles (A3)
--
-- Profiles above have no auth user yet, so nobody can sign in until you link one.
--
-- STEP 1 — create the users. Supabase Dashboard -> Authentication -> Users ->
--          "Add user", with "Auto Confirm User" ticked:
--
--            admin@diamondpolymers.local   (any password you choose)
--            ravi@diamondpolymers.local
--
-- STEP 2 — link each login to its profile by employee code:
--
--   update public.profiles p
--   set    auth_user_id = u.id
--   from   auth.users u
--   where  u.email = 'admin@diamondpolymers.local'
--     and  p.employee_code = 'EMP-001';
--
--   update public.profiles p
--   set    auth_user_id = u.id
--   from   auth.users u
--   where  u.email = 'ravi@diamondpolymers.local'
--     and  p.employee_code = 'EMP-101';
--
-- Creating auth users directly in SQL is deliberately NOT done here: the exact
-- shape of auth.users and auth.identities changes between GoTrue releases, and a
-- seed that silently produces an unusable login is worse than one that asks for
-- two clicks.
--
-- STEP 3 — verify the ledgers agree with the balances:
--
--   select * from public.v_stock_reconciliation where not ok;   -- expect 0 rows
-- =============================================================================
