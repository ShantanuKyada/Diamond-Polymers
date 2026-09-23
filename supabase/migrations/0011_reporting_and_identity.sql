-- =============================================================================
-- 0011_reporting_and_identity.sql — closes two gaps found auditing the phases
--                                   in the app against the database
--
-- 1. PHASE 2 (Operators). docs/01 A3 states that "the link_profile_to_auth_user()
--    seam is already in the schema". It is not — the function was never written.
--    Admin "Add operator" therefore has no way to attach a login to a profile,
--    and the documented workaround is two hand-written UPDATE statements in the
--    SQL editor. The function is written here, so the claim becomes true.
--
-- 2. PHASE 7 (Reports). The screen promises "Opening, movement and closing
--    quantities" over a date range. Nothing in the database could produce them:
--    the summary views aggregate movements but no view or function gives a
--    balance as at a date. Without this every client would have to walk the
--    ledger itself and they would each get it subtly wrong.
--
-- TIME ZONES. Ledger rows are stamped `created_at timestamptz`, and Supabase
-- runs in UTC. A factory day is not a UTC day, so a report asked for "5 Sept"
-- would otherwise take movements from 05:30 that morning to 05:30 the next —
-- silently misattributing the night shift. Every boundary below is resolved
-- through `factory_timezone`.
-- =============================================================================

insert into public.app_settings (key, value, description) values
  ('factory_timezone', 'Asia/Kolkata',
   'Time zone the factory day is measured in. Report date boundaries are '
   'resolved through it, so a day means a day on the floor rather than a day '
   'in UTC.')
on conflict (key) do update set description = excluded.description;

-- -----------------------------------------------------------------------------
-- Phase 2: attach a login to a profile
--
-- A profile and a login are deliberately separate (A3): an operator can exist as
-- a factory record without ever signing in. Creating the auth user still needs
-- the admin API and a service-role key, which must never ship inside the app, so
-- an administrator creates the user in the Supabase dashboard and then calls
-- this to join the two.
-- -----------------------------------------------------------------------------

create or replace function public.link_profile_to_auth_user(
  p_employee_code text,
  p_email         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin   uuid := app.require_admin();
  v_profile public.profiles;
  v_user_id uuid;
  v_taken   text;
begin
  select * into v_profile
  from public.profiles
  where employee_code = btrim(p_employee_code);

  if v_profile.id is null then
    raise exception using
      errcode = 'DP005',
      message = format('No staff member has the code %s.', p_employee_code),
      detail  = '{"field":"employee_code"}';
  end if;

  select id into v_user_id
  from auth.users
  where lower(email) = lower(btrim(p_email));

  if v_user_id is null then
    raise exception using
      errcode = 'DP005',
      message = format('No login exists for %s. Create the user under '
                       'Authentication first, then link it.', p_email),
      detail  = '{"field":"email"}';
  end if;

  -- One login belongs to one person. Silently moving it would leave the
  -- previous holder unable to sign in, with nothing recorded about why.
  select employee_code into v_taken
  from public.profiles
  where auth_user_id = v_user_id
    and id <> v_profile.id;

  if v_taken is not null then
    raise exception using
      errcode = 'DP005',
      message = format('That login is already linked to %s.', v_taken),
      detail  = json_build_object('employee_code', v_taken)::text;
  end if;

  update public.profiles
  set auth_user_id = v_user_id
  where id = v_profile.id;

  return jsonb_build_object(
    'profile_id',    v_profile.id,
    'employee_code', v_profile.employee_code,
    'name',          v_profile.name,
    'role',          v_profile.role,
    'auth_user_id',  v_user_id,
    'email',         lower(btrim(p_email))
  );
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Report window helper
--
-- Turns a pair of dates into the half-open timestamptz range that actually
-- bounds those days on the factory floor.
-- -----------------------------------------------------------------------------

create or replace function app.report_window(p_from date, p_to date)
returns tstzrange
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_tz text := coalesce(app.setting('factory_timezone', 'Asia/Kolkata'), 'Asia/Kolkata');
begin
  if p_from is null or p_to is null then
    raise exception using
      errcode = 'DP005',
      message = 'A report needs a start and an end date.',
      detail  = '{"field":"date_range"}';
  end if;

  if p_to < p_from then
    raise exception using
      errcode = 'DP005',
      message = 'The end date is before the start date.',
      detail  = '{"field":"date_range"}';
  end if;

  return tstzrange(
    (p_from::timestamp) at time zone v_tz,
    ((p_to + 1)::timestamp) at time zone v_tz,
    '[)'
  );
end;
$fn$;

-- =============================================================================
-- raw_material_report — opening, movement and closing, in kilograms
--
-- Opening is the sum of every movement before the window, which is the only
-- honest definition: the balance table holds today's figure and cannot be
-- rewound. The ledger can, because each row is a signed delta and the CHECK in
-- 0001 guarantees the deltas and the running totals agree.
--
-- Admin-only: an operator's RLS view of the ledger is limited to their own
-- movements, so a report run as an operator would return confident, wrong
-- totals. Better to refuse than to mislead.
-- =============================================================================

create or replace function public.raw_material_report(
  p_from date,
  p_to   date
)
returns table (
  raw_material_id   uuid,
  material_code     text,
  material_name     text,
  category          text,
  unit              text,
  is_recycled       boolean,
  opening_qty       numeric,
  stock_in_qty      numeric,
  consumed_qty      numeric,
  wastage_qty       numeric,
  recovered_qty     numeric,
  shred_return_qty  numeric,
  adjustment_qty    numeric,
  closing_qty       numeric,
  minimum_stock     numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin  uuid := app.require_admin();
  v_window tstzrange := app.report_window(p_from, p_to);
begin
  return query
  select
    m.id,
    m.code,
    m.name,
    m.category,
    m.unit,
    m.is_recycled,
    coalesce(o.opening, 0),
    coalesce(w.stock_in, 0),
    coalesce(w.consumed, 0),
    coalesce(w.wastage, 0),
    coalesce(w.recovered, 0),
    coalesce(w.shred_return, 0),
    coalesce(w.adjustment, 0),
    coalesce(o.opening, 0) + coalesce(w.net, 0),
    m.minimum_stock
  from public.raw_materials m
  left join (
    select t.raw_material_id, sum(t.quantity) as opening
    from public.raw_material_transactions t
    where t.created_at < lower(v_window)
    group by t.raw_material_id
  ) o on o.raw_material_id = m.id
  left join (
    select
      t.raw_material_id,
      sum(t.quantity)                                                        as net,
      coalesce(sum(t.quantity) filter (
        where t.transaction_type in ('OPENING_STOCK', 'STOCK_IN')), 0)       as stock_in,
      -- Consumption, wastage and recovery are reported as positive magnitudes;
      -- the ledger stores them signed.
      coalesce(-sum(t.quantity) filter (
        where t.transaction_type = 'PRODUCTION_CONSUMPTION'), 0)             as consumed,
      coalesce(-sum(t.quantity) filter (
        where t.transaction_type = 'WASTAGE'), 0)                            as wastage,
      coalesce(sum(t.quantity) filter (
        where t.transaction_type = 'RECOVERED_WASTAGE'), 0)                  as recovered,
      coalesce(sum(t.quantity) filter (
        where t.transaction_type = 'SHRED_RETURN'), 0)                       as shred_return,
      coalesce(sum(t.quantity) filter (
        where t.transaction_type in ('MANUAL_ADJUSTMENT', 'CORRECTION')), 0) as adjustment
    from public.raw_material_transactions t
    where t.created_at <@ v_window
    group by t.raw_material_id
  ) w on w.raw_material_id = m.id
  where m.active
  order by m.is_recycled, m.name;
end;
$fn$;

-- =============================================================================
-- finished_goods_report — the same shape, in bundles and kilograms
--
-- Bundles are what the floor counts and kilograms are what the material balance
-- needs, so both are reported. Weight uses the product's current bundle weight,
-- which is a stated approximation: individual entries keep their own snapshot
-- (A21), but a stock balance is an aggregate with no single weight behind it.
-- =============================================================================

create or replace function public.finished_goods_report(
  p_from date,
  p_to   date
)
returns table (
  pipe_type_id      uuid,
  pipe_size_id      uuid,
  sku               text,
  product_label     text,
  diameter_mm       numeric,
  bundle_weight_kg  numeric,
  opening_bundles   integer,
  produced_bundles  integer,
  dispatched_bundles integer,
  shredded_bundles  integer,
  returned_bundles  integer,
  adjustment_bundles integer,
  closing_bundles   integer,
  closing_weight_kg numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin  uuid := app.require_admin();
  v_window tstzrange := app.report_window(p_from, p_to);
begin
  return query
  select
    t.id,
    z.id,
    p.sku,
    t.name || ' — ' || z.name,
    z.diameter_mm,
    p.bundle_weight_kg,
    coalesce(o.opening, 0)::integer,
    coalesce(w.produced, 0)::integer,
    coalesce(w.dispatched, 0)::integer,
    coalesce(w.shredded, 0)::integer,
    coalesce(w.returned, 0)::integer,
    coalesce(w.adjustment, 0)::integer,
    (coalesce(o.opening, 0) + coalesce(w.net, 0))::integer,
    (coalesce(o.opening, 0) + coalesce(w.net, 0)) * coalesce(p.bundle_weight_kg, 0)
  from public.pipe_types t
  cross join public.pipe_sizes z
  left join public.pipe_products p
         on p.pipe_type_id = t.id and p.pipe_size_id = z.id
  left join (
    select f.pipe_type_id, f.pipe_size_id, sum(f.bundle_quantity) as opening
    from public.finished_goods_transactions f
    where f.created_at < lower(v_window)
    group by f.pipe_type_id, f.pipe_size_id
  ) o on o.pipe_type_id = t.id and o.pipe_size_id = z.id
  left join (
    select
      f.pipe_type_id,
      f.pipe_size_id,
      sum(f.bundle_quantity)                                                as net,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type in ('OPENING_STOCK', 'PRODUCTION')), 0)    as produced,
      coalesce(-sum(f.bundle_quantity) filter (
        where f.transaction_type = 'DISPATCH'), 0)                          as dispatched,
      coalesce(-sum(f.bundle_quantity) filter (
        where f.transaction_type = 'SHRED'), 0)                             as shredded,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type = 'RETURN'), 0)                            as returned,
      coalesce(sum(f.bundle_quantity) filter (
        where f.transaction_type in ('ADJUSTMENT', 'CORRECTION')), 0)       as adjustment
    from public.finished_goods_transactions f
    where f.created_at <@ v_window
    group by f.pipe_type_id, f.pipe_size_id
  ) w on w.pipe_type_id = t.id and w.pipe_size_id = z.id
  where t.active and z.active
  order by t.name, z.sort_order;
end;
$fn$;

-- =============================================================================
-- production_report — output by machine, operator and product over a range
--
-- The existing summary views answer "per day", "per machine" and "per operator"
-- separately and over all time. This answers the question the Reports screen
-- actually asks: what happened between these two dates, filtered.
--
-- Filters are NULL-means-all, so one function serves every combination the
-- screen offers rather than one function per filter.
-- =============================================================================

create or replace function public.production_report(
  p_from        date,
  p_to          date,
  p_machine_id  uuid default null,
  p_operator_id uuid default null,
  p_pipe_type_id uuid default null,
  p_pipe_size_id uuid default null
)
returns table (
  entry_date       date,
  machine_id       uuid,
  machine_name     text,
  operator_id      uuid,
  operator_name    text,
  shift_name       text,
  pipe_type_name   text,
  pipe_size_name   text,
  sku              text,
  entries          bigint,
  bundles          bigint,
  output_kg        numeric,
  wastage_kg       numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
begin
  if p_to < p_from then
    raise exception using
      errcode = 'DP005',
      message = 'The end date is before the start date.',
      detail  = '{"field":"date_range"}';
  end if;

  return query
  select
    e.entry_date,
    e.machine_id,
    mc.name,
    e.operator_id,
    o.name,
    sh.name,
    tp.name,
    sz.name,
    pp.sku,
    count(*),
    sum(e.bundle_quantity)::bigint,
    sum(coalesce(e.output_weight_kg, 0)),
    sum(e.wastage_quantity)
  from public.production_entries e
  join public.machines mc on mc.id = e.machine_id
  join public.profiles o on o.id = e.operator_id
  join public.shifts sh on sh.id = e.shift_id
  join public.pipe_types tp on tp.id = e.pipe_type_id
  join public.pipe_sizes sz on sz.id = e.pipe_size_id
  left join public.pipe_products pp on pp.id = e.pipe_product_id
  where e.entry_date between p_from and p_to
    and (p_machine_id   is null or e.machine_id   = p_machine_id)
    and (p_operator_id  is null or e.operator_id  = p_operator_id)
    and (p_pipe_type_id is null or e.pipe_type_id = p_pipe_type_id)
    and (p_pipe_size_id is null or e.pipe_size_id = p_pipe_size_id)
  group by e.entry_date, e.machine_id, mc.name, e.operator_id, o.name,
           sh.name, tp.name, sz.name, pp.sku
  order by e.entry_date desc, mc.name, o.name;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Grants. Each function calls app.require_admin() and refuses anyone else at
-- runtime, so granting EXECUTE to all authenticated users is safe — the check
-- lives in the function, not in who may call it.
-- -----------------------------------------------------------------------------

grant execute on function
  public.link_profile_to_auth_user(text, text),
  public.raw_material_report(date, date),
  public.finished_goods_report(date, date),
  public.production_report(date, date, uuid, uuid, uuid, uuid)
to authenticated;
