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
   'Currency shown on payroll screens.')
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

-- `role` is what somebody may see in the app; `employee_type` is what they do
-- for a living (A40). The administrator is office staff, not a machine
-- operator, and stating both here keeps the seed from relying on a column
-- default that would file them as one.
-- -----------------------------------------------------------------------------
-- The one account that has to exist
--
-- A factory starts with nobody on the system but the person setting it up.
-- Real staff are added in the app, under Employees — not here, because a seed
-- that invents people leaves somebody deleting strangers on their first day.
--
-- Sample staff, and a week of invented work, live in seed_sample.sql.
-- -----------------------------------------------------------------------------

insert into public.profiles
  (id, name, employee_code, role, employee_type_id, phone) values
  ('66666666-6666-4666-8666-000000000001', 'Factory Admin',  'EMP-001', 'ADMIN',
   (select id from public.employee_types where code = 'OFFICE'),  null)
on conflict (id) do update
  set name = excluded.name, role = excluded.role,
      employee_type_id = excluded.employee_type_id;


-- Finished-goods reorder thresholds (§13, §23).
insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles, minimum_stock)
select t.id, z.id, 0, 15
from public.pipe_types t cross join public.pipe_sizes z
on conflict (pipe_type_id, pipe_size_id) do update
  set minimum_stock = excluded.minimum_stock;

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
