-- =============================================================================
-- 0016_operator_material_entry.sql — operators record their own material (A34)
--
-- Reverses A30, at the factory's request. A30 moved Material Entry to
-- administrators on the reasoning that drawing down raw stock is an
-- administrative act. In practice every operator has their own machine and is
-- the person physically loading it, so making them walk to an administrator to
-- record what they just poured in produced late entries, not safer ones.
--
-- What changes: exactly one block of consume_raw_materials(). Administrators
-- keep every power they had. Operators gain the ability to record a batch for
-- THEIR OWN assigned machine and nothing else, enforced by the same
-- app.assert_can_record() that already governs record_production():
--
--   * recording for another person      -> DP004
--   * recording for another machine     -> DP006
--
-- Everything else is untouched: there is still no INSERT policy on the mixture
-- tables, so this function remains the only write path; the basket is still
-- validated whole before anything is deducted; and the client reference still
-- makes a retry safe.
--
-- Safe to re-run.
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
  -- A34 (reverses A30): the operator loads their own machine, so the operator
  -- records what went into it. Administrators keep the wider power they had.
  --
  -- The split below is the whole of the change. An administrator may still name
  -- any operator and any machine. Anybody else goes through
  -- app.assert_can_record(), which refuses to let them record for someone else
  -- (DP004) or for a machine they are not currently assigned to (DP006) — the
  -- same guard record_production() has always used, so material and production
  -- are now governed by one rule rather than two.
  if not app.is_admin() then
    v_operator := coalesce(p_operator_id, app.current_profile_id());
    v_caller   := app.assert_can_record(v_operator, p_machine_id);
  elsif p_operator_id is not null then
    v_caller := app.require_admin();
    if not exists (
      select 1 from public.profiles where id = p_operator_id and active
    ) then
      raise exception using
        errcode = 'DP005',
        message = 'That operator is not active.',
        detail  = '{"field":"operator_id"}';
    end if;
    v_operator := p_operator_id;
  else
    v_caller := app.require_admin();
    -- Credited to whoever runs the machine, preferring the operator assigned to
    -- this shift; the administrator only when the machine has nobody.
    select a.operator_id into v_operator
    from public.machine_assignments a
    where a.machine_id = p_machine_id
      and a.active
      and a.effective_to is null
    order by (a.shift_id = p_shift_id) desc nulls last, a.effective_from desc
    limit 1;

    v_operator := coalesce(v_operator, v_caller);
  end if;

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
