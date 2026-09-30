// The scripts that run in the migration window.
//
// `supabase/checks/*.sql` are pasted into the Supabase SQL editor by hand, at
// the one moment when a typo is most expensive and least welcome. Nothing else
// executes them, so this does: against a database at the migration before, and
// again at the migration after.
//
// The preflight has to survive being run twice — somebody will re-run it to
// confirm — and Postgres parses a whole statement before running any of it, so
// a check that names a column the migration dropped fails the entire script
// rather than reporting "already applied".
import { build, applyMigration } from './harness.mjs';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  process.exit(1);
});

const CHECKS = fileURLToPath(new URL('../checks/', import.meta.url));
const read = (name) => readFileSync(`${CHECKS}${name}`, 'utf8');

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

async function run(db, file) {
  try {
    return (await db.query(read(file))).rows;
  } catch (e) {
    return { error: e.message };
  }
}

// =============================================================================
section('0019 preflight, on a database at 0018');

const before = await build({ quiet: true, upto: '0018_production_batch_link.sql' });
const pre = await run(before, '0019_preflight.sql');

check('the preflight runs at all', Array.isArray(pre), pre.error ?? '');

if (Array.isArray(pre)) {
  check('it says 0019 has not been applied',
    pre.find((r) => r.check.startsWith('03'))?.ok === true);

  // The two that decide whether the migration is safe to run.
  check('it clears an empty payroll to proceed',
    pre.filter((r) => r.ok === false).length === 0,
    JSON.stringify(pre.filter((r) => r.ok === false).map((r) => r.check)));
}

// A database that has actually paid somebody must be stopped, because 0019
// drops the columns holding the figures that were paid.
//
// build({ upto }) skips the seed, so the person has to be created here.
await before.query(`
  insert into public.profiles (name, employee_code, role)
  values ('Ravi Kumar', 'EMP-101', 'OPERATOR')`);
await before.query(`
  insert into public.salary_structures (profile_id, effective_from, monthly_salary)
  select id, '2026-01-01', 21000 from public.profiles where employee_code = 'EMP-101'`);
await before.query(`
  insert into public.payroll_periods (period_month, status) values ('2026-06-01', 'DRAFT')`);
await before.query(`
  insert into public.payslips
    (payroll_period_id, profile_id, monthly_salary, calendar_days, payable_days,
     basic_amount, gross_amount, net_payable)
  select pp.id, p.id, 21000, 30, 30, 21000, 21000, 21000
  from public.payroll_periods pp, public.profiles p
  where pp.period_month = '2026-06-01' and p.employee_code = 'EMP-101'`);

const preWithHistory = await run(before, '0019_preflight.sql');
check('it refuses a database that has already paid somebody',
  Array.isArray(preWithHistory) &&
  preWithHistory.find((r) => r.check.startsWith('04'))?.ok === false,
  JSON.stringify(preWithHistory.find?.((r) => r.check.startsWith('04'))));

// =============================================================================
section('0019 preflight, run again after the migration');

// The history above would now be destroyed, which is exactly what the preflight
// is for. Start again from a clean 0018 to test the re-run.
const rerun = await build({ quiet: true, upto: '0018_production_batch_link.sql' });
await applyMigration(rerun, '0019_simple_payroll.sql');
const pre2 = await run(rerun, '0019_preflight.sql');

check('it still runs once the columns it mentions are gone',
  Array.isArray(pre2), pre2.error ?? '');
if (Array.isArray(pre2)) {
  check('and reports that 0019 is already applied',
    pre2.find((r) => r.check.startsWith('03'))?.ok === false,
    JSON.stringify(pre2.find((r) => r.check.startsWith('03'))));
}

// =============================================================================
section('0019 verify, on a fully migrated database');

const after = await build({ quiet: true });
const ver = await run(after, '0019_verify.sql');

check('the verify script runs at all', Array.isArray(ver), ver.error ?? '');

if (Array.isArray(ver)) {
  for (const row of ver) {
    check(row.check, row.ok === true, row.detail ?? '');
  }
}

console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach((f) => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
