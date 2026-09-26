// Packaging, two shifts, wastage usage and admin-only material entry (0015).
//
// Covers the scenarios the change request asks to be tested — bundles only,
// bags only, both, different types and sizes, wastage used and not used,
// Morning and Night, several operators, admin against operator — plus the path
// a live database takes: yesterday's schema with an Afternoon shift in it,
// upgraded in place.
import { build, asUser, applyMigration } from './harness.mjs';
import { randomUUID } from 'node:crypto';

process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  if (e && e.query) console.error(`  query:  ${String(e.query).slice(0, 200)}`);
  process.exit(1);
});

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

// The SQLSTATE a call fails with, or null if it succeeded.
async function sqlstate(fn) {
  try { await fn(); return null; } catch (e) { return e.code ?? 'UNKNOWN'; }
}
const num = (v) => (v === null || v === undefined ? null : Number(v));

const db = await build({ quiet: true });
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];
const id = async (sql, args = []) => (await one(sql, args)).id;

// --- people ------------------------------------------------------------------
const ADMIN = randomUUID();
const RAVI = randomUUID();      // Machine 1, Morning
const SURESH = randomUUID();    // Machine 2, Morning
const IMRAN = randomUUID();     // Machine 3, Night
await db.query(
  `insert into auth.users (id, email) values
     ($1,'admin@dp.local'),($2,'ravi@dp.local'),($3,'suresh@dp.local'),($4,'imran@dp.local')`,
  [ADMIN, RAVI, SURESH, IMRAN]);
for (const [auth, code] of [[ADMIN, 'EMP-001'], [RAVI, 'EMP-101'], [SURESH, 'EMP-102'], [IMRAN, 'EMP-103']]) {
  await db.query(`update profiles set auth_user_id=$1 where employee_code=$2`, [auth, code]);
}
const RAVI_ID = await id(`select id from profiles where employee_code='EMP-101'`);
const SURESH_ID = await id(`select id from profiles where employee_code='EMP-102'`);

// --- things ------------------------------------------------------------------
const M1 = await id(`select id from machines where code='M1'`);
const M2 = await id(`select id from machines where code='M2'`);
const M3 = await id(`select id from machines where code='M3'`);
const MORNING = await id(`select id from shifts where name='Morning'`);
const NIGHT = await id(`select id from shifts where name='Night'`);
const TA = await id(`select id from pipe_types where code='TA'`);
const TB = await id(`select id from pipe_types where code='TB'`);
const S1 = await id(`select id from pipe_sizes where code='S1'`);
const S2 = await id(`select id from pipe_sizes where code='S2'`);
const S4 = await id(`select id from pipe_sizes where code='S4'`);
const RAIZIN = await id(`select id from raw_materials where code='RM-RAIZIN'`);

const stock = async (type, size) => {
  const r = await one(
    `select quantity_bundles, quantity_bags from finished_goods_stock
     where pipe_type_id=$1 and pipe_size_id=$2`, [type, size]);
  return { bundles: num(r.quantity_bundles), bags: num(r.quantity_bags) };
};

// record_production with the app's argument order.
const produce = (o) => db.query(
  `select public.record_production(
     p_machine_id := $1, p_shift_id := $2, p_pipe_type_id := $3,
     p_pipe_size_id := $4, p_bundle_quantity := $5, p_client_ref := $6,
     p_bag_quantity := $7, p_wastage_used := $8, p_wastage_used_kg := $9) as j`,
  [o.machine, o.shift ?? MORNING, o.type ?? TA, o.size ?? S1, o.bundles ?? 0,
    o.ref ?? randomUUID(), o.bags ?? 0, o.used ?? false, o.usedKg ?? null]);

const dispatch = (o) => db.query(
  `select public.create_dispatch($1, $2::jsonb, $3, current_date, $4, $5, null) as j`,
  [o.buyer ?? 'ABC Industries', JSON.stringify(o.lines), o.ref ?? randomUUID(),
    o.reference ?? null, o.vehicle === undefined ? 'GJ01AB1234' : o.vehicle]);

// =============================================================================
section('Packaging mapping (type → size → bag / bundle)');

await asUser(db, ADMIN, async () => {
  const r = await one(
    `select public.upsert_pipe_product($1,$2,'TB-S4',47.5,5,50,true,16) as j`, [TB, S4]);
  check('an admin can set pipes per bag on a product', r.j.id != null);

  const p = await one(`select pipes_per_bag, bag_weight_kg from v_pipe_products where sku='TB-S4'`);
  check('the product view exposes the mapping and the derived bag weight',
    num(p.pipes_per_bag) === 16 && num(p.bag_weight_kg) === 152,
    JSON.stringify(p));

  check('a bag count without a bundle count is refused',
    await sqlstate(() => db.query(
      `select public.upsert_pipe_product($1,$2,'TB-S4',47.5,null,50,true,16)`, [TB, S4])) === 'DP005');

  check('a zero bag count is refused',
    await sqlstate(() => db.query(
      `select public.upsert_pipe_product($1,$2,'TB-S4',47.5,5,50,true,0)`, [TB, S4])) === 'DP005');

  // Put TB-S4 back to bundles-only; later tests rely on an unmapped product.
  await db.query(`select public.upsert_pipe_product($1,$2,'TB-S4',47.5,5,50,true,null)`, [TB, S4]);
});

await asUser(db, RAVI, async () => {
  check('an operator cannot change the packaging mapping',
    await sqlstate(() => db.query(
      `select public.upsert_pipe_product($1,$2,'TA-S1',18.5,10,100,true,99)`, [TA, S1])) === 'DP004');
  check('nor write the product table directly',
    (await db.query(`update pipe_products set pipes_per_bag=1 where sku='TA-S1' returning id`)).rows.length === 0);
});

// =============================================================================
section('Production — bundles, bags, both');

let before = await stock(TA, S1);
await asUser(db, RAVI, async () => {
  const r = (await produce({ machine: M1, bundles: 12 })).rows[0].j;
  check('bundles only: recorded', r.duplicate === false && r.bag_quantity === 0);
});
let after = await stock(TA, S1);
check('bundles only: bundle stock rises, bag stock does not',
  after.bundles === before.bundles + 12 && after.bags === before.bags,
  `${JSON.stringify(before)} -> ${JSON.stringify(after)}`);

before = after;
await asUser(db, RAVI, async () => {
  const r = (await produce({ machine: M1, bags: 7 })).rows[0].j;
  // TA-S1: 18.5 kg per 10 pipes, 20 pipes a bag -> 37 kg a bag.
  check('bags only: the bag weight is derived from the mapping',
    num(r.bag_weight_kg) === 37, JSON.stringify(r));
  check('bags only: output weight counts the bags', num(r.output_weight_kg) === 259,
    JSON.stringify(r));
});
after = await stock(TA, S1);
check('bags only: bag stock rises, bundle stock does not',
  after.bags === before.bags + 7 && after.bundles === before.bundles,
  `${JSON.stringify(before)} -> ${JSON.stringify(after)}`);

before = await stock(TB, S2);
await asUser(db, SURESH, async () => {
  const r = (await produce({ machine: M2, type: TB, size: S2, bundles: 5, bags: 3 })).rows[0].j;
  // TB-S2: 5 x 28.5 + 3 x (28.5 x 16 / 8) = 142.5 + 171.
  check('both: one entry carries both, weighed together',
    num(r.output_weight_kg) === 313.5, JSON.stringify(r));
});
after = await stock(TB, S2);
check('both: each balance moves by its own quantity',
  after.bundles === before.bundles + 5 && after.bags === before.bags + 3,
  `${JSON.stringify(before)} -> ${JSON.stringify(after)}`);

const ledger = await db.query(
  `select packaging, bundle_quantity from finished_goods_transactions
   where pipe_type_id=$1 and pipe_size_id=$2 and transaction_type='PRODUCTION'
   order by created_at desc limit 2`, [TB, S2]);
check('both: the ledger records one row per packaging',
  ledger.rows.some((r) => r.packaging === 'BUNDLE' && r.bundle_quantity === 5)
  && ledger.rows.some((r) => r.packaging === 'BAG' && r.bundle_quantity === 3),
  JSON.stringify(ledger.rows));

await asUser(db, SURESH, async () => {
  const s = await stock(TB, S4);
  check('bags for a product with no bag mapping are refused',
    await sqlstate(() => produce({ machine: M2, type: TB, size: S4, bags: 2 })) === 'DP005');
  const t = await stock(TB, S4);
  check('and nothing was written', s.bags === t.bags && s.bundles === t.bundles);

  check('zero bundles and zero bags is refused',
    await sqlstate(() => produce({ machine: M2, bundles: 0, bags: 0 })) === 'DP005');
  check('a negative quantity is refused',
    await sqlstate(() => produce({ machine: M2, bundles: -3 })) === 'DP005');
});

// =============================================================================
section('Production — wastage material used');

const regrind = await one(`select coalesce(sum(quantity),0) as q from raw_material_stock s
  join raw_materials m on m.id = s.raw_material_id where m.is_recycled`);

await asUser(db, RAVI, async () => {
  const yes = (await produce({ machine: M1, bundles: 4, used: true, usedKg: 6.5 })).rows[0].j;
  const row = await one(
    `select wastage_used, wastage_used_kg from production_entries where id=$1`, [yes.id]);
  check('Yes with a quantity is stored against the entry',
    row.wastage_used === true && num(row.wastage_used_kg) === 6.5, JSON.stringify(row));

  const no = (await produce({ machine: M1, bundles: 4, used: false })).rows[0].j;
  const row2 = await one(
    `select wastage_used, wastage_used_kg from production_entries where id=$1`, [no.id]);
  check('No stores no quantity', row2.wastage_used === false && row2.wastage_used_kg === null);

  const zeroNo = (await produce({ machine: M1, bundles: 4, used: false, usedKg: 0 })).rows[0].j;
  const row3 = await one(`select wastage_used_kg from production_entries where id=$1`, [zeroNo.id]);
  check('No with zero is stored as no quantity', row3.wastage_used_kg === null);

  check('Yes without a quantity is refused',
    await sqlstate(() => produce({ machine: M1, bundles: 4, used: true })) === 'DP005');
  check('Yes with zero is refused',
    await sqlstate(() => produce({ machine: M1, bundles: 4, used: true, usedKg: 0 })) === 'DP005');
  check('Yes with a negative quantity is refused',
    await sqlstate(() => produce({ machine: M1, bundles: 4, used: true, usedKg: -2 })) === 'DP005');
  check('No with a quantity is refused rather than discarded',
    await sqlstate(() => produce({ machine: M1, bundles: 4, used: false, usedKg: 3 })) === 'DP005');
});

const regrindAfter = await one(`select coalesce(sum(quantity),0) as q from raw_material_stock s
  join raw_materials m on m.id = s.raw_material_id where m.is_recycled`);
check('recording wastage used moves no recycled stock (A28)',
  num(regrind.q) === num(regrindAfter.q));

await asUser(db, ADMIN, async () => {
  // The database's own date: the report works in factory-local days.
  const rows = (await db.query(
    `select coalesce(sum(wastage_used_kg),0) as used, coalesce(sum(bags),0) as bags
     from public.production_report(current_date, current_date)`)).rows[0];
  check('the production report carries wastage used and bags',
    num(rows.used) >= 6.5 && num(rows.bags) >= 10, JSON.stringify(rows));
});

// =============================================================================
section('Shifts — Morning and Night only');

check('exactly two shifts exist and are in use',
  (await one(`select count(*) filter (where active) as a, count(*) as n from shifts`)).a == 2);

await asUser(db, IMRAN, async () => {
  const r = (await produce({ machine: M3, shift: NIGHT, bundles: 9 })).rows[0].j;
  check('a Night shift entry is accepted', r.duplicate === false);
});

await asUser(db, ADMIN, async () => {
  check('an Afternoon shift cannot be created',
    await sqlstate(() => db.query(
      `insert into shifts (name, start_time, end_time) values ('Afternoon','14:00','22:00')`)) === 'DP005');
  check('Morning cannot be renamed',
    await sqlstate(() => db.query(`update shifts set name='Day' where id=$1`, [MORNING])) === 'DP005');
  check('Night cannot be switched off',
    await sqlstate(() => db.query(`update shifts set active=false where id=$1`, [NIGHT])) === 'DP005');
  check('Night cannot be deleted',
    await sqlstate(() => db.query(`delete from shifts where id=$1`, [NIGHT])) === 'DP005');

  await db.query(`update shifts set start_time='07:00', end_time='19:00' where id=$1`, [MORNING]);
  const s = await one(`select start_time from shifts where id=$1`, [MORNING]);
  check('shift times stay editable', s.start_time === '07:00:00', s.start_time);
});

await asUser(db, RAVI, async () => {
  check('an operator cannot touch the shift master',
    (await db.query(`update shifts set start_time='05:00' where id=$1 returning id`, [MORNING])).rows.length === 0);
});

// =============================================================================
section('Dispatch — bundles only, bags only, both');

await asUser(db, ADMIN, async () => {
  let b = await stock(TA, S1);
  const onlyBundles = (await dispatch({ lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 10 }] })).rows[0].j;
  let a = await stock(TA, S1);
  check('bundles only: bundles leave, bags stay',
    onlyBundles.total_bundles === 10 && onlyBundles.total_bags === 0
    && a.bundles === b.bundles - 10 && a.bags === b.bags,
    `${JSON.stringify(b)} -> ${JSON.stringify(a)}`);

  b = a;
  const onlyBags = (await dispatch({ lines: [{ pipe_type_id: TA, pipe_size_id: S1, bag_quantity: 4 }] })).rows[0].j;
  a = await stock(TA, S1);
  check('bags only: bags leave, bundles stay',
    onlyBags.total_bags === 4 && a.bags === b.bags - 4 && a.bundles === b.bundles,
    `${JSON.stringify(b)} -> ${JSON.stringify(a)}`);

  // The request's own example: 20 bundles and 10 bags to one buyer.
  await db.query(`select public.record_production(
    p_machine_id := $1, p_shift_id := $2, p_pipe_type_id := $3, p_pipe_size_id := $4,
    p_bundle_quantity := 0, p_client_ref := $5, p_operator_id := $6, p_bag_quantity := 20)`,
    [M1, MORNING, TA, S1, randomUUID(), RAVI_ID]);
  b = await stock(TA, S1);
  const both = (await dispatch({
    buyer: 'ABC Industries', vehicle: 'gj xx-1234',
    lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 20, bag_quantity: 10 }],
  })).rows[0].j;
  a = await stock(TA, S1);
  check('both: one line, both quantities leave their own balance',
    both.total_bundles === 20 && both.total_bags === 10
    && a.bundles === b.bundles - 20 && a.bags === b.bags - 10,
    `${JSON.stringify(b)} -> ${JSON.stringify(a)}`);

  const line = await one(
    `select customer_name, vehicle_number, bundle_quantity, bag_quantity
     from v_dispatch_lines where dispatch_id=$1`, [both.id]);
  check('the line records bundles and bags separately',
    line.bundle_quantity === 20 && line.bag_quantity === 10, JSON.stringify(line));
  check('the vehicle number is stored normalised', line.vehicle_number === 'GJXX1234',
    line.vehicle_number);

  const note = await one(
    `select message from notifications where metadata->>'dispatch_id'=$1`, [both.id]);
  check('the notification names both quantities and what remains',
    /20 bundles and 10 bags/.test(note.message) && /bags\.$/.test(note.message), note.message);

  // Several products on one dispatch, one of them short on bags.
  const bundlesBefore = await stock(TB, S2);
  const bagsBefore = await stock(TA, S2);
  const short = await sqlstate(() => dispatch({
    lines: [
      { pipe_type_id: TB, pipe_size_id: S2, bundle_quantity: 1 },
      { pipe_type_id: TA, pipe_size_id: S2, bag_quantity: 999 },
    ],
  }));
  check('a dispatch short on bags is refused', short === 'DP002', `got ${short}`);
  check('ATOMICITY: and no line of it moved stock',
    JSON.stringify(await stock(TB, S2)) === JSON.stringify(bundlesBefore)
    && JSON.stringify(await stock(TA, S2)) === JSON.stringify(bagsBefore));

  check('bags for a product with no bag mapping are refused',
    await sqlstate(() => dispatch({ lines: [{ pipe_type_id: TB, pipe_size_id: S4, bag_quantity: 1 }] })) === 'DP005');
  check('a line with neither bundles nor bags is refused',
    await sqlstate(() => dispatch({ lines: [{ pipe_type_id: TA, pipe_size_id: S1 }] })) === 'DP005');
  check('a negative bag quantity is refused',
    await sqlstate(() => dispatch({ lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 1, bag_quantity: -1 }] })) === 'DP005');
  check('a missing buyer is refused',
    await sqlstate(() => dispatch({ buyer: '  ', lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 1 }] })) === 'DP005');
  check('a missing vehicle number is refused',
    await sqlstate(() => dispatch({ vehicle: null, lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 1 }] })) === 'DP005');
  check('a malformed vehicle number is refused',
    await sqlstate(() => dispatch({ vehicle: 'GJ/1', lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 1 }] })) === 'DP005');

  const ref = randomUUID();
  const first = (await dispatch({ ref, lines: [{ pipe_type_id: TA, pipe_size_id: S1, bag_quantity: 1 }] })).rows[0].j;
  const again = (await dispatch({ ref, lines: [{ pipe_type_id: TA, pipe_size_id: S1, bag_quantity: 1 }] })).rows[0].j;
  check('a retried dispatch is not applied twice', again.duplicate === true && again.id === first.id);
});

await asUser(db, RAVI, async () => {
  check('an operator cannot dispatch',
    await sqlstate(() => dispatch({ lines: [{ pipe_type_id: TA, pipe_size_id: S1, bundle_quantity: 1 }] })) === 'DP004');
  check('nor read dispatches',
    (await db.query(`select * from v_dispatch_lines`)).rows.length === 0);
});

// =============================================================================
section('Ledgers still reconcile, per packaging');

const bad = await db.query(`select ledger, label, balance, ledger_total from v_stock_reconciliation where not ok`);
check('every bundle and bag balance agrees with its ledger', bad.rows.length === 0,
  JSON.stringify(bad.rows));

await asUser(db, ADMIN, async () => {
  const rep = await one(
    `select closing_bundles from public.finished_goods_report(current_date, current_date)
     where sku = 'TA-S1'`).catch(() => null);
  const live = await stock(TA, S1);
  if (rep) {
    check('the bundle report ignores bag movements', num(rep.closing_bundles) === live.bundles,
      `${rep.closing_bundles} vs ${live.bundles}`);
  } else {
    const cols = (await db.query(
      `select * from public.finished_goods_report(current_date, current_date) limit 1`)).fields.map((f) => f.name);
    check('the bundle report ignores bag movements', false, `columns: ${cols}`);
  }
});

// =============================================================================
// A34 (0016) reverses A30: the operator loads their own machine, so the
// operator records it. The boundary moved from "admins only" to "your own
// machine only" — which is a narrowing for everyone except the person actually
// standing at the machine.
section('Material entry — an operator records their own machine (A34)');

await asUser(db, RAVI, async () => {
  const r = (await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID()])).rows[0].j;
  check('an operator can record a batch for their own machine',
    r.duplicate === false && Number(r.total_quantity) === 1, JSON.stringify(r));

  const e = await one(`select operator_id, machine_id from mixture_entries where id=$1`, [r.id]);
  check('and the batch is credited to them, on that machine',
    e.operator_id === RAVI_ID && e.machine_id === M1);

  // The two things the old admin-only rule was protecting against are still
  // refused — they are just refused precisely now, rather than wholesale.
  const other = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M2, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID()]));
  check('but not for a machine they are not assigned to', other === 'DP006', `got ${other}`);

  const someoneElse = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4,$5)`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID(), SURESH_ID]));
  check('and not on somebody else\'s behalf', someoneElse === 'DP004', `got ${someoneElse}`);

  const direct = await sqlstate(() => db.query(
    `insert into mixture_entries (machine_id, operator_id, shift_id, total_quantity, client_ref)
     values ($1,$2,$3,1,$4)`, [M1, RAVI_ID, MORNING, randomUUID()]));
  check('the function is still the only way in — no INSERT policy',
    direct !== null, `got ${direct}`);

  // The all-or-nothing rule is unchanged by the new caller.
  const before = Number((await one(
    `select quantity from raw_material_stock where raw_material_id=$1`, [RAIZIN])).quantity);
  const short = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 99999999 }]),
      randomUUID()]));
  const after = Number((await one(
    `select quantity from raw_material_stock where raw_material_id=$1`, [RAIZIN])).quantity);
  check('a short batch is still refused for an operator', short === 'DP001', `got ${short}`);
  check('and still deducts nothing', before === after, `${before} -> ${after}`);
});

await asUser(db, ADMIN, async () => {
  const r = (await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [M2, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 2 }]), randomUUID()])).rows[0].j;
  const e = await one(`select operator_id from mixture_entries where id=$1`, [r.id]);
  check('an admin entry is credited to the machine\'s operator', e.operator_id === SURESH_ID,
    `${e.operator_id} vs ${SURESH_ID}`);
});

// =============================================================================
section('Self-service profile');

await asUser(db, RAVI, async () => {
  const r = (await db.query(`select public.update_my_profile('Ravi K.', '+91 98765-43210') as j`)).rows[0].j;
  check('an operator can change their own name and phone',
    r.name === 'Ravi K.' && r.phone === '+919876543210', JSON.stringify(r));

  check('a short phone number is refused',
    await sqlstate(() => db.query(`select public.update_my_profile('Ravi', '12345')`)) === 'DP005');
  check('letters in a phone number are refused',
    await sqlstate(() => db.query(`select public.update_my_profile('Ravi', '98765abcde')`)) === 'DP005');
  check('an empty name is refused',
    await sqlstate(() => db.query(`select public.update_my_profile('   ', null)`)) === 'DP005');

  const cleared = (await db.query(`select public.update_my_profile('Ravi Kumar', '') as j`)).rows[0].j;
  check('the phone number can be cleared', cleared.phone === null);

  const direct = await db.query(
    `update profiles set role='ADMIN' where auth_user_id=$1 returning id`, [RAVI]);
  check('but cannot promote themselves by writing the table', direct.rows.length === 0);
});

const ravi = await one(`select role, auth_user_id, employee_code from profiles where id=$1`, [RAVI_ID]);
check('role, login and employee code are untouched',
  ravi.role === 'OPERATOR' && ravi.auth_user_id === RAVI && ravi.employee_code === 'EMP-101',
  JSON.stringify(ravi));

// =============================================================================
section('Operators see only their own history and attendance');

await asUser(db, RAVI, async () => {
  const rows = (await db.query(`select distinct operator_id from v_production_entries`)).rows;
  check('My Entries returns only the signed-in operator\'s rows',
    rows.length === 1 && rows[0].operator_id === RAVI_ID, JSON.stringify(rows));

  const cols = (await db.query(
    `select bag_quantity, wastage_used, wastage_used_kg, shift_name, pipe_type_name, pipe_size_name
     from v_production_entries limit 1`)).rows;
  check('and carries shift, product, bags and wastage used', cols.length === 1);

  await db.query(`select public.punch_in(p_shift_id := $1)`, [MORNING]);
  const att = (await db.query(`select distinct profile_id from v_attendance_days`)).rows;
  check('attendance returns only the signed-in person',
    att.length === 1 && att[0].profile_id === RAVI_ID, JSON.stringify(att));
});

await asUser(db, SURESH, async () => {
  const theirs = (await db.query(
    `select count(*) as n from v_production_entries where operator_id=$1`, [RAVI_ID])).rows[0];
  check('another operator cannot read those entries', num(theirs.n) === 0);
  check('nor that attendance',
    (await db.query(`select * from v_attendance_days where profile_id=$1`, [RAVI_ID])).rows.length === 0);
});

// =============================================================================
section('Upgrading a live database that still has an Afternoon shift');

const old = await build({ quiet: true, upto: '0014_payroll_views_rls.sql' });
await old.exec(`
  insert into profiles (id, name, employee_code, role) values
    ('aaaaaaaa-0000-4000-8000-000000000001','Admin','A-1','ADMIN'),
    ('aaaaaaaa-0000-4000-8000-000000000002','Op','O-1','OPERATOR');
  insert into machines (id, code, name) values ('bbbbbbbb-0000-4000-8000-000000000001','X1','X1');
  insert into shifts (id, name, start_time, end_time) values
    ('22222222-2222-4222-8222-000000000001','Morning','06:00','14:00'),
    ('22222222-2222-4222-8222-000000000002','Afternoon','14:00','22:00'),
    ('22222222-2222-4222-8222-000000000003','Night','22:00','06:00');
  insert into pipe_types (id, code, name) values ('cccccccc-0000-4000-8000-000000000001','T','T');
  insert into pipe_sizes (id, code, name) values ('dddddddd-0000-4000-8000-000000000001','Z','Z');
  insert into machine_assignments (machine_id, operator_id, shift_id) values
    ('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',
     '22222222-2222-4222-8222-000000000002');
  insert into production_entries
    (id, machine_id, operator_id, shift_id, pipe_type_id, pipe_size_id, bundle_quantity, client_ref)
  values ('eeeeeeee-0000-4000-8000-000000000001','bbbbbbbb-0000-4000-8000-000000000001',
          'aaaaaaaa-0000-4000-8000-000000000002','22222222-2222-4222-8222-000000000002',
          'cccccccc-0000-4000-8000-000000000001','dddddddd-0000-4000-8000-000000000001',
          14, gen_random_uuid());
  insert into dispatches (id, customer_name, client_ref) values
    ('ffffffff-0000-4000-8000-000000000001','Legacy Buyer', gen_random_uuid());
  insert into dispatch_lines (dispatch_id, pipe_type_id, pipe_size_id, bundle_quantity) values
    ('ffffffff-0000-4000-8000-000000000001','cccccccc-0000-4000-8000-000000000001',
     'dddddddd-0000-4000-8000-000000000001', 6);
`);

const upgrade = await sqlstate(() => applyMigration(old, '0015_packaging_shifts_access.sql'));
check('0015 applies to a database that has history on it', upgrade === null, `got ${upgrade}`);

const oq = async (sql) => (await old.query(sql)).rows;
const shiftRows = await oq(`select name, active, start_time, end_time from shifts order by name`);
check('Afternoon is switched off, not deleted',
  shiftRows.some((s) => s.name === 'Afternoon' && s.active === false), JSON.stringify(shiftRows));
check('Morning and Night stay on, moved to cover the day',
  shiftRows.some((s) => s.name === 'Morning' && s.active && s.end_time === '18:00:00')
  && shiftRows.some((s) => s.name === 'Night' && s.active && s.start_time === '18:00:00'),
  JSON.stringify(shiftRows));

const legacy = (await oq(
  `select shift_name, bundle_quantity, bag_quantity, wastage_used, wastage_used_kg
   from v_production_entries where id='eeeeeeee-0000-4000-8000-000000000001'`))[0];
check('a historical Afternoon entry still resolves, unchanged',
  legacy && legacy.shift_name === 'Afternoon' && legacy.bundle_quantity === 14
  && legacy.bag_quantity === 0 && legacy.wastage_used === false && legacy.wastage_used_kg === null,
  JSON.stringify(legacy));

const legacyLine = (await oq(
  `select bundle_quantity, bag_quantity from v_dispatch_lines
   where dispatch_id='ffffffff-0000-4000-8000-000000000001'`))[0];
check('a historical dispatch line reads as bundles with no bags',
  legacyLine.bundle_quantity === 6 && legacyLine.bag_quantity === 0, JSON.stringify(legacyLine));

const assignment = (await oq(`select shift_id from machine_assignments`))[0];
check('the assignment on Afternoon loses its shift', assignment.shift_id === null);
const warned = await oq(`select message from notifications where title='Shift assignments need attention'`);
check('and the administrators are told', warned.length === 1, JSON.stringify(warned));

const newOnOld = await sqlstate(() => old.query(`
  insert into production_entries
    (machine_id, operator_id, shift_id, pipe_type_id, pipe_size_id, bundle_quantity, client_ref)
  values ('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',
          '22222222-2222-4222-8222-000000000002','cccccccc-0000-4000-8000-000000000001',
          'dddddddd-0000-4000-8000-000000000001', 1, gen_random_uuid())`));
check('a new entry on the retired Afternoon shift is refused', newOnOld === 'DP005', `got ${newOnOld}`);

const reopen = await sqlstate(() => old.query(
  `update shifts set active = true where name = 'Afternoon'`));
check('and Afternoon cannot be switched back on', reopen === 'DP005', `got ${reopen}`);

// =============================================================================
console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
