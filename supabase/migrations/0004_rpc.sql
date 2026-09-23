-- =============================================================================
-- 0004_rpc.sql — the public API (§39)
--
-- Every stock-changing operation is one SECURITY DEFINER function so the whole
-- movement commits or rolls back together (§16, §60 RULE 6). Clients never write
-- to inventory tables directly; RLS in 0005 denies it outright.
--
-- Idempotency (§47): each entry-creating RPC takes p_client_ref. A retry with the
-- same ref returns the record that already exists instead of creating a twin.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Authorisation guard shared by the operator-facing RPCs
-- -----------------------------------------------------------------------------

create or replace function app.assert_can_record(p_operator_id uuid, p_machine_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller uuid := app.require_profile();
  v_ok     boolean;
begin
  -- Admin may record on behalf of any operator on any machine.
  if app.is_admin() then
    return v_caller;
  end if;

  if p_operator_id <> v_caller then
    raise exception using
      errcode = 'DP004',
      message = 'You can only record entries for yourself.',
      detail  = '{"reason":"operator_mismatch"}';
  end if;

  select exists (
    select 1
    from public.machine_assignments a
    where a.operator_id = p_operator_id
      and a.machine_id  = p_machine_id
      and a.active
      and a.effective_to is null
  ) into v_ok;

  if not v_ok then
    raise exception using
      errcode = 'DP006',
      message = 'You are not currently assigned to that machine.',
      detail  = json_build_object('operator_id', p_operator_id,
                                  'machine_id', p_machine_id)::text;
  end if;

  return v_caller;
end;
$$;

-- =============================================================================
-- consume_raw_materials  (§15, §16, §39)
--
-- p_lines: [{"raw_material_id": "<uuid>", "quantity": 25.5}, ...]
-- Validates the entire basket, then deducts. If any material is short, nothing
-- is deducted at all.
-- =============================================================================

create or replace function public.consume_raw_materials(
  p_machine_id  uuid,
  p_shift_id    uuid,
  p_lines       jsonb,
  p_client_ref  uuid,
  p_operator_id uuid default null,
  p_entry_date  date default current_date,
  p_remarks     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller   uuid;
  v_operator uuid;
  v_existing uuid;
  v_entry    uuid;
  v_total    numeric(14, 3) := 0;
  v_ids      uuid[];
  v_mat      uuid;
  r          record;
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());
  v_caller   := app.assert_can_record(v_operator, p_machine_id);

  -- Idempotent retry (§47).
  select id into v_existing from public.mixture_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter at least one material quantity.',
      detail  = '{"field":"lines"}';
  end if;

  -- Reject duplicate materials rather than silently summing them.
  if (select count(*) from jsonb_array_elements(p_lines) e)
     <> (select count(distinct (e->>'raw_material_id')) from jsonb_array_elements(p_lines) e)
  then
    raise exception using
      errcode = 'DP005',
      message = 'The same material appears twice in this mixture.',
      detail  = '{"field":"lines"}';
  end if;

  -- Deterministic lock order across the whole basket (A14).
  select array_agg(distinct (e->>'raw_material_id')::uuid)
  into v_ids
  from jsonb_array_elements(p_lines) e;

  perform app.lock_raw_materials(v_ids);

  select sum((e->>'quantity')::numeric)
  into v_total
  from jsonb_array_elements(p_lines) e;

  if v_total is null or v_total <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Total mixture quantity must be greater than zero.',
      detail  = '{"field":"total_quantity"}';
  end if;

  insert into public.mixture_entries (
    entry_date, machine_id, operator_id, shift_id,
    total_quantity, client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    v_total, p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  for r in
    select (e->>'raw_material_id')::uuid as material_id,
           (e->>'quantity')::numeric      as quantity
    from jsonb_array_elements(p_lines) e
    order by 1
  loop
    if r.quantity is null or r.quantity <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Every material quantity must be greater than zero.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    if not exists (select 1 from public.raw_materials where id = r.material_id and active) then
      raise exception using
        errcode = 'DP005',
        message = 'That material is no longer available.',
        detail  = json_build_object('raw_material_id', r.material_id)::text;
    end if;

    insert into public.mixture_entry_lines (mixture_entry_id, raw_material_id, quantity)
    values (v_entry, r.material_id, r.quantity);

    -- Raises DP001 and rolls the whole entry back if stock is short (§16).
    perform app.apply_raw_movement(
      r.material_id, 'PRODUCTION_CONSUMPTION', -r.quantity, v_caller,
      p_machine_id, v_operator, v_entry, 'mixture_entries', p_remarks
    );
  end loop;

  -- Alerts are raised after the basket succeeds, so a failed attempt never
  -- leaves a misleading notification behind.
  foreach v_mat in array v_ids loop
    perform app.check_low_raw_stock(v_mat);
  end loop;

  return jsonb_build_object(
    'id', v_entry,
    'duplicate', false,
    'total_quantity', v_total,
    'entry_date', p_entry_date
  );
end;
$$;

-- =============================================================================
-- record_production  (§18, §19, §39)
--
-- A7: wastage is recorded on the entry and does NOT reduce bundle_quantity.
-- =============================================================================

create or replace function public.record_production(
  p_machine_id       uuid,
  p_shift_id         uuid,
  p_pipe_type_id     uuid,
  p_pipe_size_id     uuid,
  p_bundle_quantity  integer,
  p_client_ref       uuid,
  p_operator_id      uuid default null,
  p_entry_date       date default current_date,
  p_wastage_quantity numeric default 0,
  p_remarks          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller    uuid;
  v_operator  uuid;
  v_existing  uuid;
  v_entry     uuid;
  v_resulting integer;
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());
  v_caller   := app.assert_can_record(v_operator, p_machine_id);

  select id into v_existing from public.production_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_bundle_quantity is null or p_bundle_quantity <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Bundles produced must be greater than zero.',
      detail  = '{"field":"bundle_quantity"}';
  end if;

  if coalesce(p_wastage_quantity, 0) < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Wastage cannot be negative.',
      detail  = '{"field":"wastage_quantity"}';
  end if;

  if not exists (select 1 from public.pipe_types where id = p_pipe_type_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe type is no longer available.',
      detail  = '{"field":"pipe_type_id"}';
  end if;

  if not exists (select 1 from public.pipe_sizes where id = p_pipe_size_id and active) then
    raise exception using
      errcode = 'DP005',
      message = 'That pipe size is no longer available.',
      detail  = '{"field":"pipe_size_id"}';
  end if;

  insert into public.production_entries (
    entry_date, machine_id, operator_id, shift_id,
    pipe_type_id, pipe_size_id, bundle_quantity, wastage_quantity,
    client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    p_pipe_type_id, p_pipe_size_id, p_bundle_quantity, coalesce(p_wastage_quantity, 0),
    p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  perform app.apply_fg_movement(
    p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', p_bundle_quantity, v_caller,
    v_entry, 'production_entries', p_remarks
  );

  select quantity_bundles into v_resulting
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  return jsonb_build_object(
    'id', v_entry,
    'duplicate', false,
    'bundle_quantity', p_bundle_quantity,
    'resulting_stock', v_resulting
  );
end;
$$;

-- =============================================================================
-- create_dispatch  (§22, §23, §39)
--
-- p_lines: [{"pipe_type_id":"<uuid>","pipe_size_id":"<uuid>","bundle_quantity":30}]
-- =============================================================================

create or replace function public.create_dispatch(
  p_customer_name  text,
  p_lines          jsonb,
  p_client_ref     uuid,
  p_dispatch_date  date default current_date,
  p_reference      text default null,
  p_vehicle_number text default null,
  p_remarks        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin    uuid := app.require_admin();
  v_existing uuid;
  v_dispatch uuid;
  v_total    integer := 0;
  r          record;
begin
  select id into v_existing from public.dispatches where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_customer_name is null or length(btrim(p_customer_name)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter a customer or destination.',
      detail  = '{"field":"customer_name"}';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Add at least one product to dispatch.',
      detail  = '{"field":"lines"}';
  end if;

  insert into public.dispatches (
    dispatch_date, customer_name, reference, vehicle_number,
    client_ref, created_by, remarks
  )
  values (
    p_dispatch_date, p_customer_name, p_reference, p_vehicle_number,
    p_client_ref, v_admin, p_remarks
  )
  returning id into v_dispatch;

  -- Ordered so concurrent dispatches lock products in the same sequence (A14).
  for r in
    select (e->>'pipe_type_id')::uuid    as type_id,
           (e->>'pipe_size_id')::uuid    as size_id,
           (e->>'bundle_quantity')::int  as qty
    from jsonb_array_elements(p_lines) e
    order by 1, 2
  loop
    if r.qty is null or r.qty <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Every dispatch quantity must be greater than zero.',
        detail  = '{"field":"bundle_quantity"}';
    end if;

    insert into public.dispatch_lines (dispatch_id, pipe_type_id, pipe_size_id, bundle_quantity)
    values (v_dispatch, r.type_id, r.size_id, r.qty);

    -- Raises DP002 and rolls back the whole dispatch if stock is short (§22).
    perform app.apply_fg_movement(
      r.type_id, r.size_id, 'DISPATCH', -r.qty, v_admin,
      v_dispatch, 'dispatches', p_remarks
    );

    v_total := v_total + r.qty;
  end loop;

  -- §23: one notification per product line, carrying the remaining stock.
  for r in
    select l.pipe_type_id, l.pipe_size_id, l.bundle_quantity,
           t.name as type_name, z.name as size_name,
           s.quantity_bundles as remaining
    from public.dispatch_lines l
    join public.pipe_types t on t.id = l.pipe_type_id
    join public.pipe_sizes z on z.id = l.pipe_size_id
    join public.finished_goods_stock s
      on s.pipe_type_id = l.pipe_type_id and s.pipe_size_id = l.pipe_size_id
    where l.dispatch_id = v_dispatch
  loop
    perform app.notify_role(
      'ADMIN',
      'Dispatch completed',
      format('%s %s — dispatched %s bundles. Remaining stock: %s bundles.',
             r.type_name, r.size_name, r.bundle_quantity, r.remaining),
      'DISPATCH',
      json_build_object('dispatch_id', v_dispatch,
                        'pipe_type_id', r.pipe_type_id,
                        'pipe_size_id', r.pipe_size_id,
                        'dispatched', r.bundle_quantity,
                        'remaining', r.remaining)::jsonb
    );

    perform app.check_low_fg_stock(r.pipe_type_id, r.pipe_size_id);
  end loop;

  return jsonb_build_object(
    'id', v_dispatch,
    'duplicate', false,
    'total_bundles', v_total
  );
end;
$$;

-- =============================================================================
-- record_wastage  (§24, §25, A8)
-- =============================================================================

create or replace function public.record_wastage(
  p_raw_material_id uuid,
  p_source          public.wastage_source,
  p_quantity        numeric,
  p_client_ref      uuid,
  p_reusable        boolean default false,
  p_machine_id      uuid default null,
  p_shift_id        uuid default null,
  p_operator_id     uuid default null,
  p_entry_date      date default current_date,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller   uuid;
  v_operator uuid;
  v_existing uuid;
  v_entry    uuid;
  v_unit     text;
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());

  if p_machine_id is not null then
    v_caller := app.assert_can_record(v_operator, p_machine_id);
  else
    v_caller := app.require_profile();
  end if;

  select id into v_existing from public.wastage_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Wastage quantity must be greater than zero.',
      detail  = '{"field":"quantity"}';
  end if;

  select unit into v_unit from public.raw_materials where id = p_raw_material_id and active;
  if v_unit is null then
    raise exception using
      errcode = 'DP005',
      message = 'That material is no longer available.',
      detail  = '{"field":"raw_material_id"}';
  end if;

  insert into public.wastage_entries (
    entry_date, machine_id, operator_id, shift_id, raw_material_id,
    source, quantity, unit, reusable, client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id, p_raw_material_id,
    p_source, p_quantity, v_unit, coalesce(p_reusable, false), p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  -- A8: only material that never entered a mixture is deducted from raw stock.
  -- PRODUCTION_SCRAP came out of material already consumed, so deducting it
  -- again would count the same loss twice.
  if p_source = 'RAW_MATERIAL_LOSS' then
    perform app.apply_raw_movement(
      p_raw_material_id, 'WASTAGE', -p_quantity, v_caller,
      p_machine_id, v_operator, v_entry, 'wastage_entries', p_remarks
    );
    perform app.check_low_raw_stock(p_raw_material_id);
  end if;

  -- Reusable scrap is collected into its own inventory, never back into raw (§25).
  if coalesce(p_reusable, false) then
    perform app.apply_reusable_movement(
      p_raw_material_id, 'RECOVERED', p_quantity, v_caller,
      v_entry, 'wastage_entries', p_remarks
    );
  end if;

  return jsonb_build_object('id', v_entry, 'duplicate', false);
end;
$$;

-- =============================================================================
-- consume_reusable_wastage  (§26, A9)
-- =============================================================================

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
as $$
declare
  v_caller uuid := app.require_profile();
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
    -- A9: the substitution ratio is a business rule the factory has not defined.
    -- Failing loudly is better than inventing arithmetic that silently corrupts stock.
    raise exception using
      errcode = 'DP007',
      message = 'Reusable-wastage substitution is not configured yet.',
      detail  = json_build_object('mode', v_mode)::text;
  end if;

  if exists (select 1 from public.reusable_wastage_transactions where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_reusable_movement(
    p_raw_material_id, 'CONSUMED', -p_quantity, v_caller,
    p_client_ref, 'manual', p_remarks
  );

  select quantity into v_left
  from public.reusable_wastage_stock
  where raw_material_id = p_raw_material_id;

  return jsonb_build_object('transaction_id', v_txn, 'duplicate', false, 'remaining', v_left);
end;
$$;

-- =============================================================================
-- Admin stock maintenance  (§13, §14)
-- =============================================================================

create or replace function public.add_raw_material_stock(
  p_raw_material_id uuid,
  p_quantity        numeric,
  p_client_ref      uuid,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := app.require_admin();
  v_txn   uuid;
  v_now   numeric(14, 3);
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Quantity added must be greater than zero.',
      detail  = '{"field":"quantity"}';
  end if;

  if exists (select 1 from public.raw_material_transactions where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_raw_movement(
    p_raw_material_id, 'STOCK_IN', p_quantity, v_admin,
    null, null, p_client_ref, 'manual', p_remarks
  );

  select quantity into v_now
  from public.raw_material_stock where raw_material_id = p_raw_material_id;

  return jsonb_build_object('transaction_id', v_txn, 'duplicate', false, 'resulting_stock', v_now);
end;
$$;

-- A signed correction. Negative values are allowed, but the balance still cannot
-- go below zero — apply_raw_movement enforces that.
create or replace function public.adjust_raw_material_stock(
  p_raw_material_id uuid,
  p_delta           numeric,
  p_client_ref      uuid,
  p_remarks         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := app.require_admin();
  v_txn   uuid;
  v_now   numeric(14, 3);
begin
  if p_delta is null or p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter an adjustment amount.',
      detail  = '{"field":"delta"}';
  end if;

  if p_remarks is null or length(btrim(p_remarks)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A reason is required for a manual adjustment.',
      detail  = '{"field":"remarks"}';
  end if;

  if exists (select 1 from public.raw_material_transactions where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_raw_movement(
    p_raw_material_id, 'MANUAL_ADJUSTMENT', p_delta, v_admin,
    null, null, p_client_ref, 'manual', p_remarks
  );

  select quantity into v_now
  from public.raw_material_stock where raw_material_id = p_raw_material_id;

  perform app.check_low_raw_stock(p_raw_material_id);

  return jsonb_build_object('transaction_id', v_txn, 'duplicate', false, 'resulting_stock', v_now);
end;
$$;

create or replace function public.adjust_finished_goods_stock(
  p_pipe_type_id uuid,
  p_pipe_size_id uuid,
  p_delta        integer,
  p_client_ref   uuid,
  p_remarks      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := app.require_admin();
  v_txn   uuid;
  v_now   integer;
begin
  if p_delta is null or p_delta = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Enter an adjustment amount.',
      detail  = '{"field":"delta"}';
  end if;

  if exists (select 1 from public.finished_goods_transactions where reference_id = p_client_ref) then
    return jsonb_build_object('duplicate', true);
  end if;

  v_txn := app.apply_fg_movement(
    p_pipe_type_id, p_pipe_size_id, 'ADJUSTMENT', p_delta, v_admin,
    p_client_ref, 'manual', p_remarks
  );

  select quantity_bundles into v_now
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  perform app.check_low_fg_stock(p_pipe_type_id, p_pipe_size_id);

  return jsonb_build_object('transaction_id', v_txn, 'duplicate', false, 'resulting_stock', v_now);
end;
$$;

-- =============================================================================
-- Notifications
-- =============================================================================

create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := app.require_profile();
begin
  insert into public.notification_reads (notification_id, profile_id)
  values (p_notification_id, v_me)
  on conflict do nothing;
end;
$$;

create or replace function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me   uuid := app.require_profile();
  v_role public.user_role := app.current_role();
  v_n    integer;
begin
  insert into public.notification_reads (notification_id, profile_id)
  select n.id, v_me
  from public.notifications n
  where (n.user_id = v_me or (n.user_id is null and n.target_role = v_role))
  on conflict do nothing;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- =============================================================================
-- Dashboards (§27, §28, §51) — one round trip each.
-- =============================================================================

create or replace function public.admin_dashboard(p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := app.require_admin();
begin
  return jsonb_build_object(
    'date', p_date,

    'production', (
      select jsonb_build_object(
        'total_bundles', coalesce(sum(bundle_quantity), 0),
        'total_wastage', coalesce(sum(wastage_quantity), 0),
        'entry_count',   count(*)
      )
      from public.production_entries where entry_date = p_date
    ),

    'production_by_machine', (
      select coalesce(jsonb_agg(x order by x->>'machine_name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'machine_id', e.machine_id,
                 'machine_name', mc.name,
                 'bundles', sum(e.bundle_quantity)
               ) as x
        from public.production_entries e
        join public.machines mc on mc.id = e.machine_id
        where e.entry_date = p_date
        group by e.machine_id, mc.name
      ) s
    ),

    'production_by_type', (
      select coalesce(jsonb_agg(x order by x->>'pipe_type_name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'pipe_type_id', e.pipe_type_id,
                 'pipe_type_name', t.name,
                 'bundles', sum(e.bundle_quantity)
               ) as x
        from public.production_entries e
        join public.pipe_types t on t.id = e.pipe_type_id
        where e.entry_date = p_date
        group by e.pipe_type_id, t.name
      ) s
    ),

    'production_by_size', (
      select coalesce(jsonb_agg(x order by x->>'pipe_size_name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'pipe_size_id', e.pipe_size_id,
                 'pipe_size_name', z.name,
                 'bundles', sum(e.bundle_quantity)
               ) as x
        from public.production_entries e
        join public.pipe_sizes z on z.id = e.pipe_size_id
        where e.entry_date = p_date
        group by e.pipe_size_id, z.name
      ) s
    ),

    'raw_materials', (
      select coalesce(jsonb_agg(to_jsonb(v) order by v.name), '[]'::jsonb)
      from public.v_raw_material_stock v
      where v.active
    ),

    'raw_consumption_today', (
      select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'raw_material_id', tr.raw_material_id,
                 'name', rm.name,
                 'unit', rm.unit,
                 'consumed', abs(sum(tr.quantity))
               ) as x
        from public.raw_material_transactions tr
        join public.raw_materials rm on rm.id = tr.raw_material_id
        where tr.transaction_type = 'PRODUCTION_CONSUMPTION'
          and tr.created_at::date = p_date
        group by tr.raw_material_id, rm.name, rm.unit
      ) s
    ),

    'finished_goods', (
      select coalesce(jsonb_agg(to_jsonb(v)
               order by v.pipe_type_name, v.sort_order), '[]'::jsonb)
      from public.v_finished_goods_stock v
    ),

    'finished_goods_total', (
      select coalesce(sum(quantity_bundles), 0) from public.finished_goods_stock
    ),

    'dispatch_today', (
      select jsonb_build_object(
        'total_bundles',  coalesce(sum(l.bundle_quantity), 0),
        'dispatch_count', count(distinct d.id)
      )
      from public.dispatches d
      join public.dispatch_lines l on l.dispatch_id = d.id
      where d.dispatch_date = p_date
    ),

    'wastage_today', (
      select jsonb_build_object(
        'raw_wastage',      coalesce(sum(quantity) filter (where source = 'RAW_MATERIAL_LOSS'), 0),
        'production_scrap', coalesce(sum(quantity) filter (where source = 'PRODUCTION_SCRAP'), 0),
        'reusable',         coalesce(sum(quantity) filter (where reusable), 0)
      )
      from public.wastage_entries where entry_date = p_date
    ),

    'reusable_wastage', (
      select coalesce(jsonb_agg(to_jsonb(v) order by v.name), '[]'::jsonb)
      from public.v_reusable_wastage_stock v
      where v.quantity > 0
    ),

    'machines', (
      select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'machine_id', mc.id,
                 'code', mc.code,
                 'name', mc.name,
                 'status', mc.status,
                 'operators', (
                   select coalesce(jsonb_agg(a.operator_name order by a.operator_name), '[]'::jsonb)
                   from public.v_current_machine_assignments a
                   where a.machine_id = mc.id
                 ),
                 'bundles_today', coalesce((
                   select sum(e.bundle_quantity)
                   from public.production_entries e
                   where e.machine_id = mc.id and e.entry_date = p_date
                 ), 0)
               ) as x
        from public.machines mc
        where mc.active
      ) s
    ),

    'unread_notifications', (
      select count(*)
      from public.notifications n
      where (n.user_id = v_me or (n.user_id is null and n.target_role = 'ADMIN'))
        and not exists (
          select 1 from public.notification_reads r
          where r.notification_id = n.id and r.profile_id = v_me
        )
    )
  );
end;
$$;

create or replace function public.operator_dashboard(p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := app.require_profile();
begin
  return jsonb_build_object(
    'date', p_date,

    'profile', (
      select to_jsonb(x) from (
        select p.id, p.name, p.employee_code, p.role
        from public.profiles p where p.id = v_me
      ) x
    ),

    'assignment', (
      select to_jsonb(a)
      from public.v_current_machine_assignments a
      where a.operator_id = v_me
      limit 1
    ),

    'production_today', (
      select jsonb_build_object(
        'total_bundles', coalesce(sum(bundle_quantity), 0),
        'total_wastage', coalesce(sum(wastage_quantity), 0),
        'entry_count',   count(*)
      )
      from public.production_entries
      where operator_id = v_me and entry_date = p_date
    ),

    'consumption_today', (
      select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'name', rm.name,
                 'unit', rm.unit,
                 'consumed', sum(l.quantity)
               ) as x
        from public.mixture_entries e
        join public.mixture_entry_lines l on l.mixture_entry_id = e.id
        join public.raw_materials rm on rm.id = l.raw_material_id
        where e.operator_id = v_me and e.entry_date = p_date
        group by rm.name, rm.unit
      ) s
    ),

    'recent_production', (
      select coalesce(jsonb_agg(to_jsonb(v) order by v.created_at desc), '[]'::jsonb)
      from (
        select * from public.v_production_entries
        where operator_id = v_me
        order by created_at desc
        limit 5
      ) v
    )
  );
end;
$$;
