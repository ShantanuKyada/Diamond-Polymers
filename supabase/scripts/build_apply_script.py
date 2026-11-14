"""Rebuild scripts/apply_0015_to_0024.sql from migrations/.

The live project was set up before the change request and sits at 0014. Ten
migrations stand between it and the app, and pasting ten files into the SQL
editor one after another, in a migration window, is how one gets skipped.

Run from supabase/:

    python scripts/build_apply_script.py

supabase/tests/go_live.test.mjs applies the result to a database shaped like
the live one and checks it against applying the ten separately, so the file
cannot drift from what it was generated out of without a test saying so.
"""
import io

MIGRATIONS = [
    '0015_packaging_shifts_access.sql',
    '0016_operator_material_entry.sql',
    '0017_factory_identity.sql',
    '0018_production_batch_link.sql',
    '0019_simple_payroll.sql',
    '0020_worker_profiles_and_salary_payments.sql',
    '0021_employee_types_and_any_machine.sql',
    '0022_employee_roles_master.sql',
    '0023_retire_unread_setting.sql',
    '0024_entry_dates_and_wastage_access.sql',
]

HEAD = """-- =============================================================================
-- apply_0015_to_0024.sql — the whole migration window, in one paste
--
-- GENERATED. Do not edit: run supabase/scripts/build_apply_script.py to
-- rebuild it from migrations/, and supabase/tests/go_live.test.mjs checks that
-- what is here is what is there.
--
-- A live project that was set up before the change request is at 0014. This
-- brings it to 0024 in one go.
--
--   HOW      Supabase Dashboard -> SQL Editor -> New query -> paste the whole
--            file -> Run. It is ten migrations concatenated in order; none of
--            them adds an enum value, which is the one thing that cannot share
--            a transaction with its own use, so they can travel together.
--
--   FIRST    Take a backup. Dashboard -> Database -> Backups.
--            Then run checks/0015_preflight.sql and read every row.
--
--   AFTER    Run the verify scripts in checks/, and the reconciliation:
--              select * from public.v_stock_reconciliation where not ok;
--            Zero rows is correct.
--
--   SAFE TO RE-RUN. Every migration in here is written to be, and the whole
--   file has been applied twice in a row to a database with history on it.
--
-- Nothing is lost: supabase/tests/go_live.test.mjs builds a database shaped
-- like the live one, applies this, and checks every production entry, both
-- stock balances, the ledgers and the administrator's login afterwards.
-- =============================================================================

"""


def build() -> str:
    parts = [HEAD]
    for name in MIGRATIONS:
        body = io.open(f'migrations/{name}', encoding='utf-8').read().rstrip('\n')
        bar = '-' * 77
        parts.append(f'\n-- {bar}\n-- {name}\n-- {bar}\n\n{body}\n')
    return '\n'.join(parts) + '\n'


if __name__ == '__main__':
    out = build()
    io.open('scripts/apply_0015_to_0024.sql', 'w',
            encoding='utf-8', newline='\n').write(out)
    print(f'wrote scripts/apply_0015_to_0024.sql ({len(out.splitlines())} lines)')
