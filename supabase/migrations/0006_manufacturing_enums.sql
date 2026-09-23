-- =============================================================================
-- 0006_manufacturing_enums.sql — enum extensions for the pipe manufacturing loop
--
-- RUN THIS FILE ON ITS OWN, NOT INSIDE AN EXPLICIT TRANSACTION.
--
-- Postgres permits ALTER TYPE ... ADD VALUE inside a transaction block, but the
-- new label cannot be *used* until that transaction commits. Keeping the enum
-- changes in their own file means 0007 onwards may reference the new labels
-- freely. Every statement is guarded, so the file is safe to re-run.
-- =============================================================================

-- Shredded pipe returning to stock as recycled raw material. Distinct from
-- RECOVERED_WASTAGE, which is spillage swept up and re-screened — different
-- physical event, different reporting line.
alter type public.raw_txn_type add value if not exists 'SHRED_RETURN';

-- Bundles destroyed by shredding. Distinct from ADJUSTMENT so that "stock that
-- was reground" never hides inside "stock someone corrected".
alter type public.fg_txn_type add value if not exists 'SHRED';

-- Where the shredded pipe came from.
--   PRODUCTION_REJECT — caught at the machine during the run; the pipe was never
--                       counted as a good bundle, so finished goods are untouched.
--   FINISHED_BUNDLE   — a bundle already counted into stock, later found
--                       defective; the bundles must come back out of stock.
do $$
begin
  create type public.shred_source as enum ('PRODUCTION_REJECT', 'FINISHED_BUNDLE');
exception
  when duplicate_object then null;
end
$$;
