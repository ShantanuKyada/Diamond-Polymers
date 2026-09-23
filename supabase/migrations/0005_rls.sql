-- =============================================================================
-- 0005_rls.sql — Row Level Security (§38)
--
-- Two principles hold throughout:
--
--  1. NO TABLE GRANTS AN INSERT/UPDATE/DELETE POLICY FOR OPERATIONAL DATA.
--     Every write goes through a SECURITY DEFINER RPC in 0004, which validates
--     authorisation and stock before touching anything. An operator therefore
--     cannot manipulate inventory directly (§60 RULE 14) even with a stolen anon
--     key and a hand-crafted REST call — there is simply no policy that permits
--     the write.
--
--  2. Ledgers and entries are append-only (A18). Nobody, including Admin, gets an
--     UPDATE or DELETE policy on them. Corrections are new reversing rows.
--
-- Policies are scoped `to authenticated`. The `anon` role matches no policy at
-- all and so can read nothing.
-- =============================================================================

alter table public.profiles                      enable row level security;
alter table public.machines                      enable row level security;
alter table public.shifts                        enable row level security;
alter table public.pipe_types                    enable row level security;
alter table public.pipe_sizes                    enable row level security;
alter table public.raw_material_categories       enable row level security;
alter table public.raw_materials                 enable row level security;
alter table public.machine_assignments           enable row level security;
alter table public.raw_material_stock            enable row level security;
alter table public.raw_material_transactions     enable row level security;
alter table public.mixture_entries               enable row level security;
alter table public.mixture_entry_lines           enable row level security;
alter table public.finished_goods_stock          enable row level security;
alter table public.production_entries            enable row level security;
alter table public.finished_goods_transactions   enable row level security;
alter table public.dispatches                    enable row level security;
alter table public.dispatch_lines                enable row level security;
alter table public.wastage_entries               enable row level security;
alter table public.reusable_wastage_stock        enable row level security;
alter table public.reusable_wastage_transactions enable row level security;
alter table public.notifications                 enable row level security;
alter table public.notification_reads            enable row level security;
alter table public.app_settings                  enable row level security;

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (auth_user_id = auth.uid() or app.is_admin());

create policy profiles_admin_insert on public.profiles
  for insert to authenticated
  with check (app.is_admin());

create policy profiles_admin_update on public.profiles
  for update to authenticated
  using (app.is_admin())
  with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- Master data: everyone signed in may read it (the entry forms need it);
-- only Admin may change it (§38 "Operator must NOT modify master data").
-- -----------------------------------------------------------------------------

create policy machines_read on public.machines
  for select to authenticated using (true);
create policy machines_admin_write on public.machines
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy shifts_read on public.shifts
  for select to authenticated using (true);
create policy shifts_admin_write on public.shifts
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy pipe_types_read on public.pipe_types
  for select to authenticated using (true);
create policy pipe_types_admin_write on public.pipe_types
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy pipe_sizes_read on public.pipe_sizes
  for select to authenticated using (true);
create policy pipe_sizes_admin_write on public.pipe_sizes
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy raw_categories_read on public.raw_material_categories
  for select to authenticated using (true);
create policy raw_categories_admin_write on public.raw_material_categories
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy raw_materials_read on public.raw_materials
  for select to authenticated using (true);
create policy raw_materials_admin_write on public.raw_materials
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- machine_assignments: an operator sees only their own; only Admin may change
-- assignments (§38).
-- -----------------------------------------------------------------------------

create policy assignments_read on public.machine_assignments
  for select to authenticated
  using (app.is_admin() or operator_id = app.current_profile_id());

create policy assignments_admin_write on public.machine_assignments
  for all to authenticated
  using (app.is_admin()) with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- Stock balances: readable, never writable from a client.
-- Operators can see what is available, which is what makes the mixture form
-- useful; they still cannot change a single gram except through an RPC.
-- -----------------------------------------------------------------------------

create policy raw_stock_read on public.raw_material_stock
  for select to authenticated using (true);

create policy fg_stock_read on public.finished_goods_stock
  for select to authenticated using (true);

create policy reusable_stock_read on public.reusable_wastage_stock
  for select to authenticated using (true);

-- Admin may retune thresholds directly; quantities are still RPC-only because
-- no UPDATE policy grants the quantity columns... so thresholds move via the
-- master tables and finished_goods_stock gets an admin-only update for
-- minimum_stock. Quantity changes attempted here are rejected by the trigger below.
create policy fg_stock_admin_update on public.finished_goods_stock
  for update to authenticated
  using (app.is_admin()) with check (app.is_admin());

create or replace function app.guard_fg_stock_quantity()
returns trigger
language plpgsql
as $$
begin
  -- Only a SECURITY DEFINER routine (running as the table owner) may move stock.
  if new.quantity_bundles is distinct from old.quantity_bundles
     and current_user not in ('postgres', 'supabase_admin')
  then
    raise exception using
      errcode = 'DP004',
      message = 'Stock quantities can only be changed through a stock movement.',
      detail  = '{"reason":"direct_quantity_update"}';
  end if;
  return new;
end;
$$;

create trigger fg_stock_guard
  before update on public.finished_goods_stock
  for each row execute function app.guard_fg_stock_quantity();

-- -----------------------------------------------------------------------------
-- Ledgers: Admin sees everything; an operator sees only movements they caused.
-- Append-only for everyone (A18).
-- -----------------------------------------------------------------------------

create policy raw_txn_read on public.raw_material_transactions
  for select to authenticated
  using (
    app.is_admin()
    or operator_id  = app.current_profile_id()
    or created_by   = app.current_profile_id()
  );

create policy fg_txn_read on public.finished_goods_transactions
  for select to authenticated
  using (app.is_admin() or created_by = app.current_profile_id());

create policy reusable_txn_read on public.reusable_wastage_transactions
  for select to authenticated
  using (app.is_admin() or created_by = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Entries: an operator sees their own history (§29); Admin sees all.
-- -----------------------------------------------------------------------------

create policy mixture_read on public.mixture_entries
  for select to authenticated
  using (app.is_admin() or operator_id = app.current_profile_id());

create policy mixture_lines_read on public.mixture_entry_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.mixture_entries e
      where e.id = mixture_entry_id
        and (app.is_admin() or e.operator_id = app.current_profile_id())
    )
  );

create policy production_read on public.production_entries
  for select to authenticated
  using (app.is_admin() or operator_id = app.current_profile_id());

create policy wastage_read on public.wastage_entries
  for select to authenticated
  using (app.is_admin() or operator_id = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Dispatch is Admin-only in every direction (§22, §35).
-- -----------------------------------------------------------------------------

create policy dispatch_admin_read on public.dispatches
  for select to authenticated using (app.is_admin());

create policy dispatch_lines_admin_read on public.dispatch_lines
  for select to authenticated using (app.is_admin());

-- -----------------------------------------------------------------------------
-- Notifications (A10)
-- -----------------------------------------------------------------------------

create policy notifications_read on public.notifications
  for select to authenticated
  using (
    user_id = app.current_profile_id()
    or (user_id is null and target_role = app.current_role())
  );

create policy notification_reads_read on public.notification_reads
  for select to authenticated
  using (profile_id = app.current_profile_id());

create policy notification_reads_insert on public.notification_reads
  for insert to authenticated
  with check (profile_id = app.current_profile_id());

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

create policy settings_read on public.app_settings
  for select to authenticated using (true);

create policy settings_admin_write on public.app_settings
  for all to authenticated
  using (app.is_admin()) with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- Privileges on the `app` schema.
--
-- It is not in PostgREST's exposed schema list, so nothing in it is reachable
-- over REST. Belt-and-braces on top of that: strip EXECUTE from everything
-- (Postgres grants it to PUBLIC by default), then hand back only what has to be
-- callable by an ordinary user.
--
-- The identity helpers MUST stay callable by `authenticated`: RLS policy
-- expressions are evaluated as the querying user, so every policy above that
-- calls app.is_admin() would fail with "permission denied for schema app" if
-- this grant were missing. The privileged movement helpers stay revoked — they
-- are reached only from the SECURITY DEFINER RPCs, which run as the owner.
-- -----------------------------------------------------------------------------

grant usage on schema app to authenticated;
revoke execute on all functions in schema app from public;

grant execute on function
  app.current_profile_id(),
  app.current_role(),
  app.is_admin()
to authenticated;

-- Trigger functions fire on behalf of the writing user.
grant execute on function
  app.touch_updated_at(),
  app.guard_fg_stock_quantity()
to authenticated;

-- -----------------------------------------------------------------------------
-- Function grants: the RPCs are the only write path, so they must be callable.
-- -----------------------------------------------------------------------------

grant execute on function
  public.consume_raw_materials(uuid, uuid, jsonb, uuid, uuid, date, text),
  public.record_production(uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text),
  public.record_wastage(uuid, public.wastage_source, numeric, uuid, boolean, uuid, uuid, uuid, date, text),
  public.consume_reusable_wastage(uuid, numeric, uuid, text),
  public.mark_notification_read(uuid),
  public.mark_all_notifications_read(),
  public.operator_dashboard(date)
to authenticated;

-- Admin-gated at runtime by app.require_admin(); granting execute to all
-- authenticated users is safe because the function refuses non-admins.
grant execute on function
  public.create_dispatch(text, jsonb, uuid, date, text, text, text),
  public.add_raw_material_stock(uuid, numeric, uuid, text),
  public.adjust_raw_material_stock(uuid, numeric, uuid, text),
  public.adjust_finished_goods_stock(uuid, uuid, integer, uuid, text),
  public.admin_dashboard(date)
to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime (§40): only the streams that change what is on screen.
-- -----------------------------------------------------------------------------

alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.production_entries;
alter publication supabase_realtime add table public.raw_material_stock;
alter publication supabase_realtime add table public.finished_goods_stock;
