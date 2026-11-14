-- =============================================================================
-- go_live_clear_demo_data.sql — empty the demonstration factory (one-off)
--
-- This is NOT a migration. It changes no schema and must never be added to the
-- migration list: it is a single destructive run, made once, on the day the
-- real factory starts using the app.
--
-- WHAT GOES
--   Every day-to-day record — production, mixtures, shredding, wastage,
--   dispatch, stock movements, stock balances, attendance, payroll, machine
--   assignments, notifications — and the demonstration catalogue of machines,
--   pipe types, sizes, products and raw materials.
--
-- WHAT STAYS
--   app_settings             your configuration, factory name and all
--   employee_types           Operator / Labourer / Office and anything added
--   shifts                   Morning and Night
--   raw_material_categories  Raizin, Chemical, Color, Recycled
--   profiles                 EMP-001 and EMP-101 only, logins intact
--
-- BEFORE RUNNING
--   1. Run checks/go_live_preflight.sql and read row 03. If somebody real has
--      been added who is not one of the two codes below, add their code to the
--      KEEP LIST in step 11 or they lose their record and their access.
--   2. Take a backup: Supabase dashboard → Database → Backups. There is no
--      undo. Everything below is gone for good.
--
-- The whole script runs as one transaction: if any statement fails, nothing is
-- deleted and you can fix the problem and run it again. Paste it into the
-- Supabase SQL editor and run it once. It ends with "Success. No rows
-- returned" — then run checks/go_live_verify.sql to see the result.
--
-- Order matters. Several of these foreign keys are ON DELETE RESTRICT, which
-- Postgres checks row by row rather than at the end of the statement, so a
-- child has to be emptied before its parent. Each section below says what
-- forces its position.
-- =============================================================================

begin;

-- 1. Notifications ----------------------------------------------------------
delete from public.notification_reads;
delete from public.notifications;

-- 2. Dispatch ---------------------------------------------------------------
-- Lines first: a line restricts the pipe size and type it shipped.
delete from public.dispatch_lines;
delete from public.dispatches;

-- 3. Finished goods ---------------------------------------------------------
-- The ledger, then the balance cache it adds up to.
delete from public.finished_goods_transactions;
delete from public.finished_goods_stock;

-- 4. Shredding --------------------------------------------------------------
-- Before production: a shred restricts the production entry whose bundle it
-- destroyed, so the shred has to go first.
delete from public.shred_entries;

-- 5. Wastage ----------------------------------------------------------------
delete from public.wastage_entries;
delete from public.reusable_wastage_transactions;
delete from public.reusable_wastage_stock;

-- 6. Production, then the batches it came out of ----------------------------
-- A production entry restricts its batch (A37), so entries go before mixtures.
delete from public.production_entries;
delete from public.mixture_entry_lines;
delete from public.mixture_entries;

-- 7. Raw material ledger and its balance cache ------------------------------
delete from public.raw_material_transactions;
delete from public.raw_material_stock;

-- 8. Payroll ----------------------------------------------------------------
-- Payments restrict the payslip they settle; components cascade from it.
delete from public.salary_payments;
delete from public.payslip_components;
delete from public.payslips;
delete from public.payroll_periods;
delete from public.staff_adjustments;
delete from public.advance_transactions;
delete from public.staff_advance_balance;
delete from public.salary_structures;
delete from public.attendance_days;

-- 9. Who was on which machine -----------------------------------------------
delete from public.machine_assignments;

-- 10. The demonstration catalogue -------------------------------------------
-- Machines keep a product list; products keep a weight history; a pipe type
-- points at the raw material its regrind is stocked as. Children first, and
-- raw materials last of all.
delete from public.machine_products;
delete from public.machines;
delete from public.pipe_product_weight_history;
delete from public.pipe_products;
delete from public.pipe_types;
delete from public.pipe_sizes;
delete from public.raw_materials;

-- 11. Everybody except the two who sign in ----------------------------------
--
-- KEEP LIST — the only place the two codes appear. If somebody real must also
-- survive, add their employee_code to all three lists below, exactly as it is
-- spelled in the Employees screen.
--
-- Settings and roles record who last touched them. Those references point at
-- profiles that are about to go, so they are released first; the settings and
-- the roles themselves are untouched.
update public.app_settings
set updated_by = null
where updated_by in (select id from public.profiles
                     where employee_code not in ('EMP-001', 'EMP-101'));

update public.employee_types
set created_by = null
where created_by in (select id from public.profiles
                     where employee_code not in ('EMP-001', 'EMP-101'));

delete from public.profiles
where employee_code not in ('EMP-001', 'EMP-101');

commit;

-- =============================================================================
-- One thing this script deliberately does not do
--
-- Deleting a profile does not delete the Supabase login behind it. If one of
-- the removed demonstration staff had an email linked, that account can still
-- authenticate — it just finds no profile and gets nowhere, because every
-- row-level-security policy in this database reads through profiles.
--
-- Tidy them up by hand where they belong: Supabase dashboard →
-- Authentication → Users. Row 04 of go_live_verify.sql lists any that are
-- left, so you know whether there is anything to do.
-- =============================================================================
