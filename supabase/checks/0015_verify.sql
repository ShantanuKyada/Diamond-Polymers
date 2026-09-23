-- =============================================================================
-- 0015_verify.sql — run AFTER applying 0015_packaging_shifts_access.sql
--
-- Every row must report ok = true. Nothing here writes anything.
-- =============================================================================

select
  '1. Packaging mapping on products' as check,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pipe_products'
      and column_name = 'pipes_per_bag') as ok,
  'pipe_products.pipes_per_bag' as detail

union all
select
  '2. Bag stock and its ledger',
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'finished_goods_stock'
      and column_name = 'quantity_bags')
  and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'finished_goods_transactions'
      and column_name = 'packaging'),
  'finished_goods_stock.quantity_bags + finished_goods_transactions.packaging'

union all
select
  '3. Production records bags and wastage used',
  (select count(*) = 3 from information_schema.columns
   where table_schema = 'public' and table_name = 'production_entries'
     and column_name in ('bag_quantity', 'wastage_used', 'wastage_used_kg')),
  'production_entries.bag_quantity, wastage_used, wastage_used_kg'

union all
select
  '4. Dispatch lines carry bags',
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dispatch_lines'
      and column_name = 'bag_quantity'),
  'dispatch_lines.bag_quantity'

union all
select
  '5. record_production accepts the new arguments',
  (select p.pronargs = 14 from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_production'),
  (select coalesce(array_to_string(p.proargnames, ', '), '') from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_production')

union all
select
  '6. Self-service profile function',
  to_regprocedure('public.update_my_profile(text, text)') is not null,
  'update_my_profile(p_name, p_phone)'

union all
select
  '7. Material entry is admin-only',
  (select prosrc like '%require_admin%' from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'consume_raw_materials'),
  'consume_raw_materials() calls app.require_admin()'

union all
select
  '8. Exactly two shifts are in use',
  (select count(*) = 2 from public.shifts
   where active and lower(btrim(name)) in ('morning', 'night'))
  and not exists (
    select 1 from public.shifts
    where active and lower(btrim(name)) not in ('morning', 'night')),
  (select string_agg(name || ' ' || start_time || '-' || end_time, ', ' order by name)
   from public.shifts where active)

union all
select
  '9. The shift rules are enforced by triggers',
  (select count(*) >= 2 from pg_trigger
   where tgname in ('shifts_guard', 'production_entries_shift_guard')
     and not tgisinternal),
  'shifts_guard + entry shift guards'

union all
select
  '10. History is intact — no entry lost its shift',
  not exists (
    select 1 from public.production_entries e
    left join public.shifts s on s.id = e.shift_id
    where s.id is null),
  (select count(*)::text || ' production entries still resolve their shift'
   from public.production_entries)

union all
select
  '11. Ledgers reconcile, per packaging',
  not exists (select 1 from public.v_stock_reconciliation where not ok),
  (select count(*)::text || ' balances checked' from public.v_stock_reconciliation)

union all
select
  '12. Anything needing attention',
  true,
  coalesce((
    select string_agg(title || ': ' || message, ' | ')
    from public.notifications
    where title = 'Shift assignments need attention'
  ), 'nothing — no assignment lost its shift')

order by 1;
