-- =============================================================================
-- go_live_preflight.sql — run BEFORE scripts/go_live_clear_demo_data.sql
--
-- The database still holds the demonstration factory it was seeded with: four
-- machines, two pipe types, eight products, five raw materials and three days
-- of invented production. None of that is real, and none of it should be the
-- first thing the floor sees.
--
-- The clearing script empties every operational table and the demonstration
-- catalogue, and keeps exactly two people: EMP-001 (Factory Admin) and EMP-101
-- (Shantanu Kyada). Settings, employee roles, shifts and the raw-material
-- categories stay, because those are decisions the factory has already made.
--
-- This script writes nothing. Read every row before running the clearing
-- script — rows 1, 2 and 3 are the ones that can stop you.
-- =============================================================================

select
  '01. Factory Admin is here and can sign in' as check,
  exists (select 1 from public.profiles
          where employee_code = 'EMP-001' and auth_user_id is not null) as ok,
  coalesce((select p.name || '  ·  ' || p.role || '  ·  ' ||
                   coalesce(u.email, 'NO LOGIN LINKED')
            from public.profiles p
            left join auth.users u on u.id = p.auth_user_id
            where p.employee_code = 'EMP-001'),
           'EMP-001 not found — stop, the clearing script would delete nobody '
           'useful and leave you locked out') as detail

union all
select
  '02. Shantanu is here and can sign in',
  exists (select 1 from public.profiles
          where employee_code = 'EMP-101' and auth_user_id is not null),
  coalesce((select p.name || '  ·  ' || p.role || '  ·  ' ||
                   coalesce(u.email, 'NO LOGIN LINKED')
            from public.profiles p
            left join auth.users u on u.id = p.auth_user_id
            where p.employee_code = 'EMP-101'),
           'EMP-101 not found')

union all
-- ---------------------------------------------------------------------------
-- The one row that can quietly cost somebody their access
-- ---------------------------------------------------------------------------
-- The clearing script keeps two employee codes and removes the rest. If
-- somebody real has been added since the demonstration data went in, and they
-- have a login, this row says so and you should add their code to the keep
-- list at the top of the clearing script before running it.
select
  '03. Nobody else has a login to lose',
  not exists (select 1 from public.profiles
              where employee_code not in ('EMP-001', 'EMP-101')
                and auth_user_id is not null),
  coalesce((select string_agg(p.employee_code || ' (' || p.name || ', ' ||
                              coalesce(u.email, 'no email') || ')',
                              ', ' order by p.employee_code)
            from public.profiles p
            left join auth.users u on u.id = p.auth_user_id
            where p.employee_code not in ('EMP-001', 'EMP-101')
              and p.auth_user_id is not null),
           'nobody — only the two keepers have logins')

union all
select
  '04. People who will be removed',
  true,
  coalesce((select string_agg(employee_code || ' ' || name, ', '
                              order by employee_code)
            from public.profiles
            where employee_code not in ('EMP-001', 'EMP-101')),
           'nobody — already cleared')

union all
-- ---------------------------------------------------------------------------
-- What the clearing script empties
-- ---------------------------------------------------------------------------
-- Each table is named rather than discovered, so what you read here is exactly
-- what the clearing script touches. Tables already empty are left out.
select
  '05. Day-to-day records that will be cleared',
  true,
  coalesce((select string_agg(t || ': ' || n, ', ' order by t)
            from (
              select 'production_entries' as t, count(*)::text as n from public.production_entries
              union all select 'mixture_entries',        count(*)::text from public.mixture_entries
              union all select 'mixture_entry_lines',    count(*)::text from public.mixture_entry_lines
              union all select 'shred_entries',          count(*)::text from public.shred_entries
              union all select 'wastage_entries',        count(*)::text from public.wastage_entries
              union all select 'dispatches',             count(*)::text from public.dispatches
              union all select 'dispatch_lines',         count(*)::text from public.dispatch_lines
              union all select 'raw_material_transactions', count(*)::text from public.raw_material_transactions
              union all select 'raw_material_stock',     count(*)::text from public.raw_material_stock
              union all select 'finished_goods_transactions', count(*)::text from public.finished_goods_transactions
              union all select 'finished_goods_stock',   count(*)::text from public.finished_goods_stock
              union all select 'reusable_wastage_transactions', count(*)::text from public.reusable_wastage_transactions
              union all select 'reusable_wastage_stock', count(*)::text from public.reusable_wastage_stock
              union all select 'machine_assignments',    count(*)::text from public.machine_assignments
              union all select 'notifications',          count(*)::text from public.notifications
              union all select 'notification_reads',     count(*)::text from public.notification_reads
            ) c
            where n <> '0'),
           'already empty')

union all
select
  '06. Payroll records that will be cleared',
  true,
  coalesce((select string_agg(t || ': ' || n, ', ' order by t)
            from (
              select 'attendance_days' as t, count(*)::text as n from public.attendance_days
              union all select 'payroll_periods',      count(*)::text from public.payroll_periods
              union all select 'payslips',             count(*)::text from public.payslips
              union all select 'payslip_components',   count(*)::text from public.payslip_components
              union all select 'salary_payments',      count(*)::text from public.salary_payments
              union all select 'salary_structures',    count(*)::text from public.salary_structures
              union all select 'staff_adjustments',    count(*)::text from public.staff_adjustments
              union all select 'advance_transactions', count(*)::text from public.advance_transactions
              union all select 'staff_advance_balance', count(*)::text from public.staff_advance_balance
            ) c
            where n <> '0'),
           'already empty')

union all
select
  '07. Demonstration catalogue that will be cleared',
  true,
  coalesce((select string_agg(t || ': ' || n, ', ' order by t)
            from (
              select 'machines' as t, count(*)::text as n from public.machines
              union all select 'machine_products',   count(*)::text from public.machine_products
              union all select 'pipe_types',         count(*)::text from public.pipe_types
              union all select 'pipe_sizes',         count(*)::text from public.pipe_sizes
              union all select 'pipe_products',      count(*)::text from public.pipe_products
              union all select 'pipe_product_weight_history', count(*)::text from public.pipe_product_weight_history
              union all select 'raw_materials',      count(*)::text from public.raw_materials
            ) c
            where n <> '0'),
           'already empty')

union all
-- ---------------------------------------------------------------------------
-- What survives
-- ---------------------------------------------------------------------------
select
  '08. Kept: your configuration',
  (select count(*) from public.app_settings) > 0,
  (select count(*)::text from public.app_settings) || ' setting(s), including '
  || coalesce((select value from public.app_settings where key = 'factory_name'),
              'no factory name set')

union all
select
  '09. Kept: employee roles and shifts',
  (select count(*) from public.employee_types) > 0
  and (select count(*) from public.shifts) > 0,
  coalesce((select string_agg(code, ', ' order by sort_order)
            from public.employee_types), 'no roles') || '  ·  '
  || coalesce((select string_agg(name, ', ' order by name)
               from public.shifts), 'no shifts')

union all
-- The four categories are the factory's own taxonomy, not demonstration data,
-- and RECYCLED is load-bearing: shred_pipe() stocks shredded pipe against it.
-- Deleting them would break shredding on day one, so they stay even though the
-- materials filed under them go.
select
  '10. Kept: raw-material categories',
  (select count(*) from public.raw_material_categories) > 0,
  coalesce((select string_agg(code, ', ' order by code)
            from public.raw_material_categories), 'none');
