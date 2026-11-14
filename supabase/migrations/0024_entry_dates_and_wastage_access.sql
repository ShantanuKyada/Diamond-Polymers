-- =============================================================================
-- 0024_entry_dates_and_wastage_access.sql — two holes found in the audit
--
--   A44. consume_reusable_wastage() was the one stock-moving write any signed-in
--        person could call. Every other one is admin-only or goes through
--        app.assert_can_record(). Now it is admin-only too.
--
--   A45. An entry's date was limited by the date picker and by nothing else.
--        The rule now lives in the database, where it applies to every path.
--
-- Both are enforcement, not behaviour: nothing that was allowed through the app
-- stops being allowed. Safe to re-run. Requires 0001–0023.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A45. How far back an entry may be dated
--
-- The production form has always offered the last 30 days and no future, which
-- is the right rule and was in the wrong place: the UI. "Do not rely only on
-- hiding the button" is the standard the rest of this schema is held to, and a
-- date that moves stock is exactly the kind of field that deserves it.
--
-- A setting rather than a constant, because a factory that closes its books
-- monthly wants a different window from one that does not — and because the
-- Configuration screen is where that decision belongs.
-- -----------------------------------------------------------------------------

insert into public.app_settings (key, value, description)
values (
  'entry_backdating_days',
  '30',
  'How many days back an entry may be dated. 0 means today only. '
  'Future dates are never allowed.'
)
on conflict (key) do nothing;

create or replace function app.assert_entry_date(
  p_date  date,
  p_field text default 'entry_date'
)
returns date
language plpgsql
stable
set search_path = public, pg_temp
as $fn$
declare
  v_days  integer := greatest(
    coalesce(nullif(app.setting('entry_backdating_days', '30'), '')::integer, 30),
    0);
  -- The factory's today, not the server's. Reports bucket by the factory
  -- timezone, so the window an entry is measured against has to use the same
  -- clock or the two disagree for five and a half hours every night.
  v_today date := (now() at time zone
                   app.setting('factory_timezone', 'Asia/Kolkata'))::date;
begin
  if p_date is null then
    return v_today;
  end if;

  if p_date > v_today then
    raise exception using
      errcode = 'DP005',
      message = 'An entry cannot be dated in the future.',
      detail  = json_build_object('field', p_field,
                                  'date', p_date,
                                  'today', v_today)::text;
  end if;

  if p_date < v_today - v_days then
    raise exception using
      errcode = 'DP005',
      message = format('An entry cannot be dated more than %s days back. '
                       'Change "How many days back an entry may be dated" '
                       'in Settings if the factory needs longer.', v_days),
      detail  = json_build_object('field', p_field,
                                  'date', p_date,
                                  'earliest', v_today - v_days)::text;
  end if;

  return p_date;
end;
$fn$;

comment on function app.assert_entry_date(date, text) is
  'A45: refuses a future date, or one older than entry_backdating_days.';

-- Triggers rather than edits to five RPC bodies.
--
-- The RPCs are the only write path today — these tables have no INSERT policy —
-- but a rule about what a row may contain belongs on the table, where a
-- migration that adds a sixth write path inherits it instead of forgetting it.
-- Only INSERT: history is not re-judged by a window that moved under it.

create or replace function app.check_entry_date()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fn$
begin
  if tg_argv[0] = 'dispatch_date' then
    perform app.assert_entry_date(new.dispatch_date, 'dispatch_date');
  else
    perform app.assert_entry_date(new.entry_date, 'entry_date');
  end if;
  return new;
end;
$fn$;

do $mig$
declare
  r record;
begin
  for r in
    select * from (values
      ('production_entries', 'entry_date'),
      ('mixture_entries',    'entry_date'),
      ('wastage_entries',    'entry_date'),
      ('shred_entries',      'entry_date'),
      ('dispatches',         'dispatch_date')
    ) as t(tbl, col)
  loop
    execute format(
      'drop trigger if exists %I on public.%I', r.tbl || '_entry_date_ck', r.tbl);
    execute format(
      'create trigger %I before insert on public.%I '
      'for each row execute function app.check_entry_date(%L)',
      r.tbl || '_entry_date_ck', r.tbl, r.col);
  end loop;
end
$mig$;

-- -----------------------------------------------------------------------------
-- A44. Consuming recycled stock is an administrator's act
--
-- It moves a factory-wide balance that belongs to nobody's machine, so there is
-- no "their own" for app.assert_can_record() to check — which is why it had no
-- guard at all rather than the wrong one. Admin-only is the answer the rest of
-- the stock maintenance functions already use.
--
-- The body below is unchanged except for that first line.
-- -----------------------------------------------------------------------------

create or replace function public.consume_reusable_wastage(
  p_raw_material_id uuid,
  p_quantity        numeric,
  p_client_ref      uuid,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller uuid := app.require_admin();   -- A44: was app.require_profile()
  v_mode   text := app.setting('reusable_wastage_mode', 'SEPARATE');
  v_txn    uuid;
  v_left   numeric(14, 3);
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Quantity must be greater than zero.',
      detail  = '{"field":"quantity"}';
  end if;

  if v_mode <> 'SEPARATE' then
    -- A9: the substitution ratio is a business rule the factory has not
    -- defined. Failing loudly beats inventing arithmetic that corrupts stock.
    raise exception using
      errcode = 'DP007',
      message = 'Reusable-wastage substitution is not configured yet.',
      detail  = json_build_object('mode', v_mode)::text;
  end if;

  if exists (select 1 from public.reusable_wastage_transactions
             where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_reusable_movement(
    p_raw_material_id, 'CONSUMED', -p_quantity, v_caller,
    p_client_ref, 'manual', p_remarks
  );

  select quantity into v_left
  from public.reusable_wastage_stock
  where raw_material_id = p_raw_material_id;

  return jsonb_build_object('transaction_id', v_txn,
                            'duplicate', false,
                            'remaining', v_left);
end;
$fn$;

grant execute on function public.consume_reusable_wastage(uuid, numeric, uuid, text)
  to authenticated;
grant execute on function app.assert_entry_date(date, text) to authenticated;
