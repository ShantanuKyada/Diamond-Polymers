// The whole migration window, start to finish.
//
// The live project is at 0014. Going live means applying nine migrations in one
// sitting, to a database that already has a factory's history on it, and then
// handing the app to people who will immediately record a bundle.
//
// Every other suite proves one step. This proves the sequence: 0015 through
// 0023 applied in order, each one's pre-flight and verify script run at the
// moment somebody would actually run it, with the history intact at the end and
// the app's real write path working on top of it.
//
// If this suite passes, the migration window holds no surprises that the
// scripts cannot see coming.
import { build, applyMigration, asUser } from './harness.mjs';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const CHECKS = fileURLToPath(new URL('../checks/', import.meta.url));

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

const script = async (name) => {
  try { return (await db.query(readFileSync(`${CHECKS}${name}`, 'utf8'))).rows; }
  catch (e) { return { error: e.message }; }
};

// =============================================================================
section('A database that looks like the live one: 0014, with history');

const db = await build({ quiet: true, upto: '0014_payroll_views_rls.sql' });

const ADMIN = 'aaaaaaaa-0000-4000-8000-000000000001';
const OP = 'aaaaaaaa-0000-4000-8000-000000000002';
const MACHINE = 'bbbbbbbb-0000-4000-8000-000000000001';
const MORNING = '22222222-2222-4222-8222-000000000001';
const AFTERNOON = '22222222-2222-4222-8222-000000000002';
const TYPE = 'cccccccc-0000-4000-8000-000000000001';
const SIZE = 'dddddddd-0000-4000-8000-000000000001';
const RAIZIN = 'eeeeeeee-0000-4000-8000-000000000001';
const ADMIN_AUTH = randomUUID();

await db.query(`insert into auth.users (id, email) values ($1,'admin@dp.local')`,
  [ADMIN_AUTH]);

const SEED_0014 = `
  insert into profiles (id, name, employee_code, role, auth_user_id) values
    ('${ADMIN}','Admin','EMP-001','ADMIN','${ADMIN_AUTH}'),
    ('${OP}','Operator','EMP-101','OPERATOR', null);

  insert into machines (id, code, name) values ('${MACHINE}','M1','Line 1');

  -- Three shifts, because that is what a 0014 database has. 0015 retires the
  -- middle one and stretches the other two over the day.
  insert into shifts (id, name, start_time, end_time) values
    ('${MORNING}','Morning','06:00','14:00'),
    ('${AFTERNOON}','Afternoon','14:00','22:00'),
    ('22222222-2222-4222-8222-000000000003','Night','22:00','06:00');

  insert into pipe_types (id, code, name) values ('${TYPE}','BR','Braided');
  insert into pipe_sizes (id, code, name) values ('${SIZE}','HALF','1/2 inch');
  insert into pipe_products (pipe_type_id, pipe_size_id, sku, bundle_weight_kg)
    values ('${TYPE}','${SIZE}','BR-HALF', 20);

  insert into raw_material_categories (code, name) values ('RAIZIN','Raizin');
  insert into raw_materials (id, code, name, category, minimum_stock)
    values ('${RAIZIN}','RM-RAIZIN','Raizin','RAIZIN', 400);
  insert into raw_material_stock (raw_material_id, quantity)
    values ('${RAIZIN}', 0);

  -- The operator works the shift that is about to disappear, which is the one
  -- case the migration has to handle rather than ignore.
  insert into machine_assignments (machine_id, operator_id, shift_id)
    values ('${MACHINE}','${OP}','${AFTERNOON}');
`;

await db.exec(SEED_0014);

// History made through the RPCs, so the ledgers and the balance caches agree
// the way they do on the live project.
await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.add_raw_material_stock($1,$2,$3)`,
    [RAIZIN, 1000, randomUUID()]);
  for (const bundles of [9, 12, 7]) {
    await db.query(`select public.record_production($1,$2,$3,$4,$5,$6,$7)`,
      [MACHINE, AFTERNOON, TYPE, SIZE, bundles, randomUUID(), OP]);
  }
});

const before = {
  production: Number((await db.query(
    `select count(*) as n from production_entries`)).rows[0].n),
  bundles: Number((await db.query(
    `select coalesce(sum(bundle_quantity),0) as n from production_entries`)).rows[0].n),
  stock: Number((await db.query(
    `select quantity as n from raw_material_stock where raw_material_id=$1`,
    [RAIZIN])).rows[0].n),
  finished: Number((await db.query(
    `select coalesce(sum(quantity_bundles),0) as n from finished_goods_stock`)).rows[0].n),
};

check('the database has production on it', before.production === 3);
check('and material movements behind it', before.stock > 0, `${before.stock}`);
check('and finished goods in stock', before.finished === 28, `${before.finished}`);
check('the ledgers reconcile before anything is applied',
  Number((await db.query(
    `select count(*) as n from v_stock_reconciliation where not ok`)).rows[0].n) === 0);

// =============================================================================
section('0015 — bags, two shifts, access');

const pre15 = await script('0015_preflight.sql');
check('the 0015 pre-flight runs', Array.isArray(pre15), pre15.error ?? '');
check('it clears the database to proceed',
  Array.isArray(pre15) && pre15.every((r) => r.ok === true),
  Array.isArray(pre15) ? pre15.filter((r) => !r.ok).map((r) => r.check).join(', ') : '');

await applyMigration(db, '0015_packaging_shifts_access.sql');

const ver15 = await script('0015_verify.sql');
check('the 0015 verify runs', Array.isArray(ver15), ver15.error ?? '');
check('and every line reads true',
  Array.isArray(ver15) && ver15.every((r) => r.ok === true),
  Array.isArray(ver15) ? ver15.filter((r) => !r.ok).map((r) => r.check).join(', ') : '');

check('the factory is down to two shifts',
  Number((await db.query(
    `select count(*) as n from shifts where active`)).rows[0].n) === 2);
check('the production recorded against the retired shift is still there',
  Number((await db.query(
    `select count(*) as n from production_entries`)).rows[0].n) === before.production);

// =============================================================================
section('0016 … 0018 — operator material entry, identity, batch link');

for (const m of ['0016_operator_material_entry.sql',
  '0017_factory_identity.sql',
  '0018_production_batch_link.sql']) {
  const err = await (async () => {
    try { await applyMigration(db, m); return null; } catch (e) { return e.message; }
  })();
  check(`${m.slice(0, 4)} applies`, err === null, err ?? '');
}

// =============================================================================
section('0019 — the simplified payroll');

const pre19 = await script('0019_preflight.sql');
check('the 0019 pre-flight runs', Array.isArray(pre19), pre19.error ?? '');
check('it clears a factory that has never run payroll',
  Array.isArray(pre19) && pre19.filter((r) => r.ok === false).length === 0,
  Array.isArray(pre19) ? pre19.filter((r) => !r.ok).map((r) => r.check).join(', ') : '');

await applyMigration(db, '0019_simple_payroll.sql');

const ver19 = await script('0019_verify.sql');
check('the 0019 verify passes', Array.isArray(ver19) && ver19.every((r) => r.ok === true),
  Array.isArray(ver19) ? ver19.filter((r) => !r.ok).map((r) => r.check).join(', ') : ver19.error);

// =============================================================================
section('0020 … 0024 — profiles, types, roles, a retired setting, entry dates');

for (const [mig, pre, ver] of [
  ['0020_worker_profiles_and_salary_payments.sql', '0020_preflight.sql', '0020_verify.sql'],
  ['0021_employee_types_and_any_machine.sql', '0021_preflight.sql', '0021_verify.sql'],
  ['0022_employee_roles_master.sql', '0022_preflight.sql', '0022_verify.sql'],
  ['0023_retire_unread_setting.sql', null, null],
  ['0024_entry_dates_and_wastage_access.sql', null, null],
]) {
  const tag = mig.slice(0, 4);
  if (pre) {
    const p = await script(pre);
    check(`the ${tag} pre-flight clears the way`,
      Array.isArray(p) && p.filter((r) => r.ok === false).length === 0,
      Array.isArray(p) ? p.filter((r) => !r.ok).map((r) => r.check).join(', ') : p.error);
  }
  const err = await (async () => {
    try { await applyMigration(db, mig); return null; } catch (e) { return e.message; }
  })();
  check(`${tag} applies`, err === null, err ?? '');
  if (ver) {
    const v = await script(ver);
    check(`the ${tag} verify passes`,
      Array.isArray(v) && v.every((r) => r.ok === true),
      Array.isArray(v) ? v.filter((r) => !r.ok).map((r) => r.check).join(', ') : v.error);
  }
}

// =============================================================================
section('Nothing was lost on the way');

check('every production entry survived',
  Number((await db.query(
    `select count(*) as n from production_entries`)).rows[0].n) === before.production);
check('the bundles still add up',
  Number((await db.query(
    `select coalesce(sum(bundle_quantity),0) as n from production_entries`)).rows[0].n)
    === before.bundles);
check('the material balance is unchanged',
  Number((await db.query(
    `select quantity as n from raw_material_stock where raw_material_id=$1`,
    [RAIZIN])).rows[0].n) === before.stock);
check('the finished goods balance is unchanged',
  Number((await db.query(
    `select coalesce(sum(quantity_bundles),0) as n from finished_goods_stock`)).rows[0].n)
    === before.finished);
check('the ledgers still reconcile',
  Number((await db.query(
    `select count(*) as n from v_stock_reconciliation where not ok`)).rows[0].n) === 0);
check('the administrator can still sign in',
  Number((await db.query(
    `select count(*) as n from profiles where role='ADMIN' and auth_user_id is not null`
  )).rows[0].n) === 1);

// What the step-by-step run left behind, read before anything else is written
// to it. The section below records production and a dispatch, so comparing
// against this database afterwards would be comparing against a different
// question.
const AFTER_MIGRATION = [
  ['production entries', 'select count(*) as n from production_entries'],
  ['shifts in use', 'select count(*) as n from shifts where active'],
  ['raw material balance',
    `select quantity as n from raw_material_stock where raw_material_id = '${RAIZIN}'`],
  ['finished bundles',
    'select coalesce(sum(quantity_bundles),0) as n from finished_goods_stock'],
  ['settings', 'select count(*) as n from app_settings'],
  ['ledger mismatches',
    'select count(*) as n from v_stock_reconciliation where not ok'],
];
const stepByStep = {};
for (const [label, q] of AFTER_MIGRATION) {
  stepByStep[label] = Number((await db.query(q)).rows[0].n);
}

// =============================================================================
section('The app works on the migrated database');

// Everything the change request added, exercised end to end on data that was
// recorded before any of it existed.
// A bag is weighed as bundle_weight_kg * pipes_per_bag / pipes_per_bundle
// (A26), so both counts have to be set before bags can be recorded at all.
await db.query(
  `update pipe_products set pipes_per_bundle = 100, pipes_per_bag = 50
    where pipe_type_id = $1 and pipe_size_id = $2`, [TYPE, SIZE]);

const live = await asUser(db, ADMIN_AUTH, async () => {
  try {
    const shift = (await db.query(
      `select id from shifts where active order by name limit 1`)).rows[0].id;

    // A charge, then a run that produces bundles and bags and uses recycled
    // material - the A24/A26/A28 path the live APK will take on day one.
    const batch = (await db.query(
      `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
      [MACHINE, shift,
        JSON.stringify([{ raw_material_id: RAIZIN, quantity: 40 }]),
        randomUUID()])).rows[0].j.id;

    await db.query(`select public.record_production(
        p_machine_id => $1, p_shift_id => $2,
        p_pipe_type_id => $3, p_pipe_size_id => $4,
        p_bundle_quantity => 5, p_bag_quantity => 2,
        p_client_ref => $5, p_mixture_entry_id => $6)`,
      [MACHINE, shift, TYPE, SIZE, randomUUID(), batch]);

    await db.query(`select public.create_dispatch(
        p_customer_name => $1, p_lines => $2::jsonb, p_client_ref => $3,
        p_vehicle_number => $4)`,
      ['Patel Traders',
        JSON.stringify([{
          pipe_type_id: TYPE, pipe_size_id: SIZE,
          bundle_quantity: 2, bag_quantity: 1,
        }]),
        randomUUID(), 'GJ-01-AB-1234']);
    return null;
  } catch (e) { return `${e.code ?? ''} ${e.message}`; }
});
check('a bundle-and-bag production and a dispatch both go through',
  live === null, live ?? '');
check('and the ledgers still reconcile afterwards',
  Number((await db.query(
    `select count(*) as n from v_stock_reconciliation where not ok`)).rows[0].n) === 0);

// The dashboards are what the app opens on. If either throws, nobody gets past
// the first screen.
const dash = await asUser(db, ADMIN_AUTH, async () => {
  try {
    await db.query(`select public.admin_dashboard()`);
    return null;
  } catch (e) { return e.message; }
});
check('the admin dashboard loads', dash === null, dash ?? '');

// =============================================================================
section('The same window, pasted in one go');

// scripts/apply_0015_to_0024.sql is what somebody actually runs: the ten files
// concatenated, because pasting ten of them one after another in a migration
// window is how one of them gets skipped. It has to land a 0014 database in
// exactly the place the ten separate files do, and it has to survive being run
// twice, because somebody will re-run it to be sure.
const SCRIPTS = fileURLToPath(new URL('../scripts/', import.meta.url));
const MIG_DIR = fileURLToPath(new URL('../migrations/', import.meta.url));
const combined = readFileSync(`${SCRIPTS}apply_0015_to_0024.sql`, 'utf8');

const MIGRATIONS = [
  '0015_packaging_shifts_access.sql', '0016_operator_material_entry.sql',
  '0017_factory_identity.sql', '0018_production_batch_link.sql',
  '0019_simple_payroll.sql', '0020_worker_profiles_and_salary_payments.sql',
  '0021_employee_types_and_any_machine.sql', '0022_employee_roles_master.sql',
  '0023_retire_unread_setting.sql', '0024_entry_dates_and_wastage_access.sql',
];

// It is generated, so the first question is whether it is still made of what
// it claims to be made of.
const stale = MIGRATIONS.filter((name) =>
  !combined.includes(readFileSync(`${MIG_DIR}${name}`, 'utf8').trim()));
check('it still holds every migration, unedited', stale.length === 0,
  `stale: ${stale.join(', ')}`);
check('and in order',
  MIGRATIONS.map((n) => combined.indexOf(n))
    .every((at, i, all) => at > 0 && (i === 0 || at > all[i - 1])));

// A second database at 0014, with the same history on it.
const fresh = await build({ quiet: true, upto: '0014_payroll_views_rls.sql' });
await fresh.query(`insert into auth.users (id, email) values ($1,'admin@dp.local')`,
  [ADMIN_AUTH]);
await fresh.exec(SEED_0014);
await asUser(fresh, ADMIN_AUTH, async () => {
  await fresh.query(`select public.add_raw_material_stock($1,$2,$3)`,
    [RAIZIN, 1000, randomUUID()]);
  for (const bundles of [9, 12, 7]) {
    await fresh.query(`select public.record_production($1,$2,$3,$4,$5,$6,$7)`,
      [MACHINE, AFTERNOON, TYPE, SIZE, bundles, randomUUID(), OP]);
  }
});

const pasted = await (async () => {
  try { await fresh.exec(combined); return null; } catch (e) { return e.message; }
})();
check('the whole file applies in one go', pasted === null, pasted ?? '');

const twice = await (async () => {
  try { await fresh.exec(combined); return null; } catch (e) { return e.message; }
})();
check('and a second time, unharmed', twice === null, twice ?? '');

// And leaves the database where the ten separate files left the first one.
for (const [label, q] of AFTER_MIGRATION) {
  const b = Number((await fresh.query(q)).rows[0].n);
  check(`${label}: same as the step-by-step run`, stepByStep[label] === b,
    `${stepByStep[label]} vs ${b}`);
}


console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
