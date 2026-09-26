-- =============================================================================
-- 0017_factory_identity.sql — the factory's own details, for paperwork
--
-- A delivery challan travels with the goods and has to say who sent them. Until
-- now the only thing the database knew about the factory was its name.
--
-- These are `app_settings` rows rather than a table because there is exactly one
-- factory, and a one-row table is a table you have to remember to populate. They
-- are editable from Configuration like every other setting, so the address on
-- the paperwork is never a literal compiled into an APK.
--
-- Deliberately blank by default. A challan printed with an empty address looks
-- unfinished, which is the correct signal — better than shipping a placeholder
-- that reads as real and travels out to a buyer.
--
-- Safe to re-run: existing values are never overwritten.
-- =============================================================================

insert into public.app_settings (key, value, description) values
  ('factory_address', '',
   'Postal address of the factory, shown on delivery challans. Line breaks are '
   'kept as typed.'),
  ('factory_phone', '',
   'Contact number shown on delivery challans.'),
  ('factory_gstin', '',
   'GSTIN shown on delivery challans. Leave blank if not registered — the line '
   'is omitted rather than printed empty.'),
  ('challan_prefix', 'DC',
   'Prefix for the delivery challan number, e.g. DC-20260926-4F2A. The suffix '
   'is derived from the dispatch itself, so the number is stable and traceable '
   'back to the record without a separate counter.'),
  ('challan_footer', '',
   'Optional line printed at the foot of a challan — terms, a declaration, or '
   'nothing at all.')
on conflict (key) do update
  -- The description may improve; a value the factory has typed must not be
  -- clobbered by a re-run.
  set description = excluded.description;
