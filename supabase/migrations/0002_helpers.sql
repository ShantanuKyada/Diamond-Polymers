-- =============================================================================
-- 0002_helpers.sql — identity helpers, error convention, ledger movement helpers
--
-- ERROR CONVENTION (§45)
-- Every business failure raises a custom SQLSTATE so the Flutter layer can map it
-- to a friendly sentence without string-matching Postgres internals:
--
--   DP001  insufficient raw material stock
--   DP002  insufficient finished goods stock
--   DP003  insufficient reusable wastage
--   DP004  not authorised
--   DP005  invalid input
--   DP006  operator is not assigned to that machine
--   DP007  feature not configured (see A9)
--
-- MESSAGE carries a human sentence; DETAIL carries JSON for the UI to interpolate.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Identity (A17: SECURITY DEFINER so policies on profiles do not recurse)
-- -----------------------------------------------------------------------------

create or replace function app.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.id
  from public.profiles p
  where p.auth_user_id = auth.uid()
    and p.active
  limit 1;
$$;

create or replace function app.current_role()
returns public.user_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.role
  from public.profiles p
  where p.auth_user_id = auth.uid()
    and p.active
  limit 1;
$$;

create or replace function app.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(app.current_role() = 'ADMIN', false);
$$;

create or replace function app.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := app.current_profile_id();
begin
  if v_id is null then
    raise exception using
      errcode = 'DP004',
      message = 'You are not signed in.',
      detail  = '{"reason":"no_profile"}';
  end if;

  if not app.is_admin() then
    raise exception using
      errcode = 'DP004',
      message = 'This action requires an administrator account.',
      detail  = '{"reason":"not_admin"}';
  end if;

  return v_id;
end;
$$;

create or replace function app.require_profile()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := app.current_profile_id();
begin
  if v_id is null then
    raise exception using
      errcode = 'DP004',
      message = 'You are not signed in.',
      detail  = '{"reason":"no_profile"}';
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Settings accessor (A7, A9)
-- -----------------------------------------------------------------------------

create or replace function app.setting(p_key text, p_default text default null)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select value from public.app_settings where key = p_key), p_default);
$$;

-- -----------------------------------------------------------------------------
-- Notifications
-- -----------------------------------------------------------------------------

create or replace function app.notify_role(
  p_role    public.user_role,
  p_title   text,
  p_message text,
  p_type    public.notification_type,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into public.notifications (target_role, title, message, type, metadata)
  values (p_role, p_title, p_message, p_type, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Raw material movement
--
-- Locks the balance row, refuses to go negative, writes the ledger row.
-- Callers that touch several materials must pre-lock them in a deterministic
-- order (see app.lock_raw_materials) to avoid deadlock.
-- -----------------------------------------------------------------------------

create or replace function app.lock_raw_materials(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  -- Create any missing balance rows first, so the lock below always finds a row.
  insert into public.raw_material_stock (raw_material_id, quantity)
  select unnest(p_ids), 0
  on conflict (raw_material_id) do nothing;

  -- Deterministic order = no deadlock between concurrent baskets (A14).
  for v_id in
    select unnest(p_ids) order by 1
  loop
    perform 1 from public.raw_material_stock
    where raw_material_id = v_id
    for update;
  end loop;
end;
$$;

create or replace function app.apply_raw_movement(
  p_raw_material_id uuid,
  p_type            public.raw_txn_type,
  p_delta           numeric,
  p_created_by      uuid,
  p_machine_id      uuid default null,
  p_operator_id     uuid default null,
  p_reference_id    uuid default null,
  p_reference_table text default null,
  p_remarks         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev numeric(14, 3);
  v_next numeric(14, 3);
  v_txn  uuid;
  v_name text;
  v_unit text;
begin
  if p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A stock movement cannot be zero.',
      detail  = '{"field":"quantity"}';
  end if;

  insert into public.raw_material_stock (raw_material_id, quantity)
  values (p_raw_material_id, 0)
  on conflict (raw_material_id) do nothing;

  select quantity into v_prev
  from public.raw_material_stock
  where raw_material_id = p_raw_material_id
  for update;

  v_next := v_prev + p_delta;

  if v_next < 0 then
    select name, unit into v_name, v_unit
    from public.raw_materials where id = p_raw_material_id;

    raise exception using
      errcode = 'DP001',
      message = format('Insufficient %s stock. Available: %s %s.',
                       coalesce(v_name, 'material'),
                       trim(to_char(v_prev, 'FM999999990.999')),
                       coalesce(v_unit, 'kg')),
      detail  = json_build_object(
                  'raw_material_id', p_raw_material_id,
                  'name', v_name,
                  'available', v_prev,
                  'requested', abs(p_delta),
                  'unit', v_unit
                )::text;
  end if;

  update public.raw_material_stock
  set quantity = v_next, updated_at = now()
  where raw_material_id = p_raw_material_id;

  insert into public.raw_material_transactions (
    raw_material_id, transaction_type, quantity,
    previous_stock, resulting_stock,
    machine_id, operator_id, reference_id, reference_table,
    created_by, remarks
  )
  values (
    p_raw_material_id, p_type, p_delta,
    v_prev, v_next,
    p_machine_id, p_operator_id, p_reference_id, p_reference_table,
    p_created_by, p_remarks
  )
  returning id into v_txn;

  return v_txn;
end;
$$;

-- -----------------------------------------------------------------------------
-- Finished goods movement
-- -----------------------------------------------------------------------------

create or replace function app.apply_fg_movement(
  p_pipe_type_id    uuid,
  p_pipe_size_id    uuid,
  p_type            public.fg_txn_type,
  p_delta           integer,
  p_created_by      uuid,
  p_reference_id    uuid default null,
  p_reference_table text default null,
  p_remarks         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev integer;
  v_next integer;
  v_txn  uuid;
  v_label text;
begin
  if p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A stock movement cannot be zero.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles)
  values (p_pipe_type_id, p_pipe_size_id, 0)
  on conflict (pipe_type_id, pipe_size_id) do nothing;

  select quantity_bundles into v_prev
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id
    and pipe_size_id = p_pipe_size_id
  for update;

  v_next := v_prev + p_delta;

  if v_next < 0 then
    select t.name || ' — ' || s.name into v_label
    from public.pipe_types t, public.pipe_sizes s
    where t.id = p_pipe_type_id and s.id = p_pipe_size_id;

    raise exception using
      errcode = 'DP002',
      message = format('Insufficient finished-goods stock. Available: %s bundles.', v_prev),
      detail  = json_build_object(
                  'pipe_type_id', p_pipe_type_id,
                  'pipe_size_id', p_pipe_size_id,
                  'label', v_label,
                  'available', v_prev,
                  'requested', abs(p_delta)
                )::text;
  end if;

  update public.finished_goods_stock
  set quantity_bundles = v_next, updated_at = now()
  where pipe_type_id = p_pipe_type_id
    and pipe_size_id = p_pipe_size_id;

  insert into public.finished_goods_transactions (
    pipe_type_id, pipe_size_id, transaction_type, bundle_quantity,
    previous_stock, resulting_stock,
    reference_id, reference_table, created_by, remarks
  )
  values (
    p_pipe_type_id, p_pipe_size_id, p_type, p_delta,
    v_prev, v_next,
    p_reference_id, p_reference_table, p_created_by, p_remarks
  )
  returning id into v_txn;

  return v_txn;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reusable wastage movement
-- -----------------------------------------------------------------------------

create or replace function app.apply_reusable_movement(
  p_raw_material_id uuid,
  p_type            public.reusable_txn_type,
  p_delta           numeric,
  p_created_by      uuid,
  p_reference_id    uuid default null,
  p_reference_table text default null,
  p_remarks         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev numeric(14, 3);
  v_next numeric(14, 3);
  v_txn  uuid;
  v_name text;
  v_unit text;
begin
  insert into public.reusable_wastage_stock (raw_material_id, quantity)
  values (p_raw_material_id, 0)
  on conflict (raw_material_id) do nothing;

  select quantity into v_prev
  from public.reusable_wastage_stock
  where raw_material_id = p_raw_material_id
  for update;

  v_next := v_prev + p_delta;

  if v_next < 0 then
    select name, unit into v_name, v_unit
    from public.raw_materials where id = p_raw_material_id;

    raise exception using
      errcode = 'DP003',
      message = format('Insufficient reusable %s. Available: %s %s.',
                       coalesce(v_name, 'material'),
                       trim(to_char(v_prev, 'FM999999990.999')),
                       coalesce(v_unit, 'kg')),
      detail  = json_build_object(
                  'raw_material_id', p_raw_material_id,
                  'name', v_name,
                  'available', v_prev,
                  'requested', abs(p_delta),
                  'unit', v_unit
                )::text;
  end if;

  update public.reusable_wastage_stock
  set quantity = v_next, updated_at = now()
  where raw_material_id = p_raw_material_id;

  insert into public.reusable_wastage_transactions (
    raw_material_id, transaction_type, quantity,
    previous_quantity, resulting_quantity,
    reference_id, reference_table, created_by, remarks
  )
  values (
    p_raw_material_id, p_type, p_delta,
    v_prev, v_next,
    p_reference_id, p_reference_table, p_created_by, p_remarks
  )
  returning id into v_txn;

  return v_txn;
end;
$$;

-- -----------------------------------------------------------------------------
-- Low-stock alerting (§23, §41)
-- -----------------------------------------------------------------------------

create or replace function app.check_low_raw_stock(p_raw_material_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select m.name, m.unit, m.minimum_stock, s.quantity
  into r
  from public.raw_materials m
  join public.raw_material_stock s on s.raw_material_id = m.id
  where m.id = p_raw_material_id;

  if found and r.minimum_stock > 0 and r.quantity <= r.minimum_stock then
    perform app.notify_role(
      'ADMIN',
      'Low stock — ' || r.name,
      format('%s has only %s %s remaining.',
             r.name, trim(to_char(r.quantity, 'FM999999990.999')), r.unit),
      'STOCK_LOW',
      json_build_object('raw_material_id', p_raw_material_id,
                        'quantity', r.quantity,
                        'minimum_stock', r.minimum_stock)::jsonb
    );
  end if;
end;
$$;

create or replace function app.check_low_fg_stock(p_pipe_type_id uuid, p_pipe_size_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select t.name as type_name, sz.name as size_name,
         s.quantity_bundles, s.minimum_stock
  into r
  from public.finished_goods_stock s
  join public.pipe_types t on t.id = s.pipe_type_id
  join public.pipe_sizes sz on sz.id = s.pipe_size_id
  where s.pipe_type_id = p_pipe_type_id
    and s.pipe_size_id = p_pipe_size_id;

  if found and r.minimum_stock > 0 and r.quantity_bundles <= r.minimum_stock then
    perform app.notify_role(
      'ADMIN',
      format('Low stock — %s %s', r.type_name, r.size_name),
      format('%s %s has only %s bundles remaining.',
             r.type_name, r.size_name, r.quantity_bundles),
      'STOCK_LOW',
      json_build_object('pipe_type_id', p_pipe_type_id,
                        'pipe_size_id', p_pipe_size_id,
                        'quantity', r.quantity_bundles,
                        'minimum_stock', r.minimum_stock)::jsonb
    );
  end if;
end;
$$;
