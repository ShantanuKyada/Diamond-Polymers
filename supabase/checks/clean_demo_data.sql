-- =============================================================================
-- clean_demo_data.sql — hand the factory an empty system
--
-- Removes every invented record from a database that was seeded for
-- demonstration, and leaves the master data a factory cannot work without.
--
--   KEPT     machines, shifts, pipe types and sizes, products and their
--            packaging, raw material definitions and reorder levels, employee
--            types, configuration, and the administrator (EMP-001)
--
--   REMOVED  production, material batches, wastage, shredding, dispatch,
--            attendance, payroll, advances, salary structures, notifications,
--            every stock movement, and the sample operators
--
--   RESET    every raw material, finished goods and recycled balance to zero
--
-- Paste into the Supabase SQL editor and run. It is one transaction: if any
-- part fails, nothing is removed. Running it twice is harmless.
--
-- TAKE A BACKUP FIRST. This deletes data on purpose and there is no undo.
--
-- Tested by supabase/tests/clean_demo_data.test.mjs against a seeded database.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Records of work, children before parents.
--
-- The ledgers are append-only by design and carry no delete policy, which is
-- exactly right for the running app. This script is maintenance run by the
-- owner, not the app, so it deletes directly — and only here.
-- -----------------------------------------------------------------------------

delete from public.mixture_entry_lines;
delete from public.mixture_entries;

delete from public.shred_entries;
delete from public.wastage_entries;
delete from public.production_entries;

delete from public.dispatch_lines;
delete from public.dispatches;

delete from public.finished_goods_transactions;
delete from public.raw_material_transactions;
delete from public.reusable_wastage_transactions;

-- -----------------------------------------------------------------------------
-- 2. Pay and attendance
-- -----------------------------------------------------------------------------

delete from public.salary_payments;
delete from public.payslip_components;
delete from public.payslips;
delete from public.payroll_periods;
delete from public.staff_adjustments;
delete from public.advance_transactions;
delete from public.staff_advance_balance;
delete from public.salary_structures;
delete from public.attendance_days;

-- -----------------------------------------------------------------------------
-- 3. Notifications — all of them. They describe work that no longer exists.
-- -----------------------------------------------------------------------------

delete from public.notification_reads;
delete from public.notifications;

-- -----------------------------------------------------------------------------
-- 4. The sample operators
--
-- Everyone except the administrator and anybody who has since been given a
-- login — a real person added after go-live must not be swept away by this.
-- Their machine assignments go with them.
-- -----------------------------------------------------------------------------

delete from public.machine_assignments a
where exists (
  select 1 from public.profiles p
  where p.id = a.operator_id
    and p.role <> 'ADMIN'
    and p.auth_user_id is null
);

delete from public.pipe_product_weight_history;

delete from public.profiles
where role <> 'ADMIN'
  and auth_user_id is null;

-- -----------------------------------------------------------------------------
-- 5. Balances back to zero
--
-- The ledgers above are empty now, so any non-zero balance would disagree with
-- its history and v_stock_reconciliation would say so.
-- -----------------------------------------------------------------------------

update public.raw_material_stock set quantity = 0 where quantity <> 0;
update public.reusable_wastage_stock set quantity = 0 where quantity <> 0;

-- finished_goods_stock keeps its reorder thresholds; only the counts reset.
-- The guard trigger refuses a quantity change from anyone but the owner, which
-- is who runs this script.
update public.finished_goods_stock
set quantity_bundles = 0, quantity_bags = 0
where quantity_bundles <> 0 or quantity_bags <> 0;

commit;

-- =============================================================================
-- Check the result. Every row should read true.
-- =============================================================================

select 'no production, dispatch or material history' as check,
       not exists (select 1 from public.production_entries)
   and not exists (select 1 from public.dispatches)
   and not exists (select 1 from public.mixture_entries)
   and not exists (select 1 from public.wastage_entries) as ok
union all
select 'no payroll or attendance',
       not exists (select 1 from public.payslips)
   and not exists (select 1 from public.attendance_days)
   and not exists (select 1 from public.salary_payments)
union all
select 'no stock movements left',
       not exists (select 1 from public.raw_material_transactions)
   and not exists (select 1 from public.finished_goods_transactions)
union all
select 'every balance is zero',
       not exists (select 1 from public.raw_material_stock where quantity <> 0)
   and not exists (select 1 from public.finished_goods_stock
                   where quantity_bundles <> 0 or quantity_bags <> 0)
union all
select 'master data kept',
       exists (select 1 from public.machines)
   and exists (select 1 from public.shifts)
   and exists (select 1 from public.pipe_products)
   and exists (select 1 from public.raw_materials)
   and exists (select 1 from public.employee_types)
   and exists (select 1 from public.app_settings)
union all
select 'packaging rules kept',
       exists (select 1 from public.pipe_products where pipes_per_bag is not null)
   and not exists (select 1 from public.pipe_products where bundle_weight_kg <= 0)
union all
select 'an administrator remains',
       exists (select 1 from public.profiles where role = 'ADMIN')
union all
select 'ledgers and balances agree',
       not exists (select 1 from public.v_stock_reconciliation where not ok)
order by 1;
