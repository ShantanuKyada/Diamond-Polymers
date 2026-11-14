// 0024: who may consume recycled stock (A45), and when an entry may be dated
// (A46).
//
// Both rules existed before this migration — one in nobody's head, one in a
// date picker. This suite is what makes them real, so it tests the paths a
// browser's network tab can reach, not the ones the app happens to use.
import { build, asUser, chargeBatch } from './harness.mjs';
import { randomUUID } from 'node:crypto';

process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  process.exit(1);
});

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

// The SQLSTATE, or null when the call succeeded.
async function state(fn) {
  try { await fn(); return null; }
  catch (e) { return e.code ?? String(e.message).slice(0, 90); }
}

const db = await build({ quiet: true });
const one = async (s, p = []) => (await db.query(s, p)).rows[0];

const ADMIN_AUTH = randomUUID();
const RAVI_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values
  ($1,'admin@dp.local'), ($2,'ravi@dp.local')`, [ADMIN_AUTH, RAVI_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-001'`,
  [ADMIN_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-101'`,
  [RAVI_AUTH]);

const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const MACHINE = (await one(
  `select machine_id as id from v_current_machine_assignments
    where operator_id = $1`, [RAVI])).id;
const SHIFT = (await one(
  `select shift_id as id from v_current_machine_assignments
    where operator_id = $1`, [RAVI])).id;
const TYPE = (await one(`select pipe_type_id as id from pipe_products limit 1`)).id;
const SIZE = (await one(
  `select pipe_size_id as id from pipe_products
    where pipe_type_id = $1 limit 1`, [TYPE])).id;
const REGRIND = (await one(
  `select raw_material_id as id from reusable_wastage_stock limit 1`)).id;
const RAIZIN = (await one(
  `select id from raw_materials where code = 'RM-RAIZIN'`)).id;

// The factory's today, which is what the rule measures against.
const today = (await one(
  `select (now() at time zone app.setting('factory_timezone','Asia/Kolkata'))::date
          as d`)).d;
const day = (offset) => {
  const d = new Date(today);
  d.setDate(d.getDate() + offset);
  return d.toISOString().slice(0, 10);
};

// =============================================================================
section('A45 — consuming recycled stock is an administrator\'s act');

const opConsume = await state(() => asUser(db, RAVI_AUTH, () =>
  db.query(`select public.consume_reusable_wastage($1,$2,$3)`,
    [REGRIND, 1, randomUUID()])));
check('an operator is refused', opConsume === 'DP004' || opConsume === 'DP003'
  || /admin/i.test(opConsume ?? ''), `got ${opConsume}`);

const beforeRecycled = Number((await one(
  `select quantity as n from reusable_wastage_stock where raw_material_id=$1`,
  [REGRIND])).n);
check('and nothing moved',
  Number((await one(
    `select quantity as n from reusable_wastage_stock where raw_material_id=$1`,
    [REGRIND])).n) === beforeRecycled);

const adminConsume = await state(() => asUser(db, ADMIN_AUTH, () =>
  db.query(`select public.consume_reusable_wastage($1,$2,$3)`,
    [REGRIND, 1, randomUUID()])));
check('an administrator is not', adminConsume === null, `${adminConsume}`);
check('and the balance went down by what was consumed',
  Number((await one(
    `select quantity as n from reusable_wastage_stock where raw_material_id=$1`,
    [REGRIND])).n) === beforeRecycled - 1);

// =============================================================================
section('A46 — an entry cannot be dated in the future');

for (const [label, table, cols, vals] of [
  ['production', 'production_entries',
    '(machine_id, operator_id, shift_id, pipe_type_id, pipe_size_id, bundle_quantity, client_ref, entry_date)',
    [MACHINE, RAVI, SHIFT, TYPE, SIZE, 1, randomUUID(), day(1)]],
]) {
  const err = await state(() => db.query(
    `insert into public.${table} ${cols} values ($1,$2,$3,$4,$5,$6,$7,$8)`, vals));
  check(`a ${label} row dated tomorrow is refused`, err === 'DP005', `${err}`);
}

const futureProd = await state(() => asUser(db, ADMIN_AUTH, async () => {
  const batch = await chargeBatch(db, {
    machineId: MACHINE, shiftId: SHIFT, materialId: RAIZIN });
  await db.query(`select public.record_production(
      p_machine_id => $1, p_shift_id => $2, p_pipe_type_id => $3,
      p_pipe_size_id => $4, p_bundle_quantity => 1, p_client_ref => $5,
      p_entry_date => $6, p_mixture_entry_id => $7)`,
    [MACHINE, SHIFT, TYPE, SIZE, randomUUID(), day(1), batch]);
}));
check('and so is the RPC an administrator would call', futureProd === 'DP005',
  `${futureProd}`);

const futureDispatch = await state(() => asUser(db, ADMIN_AUTH, () =>
  db.query(`select public.create_dispatch(
      p_customer_name => $1, p_lines => $2::jsonb, p_client_ref => $3,
      p_dispatch_date => $4)`,
    ['Someone', JSON.stringify([{ pipe_type_id: TYPE, pipe_size_id: SIZE,
      bundle_quantity: 1 }]), randomUUID(), day(1)])));
check('a dispatch dated tomorrow is refused too', futureDispatch === 'DP005',
  `${futureDispatch}`);

// =============================================================================
section('A46 — nor further back than the factory allows');

const old = await state(() => asUser(db, ADMIN_AUTH, async () => {
  const batch = await chargeBatch(db, {
    machineId: MACHINE, shiftId: SHIFT, materialId: RAIZIN });
  await db.query(`select public.record_production(
      p_machine_id => $1, p_shift_id => $2, p_pipe_type_id => $3,
      p_pipe_size_id => $4, p_bundle_quantity => 1, p_client_ref => $5,
      p_entry_date => $6, p_mixture_entry_id => $7)`,
    [MACHINE, SHIFT, TYPE, SIZE, randomUUID(), day(-31), batch]);
}));
check('31 days back is refused at the default of 30', old === 'DP005', `${old}`);

const withinWindow = await state(() => asUser(db, ADMIN_AUTH, async () => {
  const batch = await chargeBatch(db, {
    machineId: MACHINE, shiftId: SHIFT, materialId: RAIZIN });
  await db.query(`select public.record_production(
      p_machine_id => $1, p_shift_id => $2, p_pipe_type_id => $3,
      p_pipe_size_id => $4, p_bundle_quantity => 1, p_client_ref => $5,
      p_entry_date => $6, p_mixture_entry_id => $7)`,
    [MACHINE, SHIFT, TYPE, SIZE, randomUUID(), day(-29), batch]);
}));
check('29 days back goes through', withinWindow === null, `${withinWindow}`);

// =============================================================================
section('A46 — the window is the factory\'s to set');

await db.query(
  `update app_settings set value = '0' where key = 'entry_backdating_days'`);

const yesterdayNow = await state(() => asUser(db, ADMIN_AUTH, async () => {
  const batch = await chargeBatch(db, {
    machineId: MACHINE, shiftId: SHIFT, materialId: RAIZIN });
  await db.query(`select public.record_production(
      p_machine_id => $1, p_shift_id => $2, p_pipe_type_id => $3,
      p_pipe_size_id => $4, p_bundle_quantity => 1, p_client_ref => $5,
      p_entry_date => $6, p_mixture_entry_id => $7)`,
    [MACHINE, SHIFT, TYPE, SIZE, randomUUID(), day(-1), batch]);
}));
check('set to 0, yesterday is refused', yesterdayNow === 'DP005', `${yesterdayNow}`);

const todayStill = await state(() => asUser(db, ADMIN_AUTH, async () => {
  const batch = await chargeBatch(db, {
    machineId: MACHINE, shiftId: SHIFT, materialId: RAIZIN });
  await db.query(`select public.record_production(
      p_machine_id => $1, p_shift_id => $2, p_pipe_type_id => $3,
      p_pipe_size_id => $4, p_bundle_quantity => 1, p_client_ref => $5,
      p_mixture_entry_id => $6)`,
    [MACHINE, SHIFT, TYPE, SIZE, randomUUID(), batch]);
}));
check('but today still works', todayStill === null, `${todayStill}`);

await db.query(
  `update app_settings set value = '30' where key = 'entry_backdating_days'`);

// =============================================================================
section('A46 — history is not re-judged');

// The rule is on INSERT only. A factory that shortens the window must not find
// that last month's entries have become invalid, or that a report over them
// now fails.
await db.query(
  `update app_settings set value = '1' where key = 'entry_backdating_days'`);
const stillThere = Number((await one(
  `select count(*) as n from production_entries where entry_date < current_date - 1`
)).n);
check('older entries are still readable', stillThere > 0, `${stillThere}`);
check('and the ledgers still reconcile',
  Number((await one(
    `select count(*) as n from v_stock_reconciliation where not ok`)).n) === 0);
await db.query(
  `update app_settings set value = '30' where key = 'entry_backdating_days'`);

console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
