-- =============================================================================
-- 0015_preflight.sql — run BEFORE applying 0015_packaging_shifts_access.sql
--
-- Paste into the Supabase SQL editor and run. Read the `ok` column: every row
-- must say true (or be an informational count) before you apply 0015.
--
-- Nothing here writes anything.
-- =============================================================================

select
  '1. Migrations 0001-0011 applied' as check,
  to_regclass('public.pipe_products') is not null as ok,
  coalesce(
    (select count(*)::text || ' products configured' from public.pipe_products),
    'pipe_products missing — apply 0001-0011 first') as detail

union all
select
  '2. Payroll 0012-0014 applied',
  to_regclass('public.payslips') is not null,
  case
    when to_regclass('public.payslips') is null
      then 'payslips missing — apply 0012-0014 first'
    else 'payroll tables present'
  end

union all
select
  '3. 0015 not applied yet',
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pipe_products'
      and column_name = 'pipes_per_bag'),
  case
    when exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'pipe_products'
        and column_name = 'pipes_per_bag')
      then 'ALREADY APPLIED — re-running is safe but unnecessary'
    else 'not applied; ready to apply'
  end

union all
select
  '4. Shifts that will be retired',
  true,
  coalesce((
    select string_agg(name || ' (' || case when active then 'active' else 'off' end || ')', ', ')
    from public.shifts
    where lower(btrim(name)) not in ('morning', 'night')
  ), 'none — only Morning and Night exist')

union all
select
  '5. Entries recorded against those shifts (kept, never deleted)',
  true,
  (select count(*)::text || ' production entries'
   from public.production_entries e
   join public.shifts s on s.id = e.shift_id
   where lower(btrim(s.name)) not in ('morning', 'night'))

union all
select
  '6. Operator assignments that will need a new shift',
  true,
  (select count(*)::text || ' assignment(s) — 0015 clears the shift and notifies admins'
   from public.machine_assignments a
   join public.shifts s on s.id = a.shift_id
   where a.active and a.effective_to is null
     and lower(btrim(s.name)) not in ('morning', 'night'))

union all
select
  '7. Ledgers currently reconcile',
  not exists (select 1 from public.v_stock_reconciliation where not ok),
  case
    when exists (select 1 from public.v_stock_reconciliation where not ok)
      then 'MISMATCH already present — investigate before migrating'
    else 'balances agree with their ledgers'
  end

order by 1;
