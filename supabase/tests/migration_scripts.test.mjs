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
import { build, applyMigration, asUser } from './harness.mjs';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  process.exit(1);
});

const CHECKS = fileURLToPath(new URL('../checks/', import.meta.url));
const read = (name) => readFileSync(`${CHECKS}${name}`, 'utf8');

// The one-off scripts in ../scripts/ are not checks: they write. They are run
// by hand too, at the same keyboard and with the same lack of an undo, so they
// are tested the same way.
const SCRIPTS = fileURLToPath(new URL('../scripts/', import.meta.url));
const readScript = (name) => readFileSync(`${SCRIPTS}${name}`, 'utf8');

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
section('0019 verify, on a database at 0019');

const after = await build({ quiet: true, upto: '0019_simple_payroll.sql' });
const ver = await run(after, '0019_verify.sql');

check('the verify script runs at all', Array.isArray(ver), ver.error ?? '');

if (Array.isArray(ver)) {
  for (const row of ver) {
    check(row.check, row.ok === true, row.detail ?? '');
  }
}

// =============================================================================
section('0020 preflight, on a database at 0019');

const at19 = await build({ quiet: true, upto: '0019_simple_payroll.sql' });
const pre20 = await run(at19, '0020_preflight.sql');

check('the 0020 preflight runs at all', Array.isArray(pre20), pre20.error ?? '');
if (Array.isArray(pre20)) {
  check('it confirms 0019 is in place and 0020 is not',
    pre20.find((r) => r.check.startsWith('01'))?.ok === true &&
    pre20.find((r) => r.check.startsWith('02'))?.ok === true,
    JSON.stringify(pre20.filter((r) => r.ok === false).map((r) => r.check)));
}

await applyMigration(at19, '0020_worker_profiles_and_salary_payments.sql');
const pre20Again = await run(at19, '0020_preflight.sql');
check('and still runs once 0020 has been applied',
  Array.isArray(pre20Again) &&
  pre20Again.find((r) => r.check.startsWith('02'))?.ok === false,
  pre20Again.error ?? JSON.stringify(pre20Again.find?.((r) => r.check.startsWith('02'))));

// =============================================================================
section('0020 verify, on a database at 0020');

const after20 = await build({
  quiet: true,
  upto: '0020_worker_profiles_and_salary_payments.sql',
});
const ver20 = await run(after20, '0020_verify.sql');

check('the 0020 verify script runs at all', Array.isArray(ver20), ver20.error ?? '');
if (Array.isArray(ver20)) {
  for (const row of ver20) {
    check(row.check, row.ok === true, row.detail ?? '');
  }
}

// =============================================================================
section('0021 preflight, on a database at 0020');

const at20 = await build({
  quiet: true,
  upto: '0020_worker_profiles_and_salary_payments.sql',
});
const pre21 = await run(at20, '0021_preflight.sql');

check('the 0021 preflight runs at all', Array.isArray(pre21), pre21.error ?? '');
if (Array.isArray(pre21)) {
  check('it confirms 0020 is in place and 0021 is not',
    pre21.find((r) => r.check.startsWith('01'))?.ok === true &&
    pre21.find((r) => r.check.startsWith('02'))?.ok === true,
    JSON.stringify(pre21.filter((r) => r.ok === false).map((r) => r.check)));
}

await applyMigration(at20, '0021_employee_types_and_any_machine.sql');
const pre21Again = await run(at20, '0021_preflight.sql');
check('and still runs once 0021 has been applied',
  Array.isArray(pre21Again) &&
  pre21Again.find((r) => r.check.startsWith('02'))?.ok === false,
  pre21Again.error ?? 'did not report it as applied');

// =============================================================================
section('0021 verify, on a database at 0021');

const after21 = await build({
  quiet: true,
  upto: '0021_employee_types_and_any_machine.sql',
});
const ver21 = await run(after21, '0021_verify.sql');

check('the 0021 verify script runs at all', Array.isArray(ver21), ver21.error ?? '');
if (Array.isArray(ver21)) {
  for (const row of ver21) {
    check(row.check, row.ok === true, row.detail ?? '');
  }
}

// =============================================================================
section('0022 preflight, on a database at 0021');

const at21 = await build({
  quiet: true,
  upto: '0021_employee_types_and_any_machine.sql',
});
const pre22 = await run(at21, '0022_preflight.sql');

check('the 0022 preflight runs at all', Array.isArray(pre22), pre22.error ?? '');
if (Array.isArray(pre22)) {
  check('it confirms 0021 is in place and 0022 is not',
    pre22.find((r) => r.check.startsWith('01'))?.ok === true &&
    pre22.find((r) => r.check.startsWith('02'))?.ok === true,
    JSON.stringify(pre22.filter((r) => r.ok === false).map((r) => r.check)));

  check('and that every role in use is one it knows how to carry across',
    pre22.find((r) => r.check.startsWith('04'))?.ok === true,
    JSON.stringify(pre22.find((r) => r.check.startsWith('04'))));
}

await applyMigration(at21, '0022_employee_roles_master.sql');
const pre22Again = await run(at21, '0022_preflight.sql');
check('and still runs once 0022 has been applied',
  Array.isArray(pre22Again) &&
  pre22Again.find((r) => r.check.startsWith('02'))?.ok === false,
  pre22Again.error ?? 'did not report it as applied');

// =============================================================================
section('0022 verify, on a database at 0022');

const after22 = await build({ quiet: true });
const ver22 = await run(after22, '0022_verify.sql');

check('the 0022 verify script runs at all', Array.isArray(ver22), ver22.error ?? '');
if (Array.isArray(ver22)) {
  for (const row of ver22) {
    check(row.check, row.ok === true, row.detail ?? '');
  }
}

// =============================================================================
section('go-live: clearing the demonstration factory');

// The scripts that empty the seeded demo so the real factory starts on a blank
// floor. They run once, by hand, against the live database, with no undo — so
// the delete order has to be right the first time. Several of these foreign
// keys are ON DELETE RESTRICT, which Postgres checks row by row rather than at
// the end of the statement, and a child emptied after its parent fails the run.
const glDb = await build({ quiet: true });

// Production's shape: two people who sign in, and a demonstration operator who
// was given a login along the way. The preflight exists to notice that third
// one before it is deleted.
await glDb.exec(`
  insert into auth.users (id, email) values
    ('77777777-7777-4777-8777-000000000001','admin@dp.local'),
    ('77777777-7777-4777-8777-000000000002','shantanu@dp.local'),
    ('77777777-7777-4777-8777-000000000003','demo-operator@dp.local');
  update public.profiles set auth_user_id='77777777-7777-4777-8777-000000000001'
    where employee_code = 'EMP-001';
  update public.profiles set auth_user_id='77777777-7777-4777-8777-000000000002'
    where employee_code = 'EMP-101';
  update public.profiles set auth_user_id='77777777-7777-4777-8777-000000000003'
    where employee_code = 'EMP-102';
  -- Settings and roles record who last touched them, and those references point
  -- at a profile that is about to go. Left alone they block the delete.
  update public.app_settings
    set updated_by = (select id from public.profiles where employee_code = 'EMP-102')
    where key = 'factory_name';
  update public.employee_types
    set created_by = (select id from public.profiles where employee_code = 'EMP-102')
    where code = 'LABOURER';
`);

// A seeded demonstration is not the shape of a live database, and the gaps sit
// exactly where a delete order goes wrong. The seed never links a shred to the
// bundle it destroyed, never links production to the batch it came out of, and
// carries no payroll at all — three ON DELETE RESTRICT links and nine tables
// that the clearing script would otherwise be proved against while empty.
// Postgres checks RESTRICT row by row rather than at the end of the statement,
// so an empty child hides a wrong order completely.
const GL_ADMIN = '77777777-7777-4777-8777-000000000001';
const glShantanu = (await glDb.query(
  `select id from public.profiles where employee_code = 'EMP-101'`)).rows[0].id;
const glShift = (await glDb.query(
  `select id from public.shifts order by start_time limit 1`)).rows[0].id;

// A37: production belongs to the batch it came out of, and a shred names the
// bundle it destroyed. Each restricts its parent.
await glDb.exec(`
  update public.production_entries p
  set mixture_entry_id = (select m.id from public.mixture_entries m
                          where m.machine_id = p.machine_id
                          order by m.id limit 1)
  where exists (select 1 from public.mixture_entries m
                where m.machine_id = p.machine_id);

  update public.shred_entries
  set production_entry_id = (select id from public.production_entries
                             order by id limit 1)
  where id = (select id from public.shred_entries order by id limit 1);
`);

// A month of payroll, run the way the office runs it: a salary, a day marked,
// an advance taken mid-month, a deduction, the run, the lock, a part payment
// and a payment reversed. That fills every payroll table the clearing script
// empties, and puts a payment in front of the payslip that restricts it.
await asUser(glDb, GL_ADMIN, async () => {
  await glDb.query(`select public.set_salary_structure($1, 20000, '2026-06-01')`,
    [glShantanu]);
  await glDb.query(`select public.set_attendance(
      p_profile_id => $1, p_work_date => '2026-06-02',
      p_status => 'PRESENT', p_shift_id => $2)`, [glShantanu, glShift]);
  await glDb.query(`select public.issue_salary_advance($1, 3000, $2, '2026-06-10')`,
    [glShantanu, randomUUID()]);
  await glDb.query(`select public.add_staff_adjustment(
      $1, '2026-06-01', 'DEDUCTION', 'Uniform', 250, $2)`,
    [glShantanu, randomUUID()]);
  await glDb.query(`select public.run_payroll('2026-06-01')`);
  await glDb.query(`select public.finalise_payroll('2026-06-01')`);

  const slip = (await glDb.query(`select id from public.payslips limit 1`)).rows[0].id;
  const paid = (await glDb.query(
    `select public.record_salary_payment($1, 5000, $2, '2026-07-01') as j`,
    [slip, randomUUID()])).rows[0].j;
  await glDb.query(`select public.reverse_salary_payment($1, $2)`,
    [paid.id, randomUUID()]);
});

const glShape = (await glDb.query(`select
  (select count(*) from public.payslips) as slips,
  (select count(*) from public.payslip_components) as components,
  (select count(*) from public.salary_payments) as payments,
  (select count(*) from public.staff_adjustments) as adjustments,
  (select count(*) from public.advance_transactions) as advances,
  (select count(*) from public.attendance_days) as attendance,
  (select count(*) from public.shred_entries
   where production_entry_id is not null) as linked_shreds,
  (select count(*) from public.production_entries
   where mixture_entry_id is not null) as batched`)).rows[0];

check('the demonstration data was brought up to a live shape first',
  glShape.slips > 0 && glShape.components > 0 && glShape.payments === 2 &&
  glShape.adjustments > 0 && glShape.advances > 0 && glShape.attendance > 0 &&
  glShape.linked_shreds > 0 && glShape.batched > 0,
  JSON.stringify(glShape));

const glPre = await run(glDb, 'go_live_preflight.sql');
check('the go-live preflight runs at all', Array.isArray(glPre), glPre.error ?? '');

if (Array.isArray(glPre)) {
  check('it finds both people who sign in',
    glPre.find((r) => r.check.startsWith('01'))?.ok === true &&
    glPre.find((r) => r.check.startsWith('02'))?.ok === true,
    JSON.stringify(glPre.filter((r) => r.ok === false).map((r) => r.check)));

  // The row that earns the preflight its place: somebody who is not on the keep
  // list has a login, and would lose it without a word.
  check('it refuses to pass somebody else holding a login',
    glPre.find((r) => r.check.startsWith('03'))?.ok === false &&
    /EMP-102/.test(glPre.find((r) => r.check.startsWith('03'))?.detail ?? ''),
    JSON.stringify(glPre.find((r) => r.check.startsWith('03'))));

  check('it names everyone the clearing script will remove',
    /EMP-102.*EMP-103.*EMP-104/.test(
      glPre.find((r) => r.check.startsWith('04'))?.detail ?? ''),
    glPre.find((r) => r.check.startsWith('04'))?.detail ?? '');

  check('it counts the demonstration catalogue rather than guessing',
    /machines: 4/.test(glPre.find((r) => r.check.startsWith('07'))?.detail ?? ''),
    glPre.find((r) => r.check.startsWith('07'))?.detail ?? '');
}

// Unlink that third login, the way an administrator would after reading row 03,
// and the preflight should clear.
await glDb.exec(`update public.profiles set auth_user_id = null
                 where employee_code = 'EMP-102'`);
const glPreAgain = await run(glDb, 'go_live_preflight.sql');
check('and clears once nobody else holds one',
  Array.isArray(glPreAgain) &&
  glPreAgain.find((r) => r.check.startsWith('03'))?.ok === true,
  JSON.stringify(glPreAgain.error ?? glPreAgain.find((r) => r.check.startsWith('03'))));

// -----------------------------------------------------------------------------
let glWipeError = null;
try {
  await glDb.exec(readScript('go_live_clear_demo_data.sql'));
} catch (e) {
  glWipeError = e.message;
}
check('the clearing script runs without tripping a foreign key',
  glWipeError === null, glWipeError ?? '');

const glVer = await run(glDb, 'go_live_verify.sql');
check('the go-live verify runs at all', Array.isArray(glVer), glVer.error ?? '');
if (Array.isArray(glVer)) {
  for (const row of glVer) check(row.check, row.ok === true, row.detail ?? '');

  // Row 09 reports rather than judges: the demonstration operator's Supabase
  // login outlives the employee record, and the script says so instead of
  // reaching into auth.users itself.
  check('it reports the login left behind in auth',
    /demo-operator@dp.local/.test(
      glVer.find((r) => r.check.startsWith('09'))?.detail ?? ''),
    glVer.find((r) => r.check.startsWith('09'))?.detail ?? '');
}

// Somebody will run it twice to be sure. That must be harmless.
let glSecondError = null;
try {
  await glDb.exec(readScript('go_live_clear_demo_data.sql'));
} catch (e) {
  glSecondError = e.message;
}
check('running it a second time changes nothing and raises nothing',
  glSecondError === null, glSecondError ?? '');

// Nothing overlooked: every table outside the keep list is empty, including any
// table a later migration adds that nobody remembered to list.
const GL_KEPT = new Set(['app_settings', 'employee_types', 'shifts',
                      'raw_material_categories', 'profiles']);
const glTables = (await glDb.query(`select table_name from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`)).rows;
const glLeftovers = [];
for (const { table_name } of glTables) {
  if (GL_KEPT.has(table_name)) continue;
  const n = (await glDb.query(`select count(*)::int n from public."${table_name}"`)).rows[0].n;
  if (n > 0) glLeftovers.push(`${table_name}: ${n}`);
}
check('no table outside the keep list still holds a row',
  glLeftovers.length === 0, glLeftovers.join(', '));

check('and the keep list kept what it promised',
  (await glDb.query(`select
     (select count(*) from public.profiles) as people,
     (select count(*) from public.app_settings) as settings,
     (select count(*) from public.employee_types) as roles,
     (select count(*) from public.shifts) as shifts,
     (select count(*) from public.raw_material_categories) as cats`))
    .rows[0].people === 2);

console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach((f) => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
