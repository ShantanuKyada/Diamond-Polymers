-- =============================================================================
-- 0019_verify.sql — run AFTER applying 0019_simple_payroll.sql
--
-- Every row must say ok = true. Nothing here writes anything.
-- =============================================================================

select
  '01. The proration and overtime columns are gone' as check,
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'payslips'
      and column_name in ('basic_amount', 'gross_amount', 'overtime_amount',
                          'additions_amount', 'payable_days', 'present_days',
                          'absent_days', 'calendar_days', 'overtime_hours',
                          'overtime_rate_per_hour')) as ok,
  coalesce((select string_agg(column_name, ', ')
            from information_schema.columns
            where table_schema = 'public' and table_name = 'payslips'
              and column_name in ('basic_amount', 'gross_amount',
                                  'overtime_amount', 'additions_amount',
                                  'payable_days', 'present_days', 'absent_days',
                                  'calendar_days', 'overtime_hours',
                                  'overtime_rate_per_hour')),
           'none left') as detail

union all
select
  '02. A payslip is four figures',
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'payslips'
     and column_name in ('monthly_salary', 'deductions_amount',
                         'advance_recovered', 'net_payable')) = 4,
  'monthly_salary, deductions_amount, advance_recovered, net_payable'

union all
select
  '03. The arithmetic is enforced',
  exists (select 1 from pg_constraint
          where conname = 'payslip_net_ck'
            and conrelid = 'public.payslips'::regclass),
  'payslip_net_ck: net = salary - deductions - advance'

union all
select
  '04. A salary is a number, not a rate card',
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'salary_structures'
                and column_name in ('overtime_rate_per_hour',
                                    'standard_hours_per_day')),
  'salary_structures carries monthly_salary and its dates'

union all
select
  '05. The settings that drove proration are gone',
  not exists (select 1 from public.app_settings
              where key in ('payroll_fixed_days', 'payroll_overtime_multiplier',
                            'payroll_proration_basis',
                            'payroll_unmarked_day_policy')),
  coalesce((select string_agg(key, ', ') from public.app_settings
            where key in ('payroll_fixed_days', 'payroll_overtime_multiplier',
                          'payroll_proration_basis',
                          'payroll_unmarked_day_policy')),
           'none left')

union all
select
  '06. Advance recovery is still switched on',
  exists (select 1 from public.app_settings
          where key = 'payroll_recover_advances' and value = 'true'),
  coalesce((select 'payroll_recover_advances = ' || value
            from public.app_settings where key = 'payroll_recover_advances'),
           'MISSING')

union all
select
  '07. An adjustment can only subtract',
  exists (select 1 from pg_constraint
          where conname = 'staff_adjustment_type_ck'
            and conrelid = 'public.staff_adjustments'::regclass
            and pg_get_constraintdef(oid) ilike '%DEDUCTION%'
            and pg_get_constraintdef(oid) not ilike '%BONUS%'),
  coalesce((select pg_get_constraintdef(oid) from pg_constraint
            where conname = 'staff_adjustment_type_ck'
              and conrelid = 'public.staff_adjustments'::regclass), 'MISSING')

union all
select
  '08. set_salary_structure has one signature',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_salary_structure') = 1,
  -- Two would make an overload PostgREST cannot choose between, and every call
  -- from the app would fail with PGRST203.
  (select coalesce(string_agg(array_to_string(p.proargnames, ', '), ' | '),
                   'MISSING')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_salary_structure')

union all
select
  '09. remove_staff_adjustment exists',
  to_regprocedure('public.remove_staff_adjustment(uuid)') is not null,
  'the undo a mistyped deduction never had'

union all
select
  '10. The read models are rebuilt',
  (select count(*) from pg_views
   where schemaname = 'public'
     and viewname in ('v_payslips', 'v_payroll_summary', 'v_staff_pay',
                      'v_staff_deductions')) = 4,
  coalesce((select string_agg(viewname, ', ' order by viewname) from pg_views
            where schemaname = 'public'
              and viewname in ('v_payslips', 'v_payroll_summary',
                               'v_staff_pay', 'v_staff_deductions')), 'none')

union all
select
  '11. Every payroll view still runs as the caller',
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and c.relname in ('v_payslips', 'v_payroll_summary', 'v_staff_pay',
                        'v_staff_deductions')
      and coalesce(array_to_string(c.reloptions, ','), '')
          not like '%security_invoker=on%'),
  -- Without security_invoker a view runs as its owner and hands every worker
  -- the entire payroll.
  'security_invoker = on'

union all
select
  '12. Attendance is untouched',
  to_regclass('public.attendance_days') is not null
    and to_regprocedure('public.set_attendance(uuid, date, public.attendance_status, timestamptz, timestamptz, numeric, uuid, text)') is not null,
  coalesce((select count(*)::text || ' attendance day(s) still on file'
            from public.attendance_days), '0')

union all
select
  '13. Nothing was paid that does not add up',
  not exists (select 1 from public.payslips
              where net_payable <> monthly_salary - deductions_amount
                                   - advance_recovered),
  coalesce((select count(*)::text || ' payslip(s) on file'
            from public.payslips), '0')

union all
select
  '14. Every advance balance is explained by its ledger',
  not exists (
    select 1 from public.staff_advance_balance b
    left join public.advance_transactions t on t.profile_id = b.profile_id
    group by b.profile_id, b.outstanding
    having b.outstanding <> coalesce(sum(t.amount), 0)),
  'balance caches agree with the ledger'

order by 1;
