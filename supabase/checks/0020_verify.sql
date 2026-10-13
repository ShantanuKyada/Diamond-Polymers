-- =============================================================================
-- 0020_verify.sql — run AFTER applying 0020_worker_profiles_and_salary_payments.sql
--
-- Every row must say ok = true. Nothing here writes anything.
-- =============================================================================

select
  '01. A profile records when somebody joined and when they are paid' as check,
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name in ('joined_on', 'salary_day')) = 2 as ok,
  'profiles.joined_on, profiles.salary_day' as detail

union all
select
  '02. A salary day has to be a day of a month',
  exists (select 1 from pg_constraint
          where conname = 'profiles_salary_day_ck'
            and conrelid = 'public.profiles'::regclass),
  coalesce((select pg_get_constraintdef(oid) from pg_constraint
            where conname = 'profiles_salary_day_ck'
              and conrelid = 'public.profiles'::regclass), 'MISSING')

union all
select
  '03. The payments ledger exists',
  to_regclass('public.salary_payments') is not null,
  'salary_payments'

union all
select
  '04. A draft rebuild cannot delete payment history',
  -- ON DELETE RESTRICT. run_payroll() deletes a draft's payslips, and paying
  -- needs a finalised month, so this never fires in normal use — it is here so
  -- that a later change breaking that rule fails loudly instead of quietly
  -- destroying what was paid.
  exists (select 1 from pg_constraint
          where conrelid = 'public.salary_payments'::regclass
            and contype = 'f' and confdeltype = 'r'
            and confrelid = 'public.payslips'::regclass),
  'salary_payments.payslip_id is ON DELETE RESTRICT'

union all
select
  '05. A payment cannot be zero',
  exists (select 1 from pg_constraint
          where conrelid = 'public.salary_payments'::regclass
            and contype = 'c'
            and pg_get_constraintdef(oid) like '%<> (0)%'),
  'amount <> 0, so a reversal can be negative but nothing can be nothing'

union all
select
  '06. A payment can be reversed once and only once',
  exists (select 1 from pg_indexes
          where schemaname = 'public'
            and indexname = 'salary_payments_one_reversal'),
  'unique index on reverses'

union all
select
  '07. Nobody can write a payment by hand',
  -- Append-only through the RPC: a SELECT policy and nothing else, so not even
  -- an administrator can edit or delete what was paid.
  (select count(*) from pg_policies
   where schemaname = 'public' and tablename = 'salary_payments') = 1
  and exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'salary_payments'
                and cmd = 'SELECT'),
  coalesce((select string_agg(policyname || ' (' || cmd || ')', ', ')
            from pg_policies
            where schemaname = 'public' and tablename = 'salary_payments'),
           'NONE')

union all
select
  '08. Row level security is on',
  (select relrowsecurity from pg_class
   where oid = 'public.salary_payments'::regclass),
  'salary_payments'

union all
select
  '09. The three new functions exist, one signature each',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('record_salary_payment', 'reverse_salary_payment',
                       'save_worker_profile')) = 3,
  -- More than one of any name would be an overload PostgREST cannot choose
  -- between, and every call from the app would fail with PGRST203.
  coalesce((select string_agg(p.proname, ', ' order by p.proname)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('record_salary_payment',
                                'reverse_salary_payment',
                                'save_worker_profile')), 'NONE')

union all
select
  '10. A signed-in administrator can call them',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'execute'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('record_salary_payment', 'reverse_salary_payment',
                       'save_worker_profile')),
  'granted to authenticated; each one calls app.require_admin() at runtime'

union all
select
  '11. A payslip now reports where it stands',
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'v_payslips'
     and column_name in ('paid_amount', 'outstanding', 'payment_status',
                         'salary_due_on', 'joined_on', 'salary_day')) = 6,
  'v_payslips: paid_amount, outstanding, payment_status, salary_due_on'

union all
select
  '12. The read models are all present',
  (select count(*) from pg_views
   where schemaname = 'public'
     and viewname in ('v_payslips', 'v_payroll_summary', 'v_staff_pay',
                      'v_staff_deductions', 'v_salary_payments',
                      'v_salary_advances')) = 6,
  coalesce((select string_agg(viewname, ', ' order by viewname) from pg_views
            where schemaname = 'public'
              and viewname in ('v_payslips', 'v_payroll_summary',
                               'v_staff_pay', 'v_staff_deductions',
                               'v_salary_payments', 'v_salary_advances')),
           'none')

union all
select
  '13. Every payroll view still runs as the caller',
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and c.relname in ('v_payslips', 'v_payroll_summary', 'v_staff_pay',
                        'v_staff_deductions', 'v_salary_payments',
                        'v_salary_advances')
      and coalesce(array_to_string(c.reloptions, ','), '')
          not like '%security_invoker=on%'),
  -- Without security_invoker a view runs as its owner and hands every worker
  -- the entire payroll.
  'security_invoker = on'

union all
select
  '14. A salary day past the end of a short month lands on its last day',
  app.salary_due_on(date '2027-02-01', 31::smallint) = date '2027-02-28'
    and app.salary_due_on(date '2027-02-01', 7::smallint) = date '2027-02-07'
    and app.salary_due_on(date '2027-02-01', null) is null,
  'app.salary_due_on clamps rather than inventing a date'

union all
select
  '15. Nothing on file has been paid more than it is owed',
  not exists (select 1 from public.v_payslips where outstanding < 0),
  coalesce((select count(*)::text || ' payslip(s) on file'
            from public.payslips), '0')

union all
select
  '16. What is paid plus what is left is what is owed',
  not exists (select 1 from public.v_payroll_summary
              where paid_total + outstanding_total <> net_total),
  'every month reconciles'

union all
select
  '17. The salary slip footer is configurable',
  exists (select 1 from public.app_settings where key = 'salary_slip_footer'),
  'More -> Configuration -> salary_slip_footer'

order by 1;
