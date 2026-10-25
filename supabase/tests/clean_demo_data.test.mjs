// supabase/checks/clean_demo_data.sql, run against a fully seeded database.
//
// This script deletes a factory's data on purpose. Nobody gets to rehearse it
// on the real one, so it is rehearsed here: seed everything, put a month of
// payroll on top so the pay tables are not trivially empty, run the script, and
// prove that what should be gone is gone and that what the factory needs in
// order to keep working is still there.
import { build, asUser } from './harness.mjs';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  if (e && e.detail) console.error(`  detail: ${e.detail}`);
  process.exit(1);
});

const CHECKS = fileURLToPath(new URL('../checks/', import.meta.url));

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

const db = await build({ quiet: true });
const count = async (t) =>
  Number((await db.query(`select count(*) as n from public.${t}`)).rows[0].n);
const one = async (s, p = []) => (await db.query(s, p)).rows[0];

// -----------------------------------------------------------------------------
// A month of pay, so the payroll deletes have something to delete.
//
// The seeds stop at production and dispatch; payroll is made in the app. Run it
// here the way the app does - through the RPCs, as the administrator - rather
// than inserting rows, so the data has the shape the script will meet.
// -----------------------------------------------------------------------------
const ADMIN_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1,'admin@dp.local')`,
  [ADMIN_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-001'`,
  [ADMIN_AUTH]);

const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const MONTH = '2026-06-01';

await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.set_salary_structure($1,$2,$3)`,
    [RAVI, 26000, '2026-01-01']);
  for (const d of ['2026-06-01', '2026-06-02', '2026-06-03']) {
    await db.query(`select public.set_attendance($1,$2,'PRESENT')`, [RAVI, d]);
  }
  await db.query(`select public.issue_salary_advance($1,$2,$3,$4)`,
    [RAVI, 5000, randomUUID(), '2026-06-05']);
  // A deduction, not a bonus: since the payroll was simplified, nothing adds
  // to a monthly salary (DP005).
  await db.query(`select public.add_staff_adjustment($1,$2,'DEDUCTION','Canteen',$3,$4)`,
    [RAVI, MONTH, 300, randomUUID()]);
  await db.query(`select public.run_payroll($1)`, [MONTH]);
  await db.query(`select public.finalise_payroll($1)`, [MONTH]);
  const slip = await one(
    `select s.id from payslips s
       join payroll_periods p on p.id = s.payroll_period_id
      where s.profile_id = $1 and p.period_month = $2`, [RAVI, MONTH]);
  await db.query(`select public.record_salary_payment($1,$2,$3,$4)`,
    [slip.id, 1000, randomUUID(), '2026-07-01']);
});

// Somebody has read a notification. The reads go with the notifications.
await db.query(`
  insert into public.notification_reads (notification_id, profile_id)
  select n.id, p.id
  from public.notifications n, public.profiles p
  where p.employee_code = 'EMP-001'
  limit 1`);

// =============================================================================
section('Before: the seeded database has plenty to lose');

for (const [label, table] of [
  ['production', 'production_entries'],
  ['material batches', 'mixture_entries'],
  ['dispatch', 'dispatches'],
  ['wastage', 'wastage_entries'],
  ['attendance', 'attendance_days'],
  ['payslips', 'payslips'],
  ['salary payments', 'salary_payments'],
  ['advances', 'advance_transactions'],
  ['adjustments', 'staff_adjustments'],
  ['stock movements', 'raw_material_transactions'],
  ['notification reads', 'notification_reads'],
]) {
  const n = await count(table);
  check(`there is ${label} to remove`, n > 0, `${table} is empty`);
}
check('there are more people than the administrator', await count('profiles') > 1);
check('something is actually in stock',
  Number((await one(
    `select count(*) as n from public.raw_material_stock where quantity > 0`)).n) > 0);

// A person added after go-live: they have a login, so they must survive.
const HIRE_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1,'newhire@dp.local')`,
  [HIRE_AUTH]);
await db.query(`
  insert into public.profiles (id, name, employee_code, role, auth_user_id)
  values (gen_random_uuid(), 'Real Hire', 'EMP-900', 'OPERATOR', $1)`, [HIRE_AUTH]);

const MASTERS = ['machines', 'shifts', 'pipe_types', 'pipe_sizes', 'pipe_products',
  'raw_materials', 'raw_material_categories', 'employee_types', 'app_settings',
  'machine_products', 'raw_material_stock', 'finished_goods_stock',
  'reusable_wastage_stock'];
const mastersBefore = {};
for (const t of MASTERS) mastersBefore[t] = await count(t);

// =============================================================================
section('Run the script');

const sql = readFileSync(`${CHECKS}clean_demo_data.sql`, 'utf8');
// db.query() takes a single statement and the script is a whole transaction,
// so it goes through exec(), which returns one result per statement. The
// verification SELECT at the end is the last of them.
const run = async () => {
  try {
    const results = await db.exec(sql);
    return results[results.length - 1].rows;
  } catch (e) { return { error: e.message }; }
};
const report = await run();
check('the script runs without error', Array.isArray(report), report.error ?? '');

if (Array.isArray(report)) {
  const bad = report.filter((r) => r.ok !== true).map((r) => r.check);
  check('its own verification reports true on every line', bad.length === 0,
    bad.join('; '));
  check('it checks eight things', report.length === 8, `${report.length}`);
}

// =============================================================================
section('After: the records of work are gone');

for (const t of ['production_entries', 'mixture_entries', 'mixture_entry_lines',
  'dispatches', 'dispatch_lines', 'wastage_entries', 'shred_entries',
  'attendance_days', 'payslips', 'payslip_components', 'payroll_periods',
  'salary_payments', 'salary_structures', 'advance_transactions',
  'staff_adjustments', 'staff_advance_balance',
  'raw_material_transactions', 'finished_goods_transactions',
  'reusable_wastage_transactions', 'notifications', 'notification_reads']) {
  const n = await count(t);
  check(`${t} is empty`, n === 0, `${n} left`);
}

// =============================================================================
section('Every balance reads zero');

const zero = async (label, q) => {
  const n = Number((await one(q)).n);
  check(label, n === 0, `${n} rows`);
};

await zero('no raw material holds stock',
  `select count(*) as n from public.raw_material_stock where quantity <> 0`);
await zero('no finished goods in bundles or bags',
  `select count(*) as n from public.finished_goods_stock
   where quantity_bundles <> 0 or quantity_bags <> 0`);
await zero('no recycled stock',
  `select count(*) as n from public.reusable_wastage_stock where quantity <> 0`);
await zero('the ledgers still agree with the balances',
  `select count(*) as n from public.v_stock_reconciliation where not ok`);

// =============================================================================
section('The master data is untouched');

for (const t of MASTERS) {
  const now = await count(t);
  check(`${t} kept all ${mastersBefore[t]}`, now === mastersBefore[t], `${now} now`);
}
check('products still carry their bundle weight and bag packing',
  Number((await one(`select count(*) as n from public.pipe_products
     where bundle_weight_kg > 0 and pipes_per_bag is not null`)).n) > 0);
check('reorder levels survive, so the low-stock alerts still mean something',
  Number((await one(`select count(*) as n from public.raw_materials
     where minimum_stock > 0`)).n) > 0
  && Number((await one(`select count(*) as n from public.finished_goods_stock
     where minimum_stock > 0`)).n) > 0);

// =============================================================================
section('People');

const people = (await db.query(
  `select employee_code, role from public.profiles order by employee_code`)).rows;
const codes = people.map((p) => p.employee_code).join(', ');
check('the administrator remains',
  people.some((p) => p.employee_code === 'EMP-001' && p.role === 'ADMIN'), codes);
check('somebody hired for real, with a login, is not swept away',
  people.some((p) => p.employee_code === 'EMP-900'), codes);
check('the sample operators are gone',
  !people.some((p) => p.employee_code.startsWith('EMP-1')
                   || p.employee_code.startsWith('EMP-2')), codes);
check('their machine assignments went with them',
  await count('machine_assignments') === 0);

// =============================================================================
section('Running it twice changes nothing more');

const twice = await run();
check('a second run is harmless', Array.isArray(twice), twice.error ?? '');
if (Array.isArray(twice)) {
  check('and still reports true on every line',
    twice.every((r) => r.ok === true),
    twice.filter((r) => r.ok !== true).map((r) => r.check).join('; '));
}
check('the administrator is still there',
  Number((await one(
    `select count(*) as n from public.profiles where role='ADMIN'`)).n) === 1);
check('and the machines are still there',
  await count('machines') === mastersBefore.machines);

// =============================================================================
section('The factory can start working the moment somebody is added');

// This is the point of keeping the masters: a delivery, a charge and a bundle
// recorded on an empty system, with no further setup.
const machine = (await one(`select id from public.machines order by code limit 1`)).id;
const shift = (await one(
  `select id from public.shifts where active order by name limit 1`)).id;
const material = (await one(
  `select id from public.raw_materials where code = 'RM-RAIZIN'`)).id;
const product = await one(`select pipe_type_id, pipe_size_id from public.pipe_products
  where pipes_per_bag is not null order by sku limit 1`);

const started = await asUser(db, ADMIN_AUTH, async () => {
  try {
    await db.query(`select public.add_raw_material_stock($1,$2,$3)`,
      [material, 500, randomUUID()]);
    const batch = (await one(
      `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
      [machine, shift,
        JSON.stringify([{ raw_material_id: material, quantity: 25 }]),
        randomUUID()])).j.id;
    // Named arguments: record_production has grown to fifteen parameters and
    // counting positions is how a test ends up asserting about the wrong one.
    await db.query(`select public.record_production(
        p_machine_id => $1, p_shift_id => $2,
        p_pipe_type_id => $3, p_pipe_size_id => $4,
        p_bundle_quantity => 4, p_client_ref => $5,
        p_mixture_entry_id => $6)`,
      [machine, shift, product.pipe_type_id, product.pipe_size_id,
        randomUUID(), batch]);
    return null;
  } catch (e) { return e.message; }
});
check('production can be recorded on the clean system', started === null, started ?? '');
check('and it shows up in stock',
  Number((await one(`select count(*) as n from public.finished_goods_stock
     where quantity_bundles > 0`)).n) > 0);
await zero('with the ledgers still agreeing',
  `select count(*) as n from public.v_stock_reconciliation where not ok`);

console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
