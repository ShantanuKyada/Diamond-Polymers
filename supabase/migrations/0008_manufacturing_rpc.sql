-- =============================================================================
-- 0008_manufacturing_rpc.sql — atomic write API for the manufacturing loop
--
-- LOCK ORDER (the rule that keeps concurrent RPCs deadlock-free)
--
--   finished_goods_stock  ->  raw_material_stock  ->  reusable_wastage_stock
--
-- and, within raw_material_stock, ascending raw_material_id. Every routine that
-- touches more than one balance takes them in this order and no other.
-- shred_pipe() is the first operation in the system to move finished goods and
-- raw material in the same transaction, which is what makes the rule necessary
-- rather than merely tidy: it takes the finished-goods row first, so it can
-- never sit holding a material row while a mixture holds the bundle row it
-- wants.
--
-- ATOMICITY. Every function below is one SECURITY DEFINER routine, so the entry
-- row, the ledger rows and the balance updates commit together or not at all.
-- A shred that cannot find its recycled pool leaves the bundles in stock.
--
-- IDEMPOTENCY. Each entry-creating RPC takes p_client_ref and returns the
-- existing row for a repeat, so a double tap or a timeout-then-retry cannot
-- produce two shreds.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Product resolution
--
-- Bundle weight is mandatory master data: it is the only bridge between the
-- kilograms that go in and the bundles that come out. Rather than let an entry
-- through with a NULL weight — which would quietly drop that run out of every
-- material balance — resolution fails with a message naming the product an
-- administrator has to configure.
-- -----------------------------------------------------------------------------

create or replace function app.resolve_pipe_product(
  p_pipe_type_id uuid,
  p_pipe_size_id uuid
)
returns public.pipe_products
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_product public.pipe_products;
  v_label   text;
begin
  select * into v_product
  from public.pipe_products
  where pipe_type_id = p_pipe_type_id
    and pipe_size_id = p_pipe_size_id;

  if v_product.id is null then
    select t.name || ' — ' || s.name into v_label
    from public.pipe_types t, public.pipe_sizes s
    where t.id = p_pipe_type_id and s.id = p_pipe_size_id;

    raise exception using
      errcode = 'DP008',
      message = format('No bundle weight is configured for %s. '
                       'An administrator must add it under Products before this '
                       'can be recorded.', coalesce(v_label, 'that product')),
      detail  = json_build_object('pipe_type_id', p_pipe_type_id,
                                  'pipe_size_id', p_pipe_size_id,
                                  'label', v_label)::text;
  end if;

  if not v_product.active then
    raise exception using
      errcode = 'DP005',
      message = 'That product has been discontinued.',
      detail  = json_build_object('pipe_product_id', v_product.id)::text;
  end if;

  return v_product;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Machine capability
--
-- Opt-in per machine: a machine with no configured products is unconstrained, so
-- switching this on for one line does not stop the rest of the factory working.
-- -----------------------------------------------------------------------------

create or replace function app.assert_machine_can_make(
  p_machine_id      uuid,
  p_pipe_product_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_configured boolean;
  v_allowed    boolean;
  v_machine    text;
  v_product    text;
begin
  if coalesce(app.setting('enforce_machine_product', 'true'), 'true') <> 'true' then
    return;
  end if;

  select exists (
    select 1 from public.machine_products
    where machine_id = p_machine_id and active
  ) into v_configured;

  if not v_configured then
    return;
  end if;

  select exists (
    select 1 from public.machine_products
    where machine_id = p_machine_id
      and pipe_product_id = p_pipe_product_id
      and active
  ) into v_allowed;

  if not v_allowed then
    select m.name into v_machine from public.machines m where m.id = p_machine_id;

    select t.name || ' — ' || s.name into v_product
    from public.pipe_products p
    join public.pipe_types t on t.id = p.pipe_type_id
    join public.pipe_sizes s on s.id = p.pipe_size_id
    where p.id = p_pipe_product_id;

    raise exception using
      errcode = 'DP009',
      message = format('%s is not set up to run %s.',
                       coalesce(v_machine, 'That machine'),
                       coalesce(v_product, 'that product')),
      detail  = json_build_object('machine_id', p_machine_id,
                                  'pipe_product_id', p_pipe_product_id)::text;
  end if;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- Recycled pool resolution for a shred
--
-- Explicit choice wins; then the pool configured on the pipe type; then, if the
-- factory keeps exactly one pool, that one. Guessing between two pools would
-- risk putting black regrind into white pipe, so more than one and no default
-- is an error rather than a coin toss.
-- -----------------------------------------------------------------------------

create or replace function app.resolve_recycled_material(
  p_pipe_type_id         uuid,
  p_recycled_material_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id      uuid := p_recycled_material_id;
  v_count   integer;
  v_active  boolean;
  v_recycle boolean;
  v_name    text;
begin
  if v_id is null then
    select recycled_material_id into v_id
    from public.pipe_types
    where id = p_pipe_type_id;
  end if;

  if v_id is null then
    select count(*) into v_count
    from public.raw_materials
    where is_recycled and active;

    if v_count = 1 then
      select id into v_id from public.raw_materials where is_recycled and active;
    end if;
  end if;

  if v_id is null then
    raise exception using
      errcode = 'DP005',
      message = 'No recycled-material pool is configured for this pipe type. '
                'An administrator must set one before shredded pipe can be '
                'returned to stock.',
      detail  = json_build_object('pipe_type_id', p_pipe_type_id)::text;
  end if;

  select active, is_recycled, name
  into v_active, v_recycle, v_name
  from public.raw_materials
  where id = v_id;

  if v_active is null then
    raise exception using
      errcode = 'DP005',
      message = 'That recycled material does not exist.',
      detail  = json_build_object('raw_material_id', v_id)::text;
  end if;

  if not v_active then
    raise exception using
      errcode = 'DP005',
      message = format('%s is no longer in use.', v_name),
      detail  = json_build_object('raw_material_id', v_id)::text;
  end if;

  -- Shredded pipe going into a virgin-material pool would inflate virgin stock
  -- and destroy the virgin-vs-recycled split in every report.
  if not v_recycle then
    raise exception using
      errcode = 'DP005',
      message = format('%s is not a recycled-material pool. Shredded pipe must '
                       'return to a material marked as recycled.', v_name),
      detail  = json_build_object('raw_material_id', v_id)::text;
  end if;

  return v_id;
end;
$fn$;

-- =============================================================================
-- record_production — replaces the 0004 version
--
-- Adds three things and changes nothing else:
--   * resolves the product and SNAPSHOTS its bundle weight onto the entry, so
--     output_weight_kg is fixed at the moment of recording;
--   * refuses a product the machine is not set up to run;
--   * accepts an optional weighed total for yield variance.
--
-- Dropped and recreated rather than replaced: the signature gains a parameter,
-- and two overloads of the same name would make the PostgREST call ambiguous.
-- =============================================================================

drop function if exists public.record_production(
  uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text
);

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
  p_remarks          text default null,
  p_actual_weight_kg numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller    uuid;
  v_operator  uuid;
  v_existing  uuid;
  v_entry     uuid;
  v_product   public.pipe_products;
  v_resulting integer;
  v_output_kg numeric(14, 3);
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

  if p_actual_weight_kg is not null and p_actual_weight_kg < 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Weighed output cannot be negative.',
      detail  = '{"field":"actual_weight_kg"}';
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

  v_product := app.resolve_pipe_product(p_pipe_type_id, p_pipe_size_id);
  perform app.assert_machine_can_make(p_machine_id, v_product.id);

  insert into public.production_entries (
    entry_date, machine_id, operator_id, shift_id,
    pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, bundle_weight_kg, actual_weight_kg, wastage_quantity,
    client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_machine_id, v_operator, p_shift_id,
    p_pipe_type_id, p_pipe_size_id, v_product.id,
    p_bundle_quantity, v_product.bundle_weight_kg, p_actual_weight_kg,
    coalesce(p_wastage_quantity, 0),
    p_client_ref, v_caller, p_remarks
  )
  returning id, output_weight_kg into v_entry, v_output_kg;

  perform app.apply_fg_movement(
    p_pipe_type_id, p_pipe_size_id, 'PRODUCTION', p_bundle_quantity, v_caller,
    v_entry, 'production_entries', p_remarks
  );

  select quantity_bundles into v_resulting
  from public.finished_goods_stock
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  return jsonb_build_object(
    'id',               v_entry,
    'duplicate',        false,
    'bundle_quantity',  p_bundle_quantity,
    'bundle_weight_kg', v_product.bundle_weight_kg,
    'output_weight_kg', v_output_kg,
    'resulting_stock',  v_resulting
  );
end;
$fn$;

-- =============================================================================
-- shred_pipe — defective pipe becomes recycled raw material
--
-- The heart of the manufacturing loop. Two physical events, one transaction
-- each:
--
--   PRODUCTION_REJECT  pipe rejected at the machine before it was ever counted
--                      as a bundle. Finished goods are untouched — the bundles
--                      never existed. Only the regrind is added to stock.
--
--   FINISHED_BUNDLE    bundles already counted into stock and later found
--                      defective. The bundles come OUT of finished goods and the
--                      regrind goes IN to the recycled pool, together. A failure
--                      to add the regrind leaves the bundles in stock; a failure
--                      to remove the bundles means no regrind is created.
--
-- The material that comes back is ordinary raw-material stock, so the next
-- mixture consumes it through consume_raw_materials() with no special case.
-- =============================================================================

create or replace function public.shred_pipe(
  p_source               public.shred_source,
  p_pipe_type_id         uuid,
  p_pipe_size_id         uuid,
  p_recovered_kg         numeric,
  p_client_ref           uuid,
  p_bundle_quantity      integer default null,
  p_recycled_material_id uuid default null,
  p_machine_id           uuid default null,
  p_shift_id             uuid default null,
  p_operator_id          uuid default null,
  p_production_entry_id  uuid default null,
  p_entry_date           date default current_date,
  p_remarks              text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_caller     uuid;
  v_operator   uuid;
  v_existing   uuid;
  v_entry      uuid;
  v_product    public.pipe_products;
  v_product_id uuid;
  v_weight     numeric(10, 3);
  v_material   uuid;
  v_expected   numeric(12, 3);
  v_tolerance  numeric;
  v_ceiling    numeric(12, 3);
  v_bundles    integer;
  v_label      text;
  v_remaining  numeric(14, 3);
  v_fg_left    integer;
begin
  v_operator := coalesce(p_operator_id, app.current_profile_id());

  -- Shredding at a machine is an operator action and is checked against that
  -- operator's assignment. Shredding from the warehouse has no machine, so it
  -- only requires a signed-in profile.
  if p_machine_id is not null then
    v_caller := app.assert_can_record(v_operator, p_machine_id);
  else
    v_caller := app.require_profile();
  end if;

  -- Idempotent retry: the same submission returns the same shred.
  select id into v_existing from public.shred_entries where client_ref = p_client_ref;
  if v_existing is not null then
    return jsonb_build_object('id', v_existing, 'duplicate', true);
  end if;

  if p_recovered_kg is null or p_recovered_kg <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Recovered weight must be greater than zero.',
      detail  = '{"field":"recovered_kg"}';
  end if;

  -- Resolve the product for its weight. A reject shred can proceed without a
  -- configured weight, since no bundle count is involved; a bundle shred cannot,
  -- because the weight is what proves the recovered mass is plausible.
  begin
    v_product    := app.resolve_pipe_product(p_pipe_type_id, p_pipe_size_id);
    v_product_id := v_product.id;
    v_weight     := v_product.bundle_weight_kg;
  exception when sqlstate 'DP008' then
    if p_source = 'FINISHED_BUNDLE' then
      raise;
    end if;
    v_product_id := null;
    v_weight     := null;
  end;

  v_material := app.resolve_recycled_material(p_pipe_type_id, p_recycled_material_id);

  -- ---------------------------------------------------------------------------
  -- Shape validation. The table CHECK enforces this too; these raises exist so
  -- the operator sees a sentence rather than a constraint name.
  -- ---------------------------------------------------------------------------

  if p_source = 'FINISHED_BUNDLE' then
    if p_bundle_quantity is null or p_bundle_quantity <= 0 then
      raise exception using
        errcode = 'DP005',
        message = 'Say how many bundles were taken out of stock to be shredded.',
        detail  = '{"field":"bundle_quantity"}';
    end if;

    v_bundles  := p_bundle_quantity;
    v_expected := v_bundles * v_weight;

    v_tolerance := coalesce(
      nullif(app.setting('shred_recovery_tolerance_pct', '20'), '')::numeric, 20
    );
    v_ceiling := v_expected * (1 + v_tolerance / 100);

    -- Shredding cannot create mass. More recovered than went in is a mistyped
    -- number, and catching it here is far cheaper than unwinding the ledger.
    if p_recovered_kg > v_ceiling then
      select t.name || ' — ' || s.name into v_label
      from public.pipe_types t, public.pipe_sizes s
      where t.id = p_pipe_type_id and s.id = p_pipe_size_id;

      raise exception using
        errcode = 'DP005',
        message = format('%s bundles of %s hold about %s kg. %s kg cannot have '
                         'been recovered from them — check the weight.',
                         v_bundles,
                         coalesce(v_label, 'that product'),
                         trim(to_char(v_expected, 'FM999999990.999')),
                         trim(to_char(p_recovered_kg, 'FM999999990.999'))),
        detail  = json_build_object('bundle_quantity', v_bundles,
                                    'expected_kg', v_expected,
                                    'recovered_kg', p_recovered_kg,
                                    'ceiling_kg', v_ceiling)::text;
    end if;
  else
    if p_bundle_quantity is not null then
      raise exception using
        errcode = 'DP005',
        message = 'Pipe rejected at the machine was never counted as bundles, so '
                  'no bundle quantity applies. Record the weight only.',
        detail  = '{"field":"bundle_quantity"}';
    end if;

    v_bundles  := null;
    v_expected := null;
  end if;

  if p_production_entry_id is not null
     and not exists (select 1 from public.production_entries where id = p_production_entry_id)
  then
    raise exception using
      errcode = 'DP005',
      message = 'That production entry does not exist.',
      detail  = '{"field":"production_entry_id"}';
  end if;

  insert into public.shred_entries (
    entry_date, source, pipe_type_id, pipe_size_id, pipe_product_id,
    bundle_quantity, recovered_kg, expected_kg, recycled_material_id,
    machine_id, operator_id, shift_id, production_entry_id,
    client_ref, created_by, remarks
  )
  values (
    p_entry_date, p_source, p_pipe_type_id, p_pipe_size_id, v_product_id,
    v_bundles, p_recovered_kg, v_expected, v_material,
    p_machine_id, v_operator, p_shift_id, p_production_entry_id,
    p_client_ref, v_caller, p_remarks
  )
  returning id into v_entry;

  -- ---------------------------------------------------------------------------
  -- Balances, in the documented lock order: finished goods first, then raw.
  -- ---------------------------------------------------------------------------

  if p_source = 'FINISHED_BUNDLE' then
    -- Raises DP002 and rolls the whole shred back if the bundles are not there.
    perform app.apply_fg_movement(
      p_pipe_type_id, p_pipe_size_id, 'SHRED', -v_bundles, v_caller,
      v_entry, 'shred_entries', p_remarks
    );
  end if;

  perform app.apply_raw_movement(
    v_material, 'SHRED_RETURN', p_recovered_kg, v_caller,
    p_machine_id, v_operator, v_entry, 'shred_entries', p_remarks
  );

  select quantity into v_remaining
  from public.raw_material_stock where raw_material_id = v_material;

  if p_source = 'FINISHED_BUNDLE' then
    select quantity_bundles into v_fg_left
    from public.finished_goods_stock
    where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

    -- Alerts fire only after the movement has succeeded, so a rejected shred
    -- never leaves a notification claiming stock was destroyed.
    perform app.check_low_fg_stock(p_pipe_type_id, p_pipe_size_id);

    select t.name || ' — ' || s.name into v_label
    from public.pipe_types t, public.pipe_sizes s
    where t.id = p_pipe_type_id and s.id = p_pipe_size_id;

    perform app.notify_role(
      'ADMIN',
      'Bundles shredded — ' || coalesce(v_label, 'product'),
      format('%s bundles of %s were shredded, recovering %s kg.',
             v_bundles, coalesce(v_label, 'product'),
             trim(to_char(p_recovered_kg, 'FM999999990.999'))),
      'WASTAGE',
      json_build_object('shred_entry_id', v_entry,
                        'bundle_quantity', v_bundles,
                        'recovered_kg', p_recovered_kg)::jsonb
    );
  end if;

  return jsonb_build_object(
    'id',                   v_entry,
    'duplicate',            false,
    'source',               p_source,
    'recovered_kg',         p_recovered_kg,
    'expected_kg',          v_expected,
    'recycled_material_id', v_material,
    'recycled_stock',       v_remaining,
    'finished_goods_stock', v_fg_left
  );
end;
$fn$;

-- =============================================================================
-- set_machine_products — replace a machine's product list in one transaction
--
-- A machine's capability set is edited as a whole. Doing it as delete-then-
-- insert from the client would leave a window where the machine can run nothing
-- and production is refused; here the swap is invisible to everyone else.
-- =============================================================================

create or replace function public.set_machine_products(
  p_machine_id       uuid,
  p_pipe_product_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_count integer;
begin
  if not exists (select 1 from public.machines where id = p_machine_id) then
    raise exception using
      errcode = 'DP005',
      message = 'That machine does not exist.',
      detail  = '{"field":"machine_id"}';
  end if;

  -- Lock the machine so two admins editing the same line serialise instead of
  -- interleaving their deletes and inserts.
  perform 1 from public.machines where id = p_machine_id for update;

  if p_pipe_product_ids is not null and array_length(p_pipe_product_ids, 1) > 0 then
    if exists (
      select 1
      from unnest(p_pipe_product_ids) id
      where not exists (select 1 from public.pipe_products p where p.id = id)
    ) then
      raise exception using
        errcode = 'DP005',
        message = 'One of those products does not exist.',
        detail  = '{"field":"pipe_product_ids"}';
    end if;
  end if;

  delete from public.machine_products where machine_id = p_machine_id;

  insert into public.machine_products (machine_id, pipe_product_id)
  select p_machine_id, id
  from unnest(coalesce(p_pipe_product_ids, '{}'::uuid[])) id
  on conflict do nothing;

  select count(*) into v_count
  from public.machine_products where machine_id = p_machine_id;

  return jsonb_build_object('machine_id', p_machine_id, 'product_count', v_count);
end;
$fn$;

-- =============================================================================
-- upsert_pipe_product — create or retune a product and its bundle weight
--
-- Admins could write the table directly under RLS; this exists because changing
-- a weight also has to seed the finished-goods row and leave a trail, and doing
-- that in one call keeps the two from drifting apart.
-- =============================================================================

create or replace function public.upsert_pipe_product(
  p_pipe_type_id     uuid,
  p_pipe_size_id     uuid,
  p_sku              text,
  p_bundle_weight_kg numeric,
  p_pipes_per_bundle integer default null,
  p_coil_length_m    numeric default null,
  p_active           boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_admin uuid := app.require_admin();
  v_id    uuid;
  v_prev  numeric(10, 3);
begin
  if p_bundle_weight_kg is null or p_bundle_weight_kg <= 0 then
    raise exception using
      errcode = 'DP005',
      message = 'Bundle weight must be greater than zero.',
      detail  = '{"field":"bundle_weight_kg"}';
  end if;

  if p_sku is null or length(btrim(p_sku)) = 0 then
    raise exception using
      errcode = 'DP005',
      message = 'A product code is required.',
      detail  = '{"field":"sku"}';
  end if;

  select id, bundle_weight_kg into v_id, v_prev
  from public.pipe_products
  where pipe_type_id = p_pipe_type_id and pipe_size_id = p_pipe_size_id;

  insert into public.pipe_products (
    pipe_type_id, pipe_size_id, sku, bundle_weight_kg,
    pipes_per_bundle, coil_length_m, active
  )
  values (
    p_pipe_type_id, p_pipe_size_id, btrim(p_sku), p_bundle_weight_kg,
    p_pipes_per_bundle, p_coil_length_m, coalesce(p_active, true)
  )
  on conflict (pipe_type_id, pipe_size_id) do update
    set sku              = excluded.sku,
        bundle_weight_kg = excluded.bundle_weight_kg,
        pipes_per_bundle = excluded.pipes_per_bundle,
        coil_length_m    = excluded.coil_length_m,
        active           = excluded.active
  returning id into v_id;

  -- Every product needs a finished-goods row so stock views show it at zero
  -- rather than omitting it entirely.
  insert into public.finished_goods_stock (pipe_type_id, pipe_size_id, quantity_bundles)
  values (p_pipe_type_id, p_pipe_size_id, 0)
  on conflict (pipe_type_id, pipe_size_id) do nothing;

  return jsonb_build_object(
    'id', v_id,
    'previous_weight_kg', v_prev,
    'bundle_weight_kg', p_bundle_weight_kg,
    'weight_changed', v_prev is distinct from p_bundle_weight_kg
  );
end;
$fn$;
