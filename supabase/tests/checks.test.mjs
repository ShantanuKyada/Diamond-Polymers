// The pre-flight and verify scripts in supabase/checks/, run against a database
// that looks like the live one: migrated to 0014, with history on it, including
// an Afternoon shift.
//
// These scripts are what somebody pastes into the SQL editor during a migration
// window. If one of them has a typo, they find out at the worst possible
// moment — so they are exercised here first.
import { build, applyMigration } from './harness.mjs';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const CHECKS = join(fileURLToPath(new URL('.', import.meta.url)), '..', 'checks');

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

const sql = (name) => readFileSync(join(CHECKS, name), 'utf8');
const rows = async (db, name) => (await db.query(sql(name))).rows;

// A database at 0014 with real history, the way a live project looks today.
const db = await build({ quiet: true, upto: '0014_payroll_views_rls.sql' });
await db.exec(`
  insert into profiles (id, name, employee_code, role) values
    ('aaaaaaaa-0000-4000-8000-000000000001','Admin','A-1','ADMIN'),
    ('aaaaaaaa-0000-4000-8000-000000000002','Op','O-1','OPERATOR');
  insert into machines (id, code, name) values
    ('bbbbbbbb-0000-4000-8000-000000000001','X1','Line 1');
  insert into shifts (id, name, start_time, end_time) values
    ('22222222-2222-4222-8222-000000000001','Morning','06:00','14:00'),
    ('22222222-2222-4222-8222-000000000002','Afternoon','14:00','22:00'),
    ('22222222-2222-4222-8222-000000000003','Night','22:00','06:00');
  insert into pipe_types (id, code, name) values
    ('cccccccc-0000-4000-8000-000000000001','T','Type T');
  insert into pipe_sizes (id, code, name) values
    ('dddddddd-0000-4000-8000-000000000001','Z','Size Z');
  insert into pipe_products (pipe_type_id, pipe_size_id, sku, bundle_weight_kg)
    values ('cccccccc-0000-4000-8000-000000000001',
            'dddddddd-0000-4000-8000-000000000001','T-Z', 20);
  insert into machine_assignments (machine_id, operator_id, shift_id) values
    ('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',
     '22222222-2222-4222-8222-000000000002');
  insert into production_entries
    (machine_id, operator_id, shift_id, pipe_type_id, pipe_size_id,
     bundle_quantity, client_ref)
  values ('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',
          '22222222-2222-4222-8222-000000000002','cccccccc-0000-4000-8000-000000000001',
          'dddddddd-0000-4000-8000-000000000001', 9, gen_random_uuid());
`);

// =============================================================================
section('Pre-flight, on a database that has not been migrated yet');

const before = await rows(db, '0015_preflight.sql');
const find = (list, n) => list.find((r) => r.check.startsWith(`${n}.`));

check('the script runs at all', before.length === 7, `${before.length} rows`);
check('sees 0001-0011 applied', find(before, 1)?.ok === true);
check('sees payroll applied', find(before, 2)?.ok === true);
check('says 0015 is not applied yet', find(before, 3)?.ok === true,
  find(before, 3)?.detail);
check('names the shift that will be retired',
  /Afternoon/.test(find(before, 4)?.detail ?? ''), find(before, 4)?.detail);
check('counts the history kept on it',
  /^1 production entries/.test(find(before, 5)?.detail ?? ''), find(before, 5)?.detail);
check('counts the assignment that will need a new shift',
  /^1 assignment/.test(find(before, 6)?.detail ?? ''), find(before, 6)?.detail);
check('confirms the ledgers reconcile first', find(before, 7)?.ok === true);

// =============================================================================
section('Apply 0015, then verify');

await applyMigration(db, '0015_packaging_shifts_access.sql');
const after = await rows(db, '0015_verify.sql');

check('the verify script runs at all', after.length === 12, `${after.length} rows`);
for (const row of after) {
  check(row.check, row.ok === true, row.detail);
}

check('the shift times were moved to cover the day',
  /Morning 06:00:00-18:00:00/.test(find(after, 8)?.detail ?? ''), find(after, 8)?.detail);
check('the stranded assignment was reported',
  /need attention/.test(find(after, 12)?.detail ?? ''), find(after, 12)?.detail);

// =============================================================================
section('Pre-flight run a second time now says so');

const again = await rows(db, '0015_preflight.sql');
check('it reports 0015 as already applied',
  again.find((r) => r.check.startsWith('3.'))?.ok === false
  && /ALREADY APPLIED/.test(again.find((r) => r.check.startsWith('3.'))?.detail ?? ''),
  again.find((r) => r.check.startsWith('3.'))?.detail);

// =============================================================================
section('Applying 0015 twice is harmless');

const twice = await (async () => {
  try { await applyMigration(db, '0015_packaging_shifts_access.sql'); return null; }
  catch (e) { return e.message; }
})();
check('a re-run does not fail', twice === null, twice ?? '');

const afterTwice = await rows(db, '0015_verify.sql');
check('and everything still verifies',
  afterTwice.every((r) => r.ok === true),
  afterTwice.filter((r) => !r.ok).map((r) => r.check).join(', '));

console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
