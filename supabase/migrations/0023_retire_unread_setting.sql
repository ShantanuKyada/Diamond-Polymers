-- =============================================================================
-- 0023_retire_unread_setting.sql — a setting nothing reads (A42)
--
-- `recycled_input_mode` was written in 0007 to record a decision: shredded pipe
-- is stocked as a RECYCLED-category raw material and mixed through
-- consume_raw_materials() like any other input.
--
-- That decision holds. What never existed is any code that reads the setting —
-- not a migration, not an RPC, not the app. Changing it would do nothing at
-- all, which is the worst kind of switch to leave on a configuration screen.
--
-- The same reasoning retired four payroll settings in 0019: a setting nobody
-- reads is a promise the system has stopped keeping. The decision it recorded
-- stays, in the comment on shred_pipe() and in docs/04-pipe-manufacturing.md,
-- where a decision belongs.
-- =============================================================================

delete from public.app_settings where key = 'recycled_input_mode';

-- low_stock_banner_enabled is the same thing, found by the same check. It was
-- seeded with "Show the low-stock banner on the admin dashboard", and the
-- dashboard shows that banner whenever something is actually low, regardless of
-- this value. Turning it off did nothing then and does nothing now.
delete from public.app_settings where key = 'low_stock_banner_enabled';

-- -----------------------------------------------------------------------------
-- While we are here: say what the two live switches actually do
--
-- The Configuration screen shows each setting's description beneath its name,
-- so these are what an administrator reads before changing a rule. Both were
-- written for whoever was reading the migration, not for them.
-- -----------------------------------------------------------------------------

update public.app_settings
set description =
  'Refuse production of a product the machine is not set up to run. Machines '
  'with no products configured are unconstrained either way, so this only '
  'binds once somebody has said which machine runs what.'
where key = 'enforce_machine_product';

update public.app_settings
set description =
  'A shred may not recover more than the bundle weighed plus this percentage. '
  'Recovering more mass than went in is impossible, so this catches a mistyped '
  'weight before it corrupts stock. Raise it if the weight specs are rough.'
where key = 'shred_recovery_tolerance_pct';
