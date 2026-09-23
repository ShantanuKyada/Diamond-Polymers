-- =============================================================================
-- 0010_manufacturing_rls.sql — row level security and grants for the new tables
--
-- The two principles from 0005 carry over unchanged:
--
--   1. No operational table grants INSERT. `shred_entries` is written only by
--      shred_pipe(), which validates the bundles, the recovered weight and the
--      destination pool before moving anything. There is no policy that would
--      let a client insert a shred directly, so a hand-crafted REST call cannot
--      manufacture recycled stock out of nothing.
--
--   2. Ledgers and entries are append-only. `shred_entries` and
--      `pipe_product_weight_history` get no UPDATE or DELETE policy for anyone,
--      administrators included.
--
-- Master data is the exception, as before: products and machine capabilities are
-- editable by an administrator, because they describe the factory rather than
-- record what happened in it.
-- =============================================================================

alter table public.pipe_products              enable row level security;
alter table public.pipe_product_weight_history enable row level security;
alter table public.machine_products           enable row level security;
alter table public.shred_entries              enable row level security;

-- -----------------------------------------------------------------------------
-- Products: everyone signed in reads them — the production form cannot show a
-- bundle weight it is not allowed to see. Only an administrator changes them.
-- -----------------------------------------------------------------------------

drop policy if exists pipe_products_read on public.pipe_products;
create policy pipe_products_read on public.pipe_products
  for select to authenticated using (true);

drop policy if exists pipe_products_admin_write on public.pipe_products;
create policy pipe_products_admin_write on public.pipe_products
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- Weight history is an audit trail: administrators read it, nobody writes it
-- from a client. The trigger that fills it runs SECURITY DEFINER.
drop policy if exists pipe_weight_history_admin_read on public.pipe_product_weight_history;
create policy pipe_weight_history_admin_read on public.pipe_product_weight_history
  for select to authenticated using (app.is_admin());

-- -----------------------------------------------------------------------------
-- Machine capabilities: readable by all so an operator's product list can be
-- filtered to what their machine actually runs; writable only by an admin.
-- -----------------------------------------------------------------------------

drop policy if exists machine_products_read on public.machine_products;
create policy machine_products_read on public.machine_products
  for select to authenticated using (true);

drop policy if exists machine_products_admin_write on public.machine_products;
create policy machine_products_admin_write on public.machine_products
  for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- -----------------------------------------------------------------------------
-- Shred entries: an operator sees the shreds they recorded, an admin sees all.
-- No INSERT, UPDATE or DELETE policy — shred_pipe() is the only way in.
-- -----------------------------------------------------------------------------

drop policy if exists shred_entries_read on public.shred_entries;
create policy shred_entries_read on public.shred_entries
  for select to authenticated
  using (
    app.is_admin()
    or operator_id = app.current_profile_id()
    or created_by  = app.current_profile_id()
  );

-- -----------------------------------------------------------------------------
-- Privileges on the app schema
--
-- 0005 stripped EXECUTE from PUBLIC for everything that existed then. Functions
-- added since have picked up the default PUBLIC grant again, so strip and
-- re-grant. The privileged helpers — product resolution, capability checks, pool
-- resolution — stay revoked: they are reached only from SECURITY DEFINER RPCs,
-- which run as the owner and do not need the caller to hold EXECUTE.
-- -----------------------------------------------------------------------------

revoke execute on all functions in schema app from public;

grant execute on function
  app.current_profile_id(),
  app.current_role(),
  app.is_admin()
to authenticated;

-- Trigger functions fire on behalf of the writing user, so the writer needs
-- EXECUTE even though the body runs as the owner.
grant execute on function
  app.touch_updated_at(),
  app.guard_fg_stock_quantity(),
  app.record_pipe_weight_change()
to authenticated;

-- -----------------------------------------------------------------------------
-- RPC grants
--
-- record_production was dropped and recreated in 0008 with an extra parameter,
-- which took its old grant with it; it has to be granted again here.
-- The admin-only routines are granted to all authenticated users because each
-- one calls app.require_admin() and refuses anyone else at runtime — the check
-- lives in the function, not in who may call it.
-- -----------------------------------------------------------------------------

grant execute on function
  public.record_production(uuid, uuid, uuid, uuid, integer, uuid, uuid, date, numeric, text, numeric),
  public.shred_pipe(public.shred_source, uuid, uuid, numeric, uuid, integer, uuid, uuid, uuid, uuid, uuid, date, text)
to authenticated;

grant execute on function
  public.set_machine_products(uuid, uuid[]),
  public.upsert_pipe_product(uuid, uuid, text, numeric, integer, numeric, boolean)
to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: the shred log changes what an admin sees on the wastage screen.
-- Guarded because adding a table twice is an error.
-- -----------------------------------------------------------------------------

do $mig$
begin
  alter publication supabase_realtime add table public.shred_entries;
exception when duplicate_object then null;
end
$mig$;
