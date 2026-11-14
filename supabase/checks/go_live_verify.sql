-- =============================================================================
-- go_live_verify.sql — run AFTER scripts/go_live_clear_demo_data.sql
--
-- Rows 01 to 08 must all say ok = true. Row 09 is information: it lists any
-- Supabase login left behind with no employee record, which you can remove
-- under Authentication → Users. Nothing here writes anything.
-- =============================================================================

select
  '01. Factory Admin still signs in' as check,
  exists (select 1 from public.profiles
          where employee_code = 'EMP-001' and auth_user_id is not null
            and active) as ok,
  coalesce((select p.name || '  ·  ' || p.role || '  ·  ' ||
                   coalesce(u.email, 'NO LOGIN LINKED')
            from public.profiles p
            left join auth.users u on u.id = p.auth_user_id
            where p.employee_code = 'EMP-001'),
           'EMP-001 is gone') as detail

union all
select
  '02. Shantanu still signs in',
  exists (select 1 from public.profiles
          where employee_code = 'EMP-101' and auth_user_id is not null
            and active),
  coalesce((select p.name || '  ·  ' || p.role || '  ·  ' ||
                   coalesce(u.email, 'NO LOGIN LINKED')
            from public.profiles p
            left join auth.users u on u.id = p.auth_user_id
            where p.employee_code = 'EMP-101'),
           'EMP-101 is gone')

union all
select
  '03. Those two are the only employees',
  (select count(*) from public.profiles) = 2,
  coalesce((select string_agg(employee_code || ' ' || name, ', '
                              order by employee_code)
            from public.profiles), 'none')

union all
select
  '04. Every day-to-day table is empty',
  (select count(*) from public.production_entries) = 0
  and (select count(*) from public.mixture_entries) = 0
  and (select count(*) from public.mixture_entry_lines) = 0
  and (select count(*) from public.shred_entries) = 0
  and (select count(*) from public.wastage_entries) = 0
  and (select count(*) from public.dispatches) = 0
  and (select count(*) from public.dispatch_lines) = 0
  and (select count(*) from public.raw_material_transactions) = 0
  and (select count(*) from public.raw_material_stock) = 0
  and (select count(*) from public.finished_goods_transactions) = 0
  and (select count(*) from public.finished_goods_stock) = 0
  and (select count(*) from public.reusable_wastage_transactions) = 0
  and (select count(*) from public.reusable_wastage_stock) = 0
  and (select count(*) from public.machine_assignments) = 0
  and (select count(*) from public.notifications) = 0
  and (select count(*) from public.notification_reads) = 0,
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
           'all empty')

union all
select
  '05. Every payroll table is empty',
  (select count(*) from public.attendance_days) = 0
  and (select count(*) from public.payroll_periods) = 0
  and (select count(*) from public.payslips) = 0
  and (select count(*) from public.payslip_components) = 0
  and (select count(*) from public.salary_payments) = 0
  and (select count(*) from public.salary_structures) = 0
  and (select count(*) from public.staff_adjustments) = 0
  and (select count(*) from public.advance_transactions) = 0
  and (select count(*) from public.staff_advance_balance) = 0,
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
           'all empty')

union all
select
  '06. The demonstration catalogue is gone',
  (select count(*) from public.machines) = 0
  and (select count(*) from public.machine_products) = 0
  and (select count(*) from public.pipe_types) = 0
  and (select count(*) from public.pipe_sizes) = 0
  and (select count(*) from public.pipe_products) = 0
  and (select count(*) from public.pipe_product_weight_history) = 0
  and (select count(*) from public.raw_materials) = 0,
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
           'all empty')

union all
select
  '07. Your configuration survived',
  (select count(*) from public.app_settings) > 0,
  (select count(*)::text from public.app_settings) || ' setting(s), including '
  || coalesce((select value from public.app_settings where key = 'factory_name'),
              'no factory name set')

union all
select
  '08. Roles, shifts and material categories survived',
  (select count(*) from public.employee_types) > 0
  and (select count(*) from public.shifts) > 0
  and exists (select 1 from public.raw_material_categories
              where code = 'RECYCLED'),
  coalesce((select string_agg(code, ', ' order by sort_order)
            from public.employee_types), 'no roles') || '  ·  '
  || coalesce((select string_agg(name, ', ' order by name)
               from public.shifts), 'no shifts') || '  ·  '
  || coalesce((select string_agg(code, ', ' order by code)
               from public.raw_material_categories), 'no categories')

union all
-- ---------------------------------------------------------------------------
-- Information, not a pass or a fail
-- ---------------------------------------------------------------------------
-- A Supabase login outlives the employee record it was attached to. One left
-- over can still authenticate and then find no profile, which gets it nowhere
-- — every policy in this database reads through profiles — but it is untidy.
-- Remove any listed here under Authentication → Users.
select
  '09. Logins with no employee record',
  true,
  coalesce((select string_agg(u.email, ', ' order by u.email)
            from auth.users u
            where not exists (select 1 from public.profiles p
                              where p.auth_user_id = u.id)),
           'none — every login has an employee');
