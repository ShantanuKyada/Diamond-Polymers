import { build, asUser, chargeBatch } from './harness.mjs';
import { randomUUID } from 'node:crypto';

// A Postgres error thrown outside a check() would otherwise print PGlite's whole
// bundled source and bury the one line that matters.
process.on('unhandledRejection', (e) => {
  console.error(`\nUNHANDLED: ${e && e.message ? e.message : e}`);
  if (e && e.query) console.error(`  query:  ${String(e.query).slice(0, 160)}`);
  if (e && e.detail) console.error(`  detail: ${e.detail}`);
  process.exit(1);
});

let pass = 0, fail = 0;
const failures = [];

function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(name); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

// Capture the SQLSTATE of a failing call rather than the driver's prose.
async function sqlstate(fn) {
  try { await fn(); return null; }
  catch (e) { return e.code ?? e.severity ?? String(e.message).slice(0, 80); }
}

const db = await build({ quiet: true });

// ---------------------------------------------------------------------------
// Link logins, the way docs/02-setup.md step 3 does.
// ---------------------------------------------------------------------------
const ADMIN_AUTH = randomUUID();
const RAVI_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1,'admin@dp.local'),($2,'ravi@dp.local')`,
  [ADMIN_AUTH, RAVI_AUTH]);
await db.query(`update public.profiles set auth_user_id=$1 where employee_code='EMP-001'`, [ADMIN_AUTH]);
await db.query(`update public.profiles set auth_user_id=$1 where employee_code='EMP-101'`, [RAVI_AUTH]);

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (sql, params = []) => (await db.query(sql, params)).rows;
const num = (v) => v === null || v === undefined ? null : Number(v);

const M1 = (await one(`select id from machines where code='M1'`)).id;
const M4 = (await one(`select id from machines where code='M4'`)).id;
const SHIFT1 = (await one(`select id from shifts where name='Morning'`)).id;
const TA = (await one(`select id from pipe_types where code='TA'`)).id;
const TB = (await one(`select id from pipe_types where code='TB'`)).id;
const S1 = (await one(`select id from pipe_sizes where code='S1'`)).id;
const S3 = (await one(`select id from pipe_sizes where code='S3'`)).id;
const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const REGRIND_A = (await one(`select id from raw_materials where code='RM-REGRIND-A'`)).id;
const RAIZIN = (await one(`select id from raw_materials where code='RM-RAIZIN'`)).id;

// =============================================================================
section('Schema and seed integrity');

const drift = await all(`select * from v_stock_reconciliation where not ok`);
check('every cached balance is explained by its ledger', drift.length === 0,
  JSON.stringify(drift.slice(0, 3)));

const products = await all(`select * from v_pipe_products order by sku`);
check('8 products, each with a bundle weight', products.length === 8
  && products.every(p => Number(p.bundle_weight_kg) > 0));

const ta_s1 = products.find(p => p.sku === 'TA-S1');
check('stock is reported in bundles and kg',
  num(ta_s1.stock_weight_kg) === num(ta_s1.quantity_bundles) * 18.5,
  `${ta_s1.quantity_bundles} bundles -> ${ta_s1.stock_weight_kg} kg`);

const backfilled = await one(
  `select count(*) filter (where bundle_weight_kg is null) as missing,
          count(*) as total from production_entries`);
check('every seeded production entry carries its weight', num(backfilled.missing) === 0,
  `${backfilled.missing} of ${backfilled.total} missing`);

const gen = await one(
  `select bundle_quantity, bundle_weight_kg, output_weight_kg from production_entries
   where bundle_weight_kg is not null limit 1`);
check('output_weight_kg is generated, not stored by hand',
  num(gen.output_weight_kg) === num(gen.bundle_quantity) * num(gen.bundle_weight_kg));

// The demo data must describe a factory that could physically exist. Before
// bundles had weights nothing could check this, and the seed happily claimed
// 2.3 tonnes of pipe out of a 67 kg batch. Excludes today, whose numbers the
// rest of this file goes on to change.
const seeded = await all(`select machine_name, entry_date, consumed_kg, produced_kg,
  wastage_kg, unaccounted_kg, yield_pct
  from v_production_material_balance
  where entry_date < current_date order by entry_date, machine_name`);
check('the seeded history covers every machine and day', seeded.length === 8,
  `${seeded.length} machine-days`);
check('no seeded day claims more product than material went in',
  seeded.every(r => num(r.yield_pct) > 90 && num(r.yield_pct) <= 100),
  JSON.stringify(seeded.map(r => num(r.yield_pct))));
check('every seeded day balances to within a kilogram',
  seeded.every(r => Math.abs(num(r.unaccounted_kg)) < 1),
  JSON.stringify(seeded.map(r => num(r.unaccounted_kg))));

// =============================================================================
section('record_production — weight snapshot and capability');

// Since A37 a run belongs to the batch that fed it, so the machine is charged
// first — exactly as the floor does it. One batch may feed several runs, which
// is why the same one is reused through this section.
let batch;
let prodId;
await asUser(db, RAVI_AUTH, async () => {
  batch = await chargeBatch(db,
    { machineId: M1, shiftId: SHIFT1, materialId: RAIZIN, quantity: 40 });

  const r = await one(
    `select public.record_production($1,$2,$3,$4,$5,$6,
       p_mixture_entry_id => $7) as j`,
    [M1, SHIFT1, TA, S1, 10, randomUUID(), batch]);
  const j = r.j;
  prodId = j.id;
  check('production records and returns the weight it used',
    num(j.bundle_weight_kg) === 18.5 && num(j.output_weight_kg) === 185,
    JSON.stringify(j));
});

// Production without a batch is refused outright (A37).
await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6)`,
    [M1, SHIFT1, TA, S1, 1, randomUUID()]));
  check('production with no batch is refused', state === 'DP012', `got ${state}`);
});

// A later spec change must not rewrite what already happened.
await db.query(`update pipe_products set bundle_weight_kg = 21.000 where sku='TA-S1'`);
const afterChange = await one(`select bundle_weight_kg, output_weight_kg from production_entries where id=$1`, [prodId]);
check('changing the spec does not rewrite historical entries',
  num(afterChange.bundle_weight_kg) === 18.5 && num(afterChange.output_weight_kg) === 185,
  JSON.stringify(afterChange));

const hist = await all(`select * from pipe_product_weight_history h
  join pipe_products p on p.id=h.pipe_product_id where p.sku='TA-S1' order by changed_at`);
check('the weight change is recorded in the audit trail', hist.length === 2
  && num(hist[1].previous_weight_kg) === 18.5 && num(hist[1].new_weight_kg) === 21,
  JSON.stringify(hist.map(h => [h.previous_weight_kg, h.new_weight_kg])));

await db.query(`update pipe_products set bundle_weight_kg = 18.500 where sku='TA-S1'`);

// M4 has no configured products, so it is unconstrained.
await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6,$7)`,
    [M4, SHIFT1, TA, S1, 5, randomUUID(), RAVI]));
  check('an operator cannot record on a machine they are not assigned to',
    state === 'DP006', `got ${state}`);
});

// M1 is configured for all 8 products; restrict it and try again.
await db.query(`select public.set_machine_products($1, array[
  (select id from pipe_products where sku='TA-S1')]::uuid[])`, [M1])
  .catch(async () => {
    // set_machine_products requires admin; call it as the admin.
    await asUser(db, ADMIN_AUTH, () => db.query(
      `select public.set_machine_products($1, array[(select id from pipe_products where sku='TA-S1')]::uuid[])`, [M1]));
  });

await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TB, S3, 5, randomUUID(), batch]));
  check('a machine cannot be credited with a product it does not run',
    state === 'DP009', `got ${state}`);

  const okAgain = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TA, S1, 3, randomUUID(), batch]));
  check('the product it does run is still accepted', okAgain === null, `got ${okAgain}`);
});

// Restore the full capability set for the remaining tests.
await asUser(db, ADMIN_AUTH, () => db.query(
  `select public.set_machine_products($1, (select array_agg(id) from pipe_products))`, [M1]));

// A product with no weight cannot be produced at all.
await db.query(`insert into pipe_sizes (id, code, name, sort_order)
  values ('44444444-4444-4444-8444-000000000099','S9','Size 9',9)`);
await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TA, '44444444-4444-4444-8444-000000000099', 5, randomUUID(), batch]));
  check('production is refused when no bundle weight is configured',
    state === 'DP008', `got ${state}`);
});

// =============================================================================
section('shred_pipe — rejects at the machine');

const before = {
  regrind: num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity),
  bundles: num((await one(`select quantity_bundles from finished_goods_stock where pipe_type_id=$1 and pipe_size_id=$2`, [TA, S1])).quantity_bundles),
};

await asUser(db, RAVI_AUTH, async () => {
  const r = await one(`select public.shred_pipe($1,$2,$3,$4,$5,null,null,$6,$7) as j`,
    ['PRODUCTION_REJECT', TA, S1, 12.5, randomUUID(), M1, SHIFT1]);
  check('a reject shred returns the recycled balance', num(r.j.recovered_kg) === 12.5);
});

const afterReject = {
  regrind: num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity),
  bundles: num((await one(`select quantity_bundles from finished_goods_stock where pipe_type_id=$1 and pipe_size_id=$2`, [TA, S1])).quantity_bundles),
};
check('regrind stock rises by the recovered weight',
  afterReject.regrind === before.regrind + 12.5, `${before.regrind} -> ${afterReject.regrind}`);
check('finished goods are untouched — those bundles never existed',
  afterReject.bundles === before.bundles, `${before.bundles} -> ${afterReject.bundles}`);

await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.shred_pipe($1,$2,$3,$4,$5,$6,null,$7,$8)`,
    ['PRODUCTION_REJECT', TA, S1, 5, randomUUID(), 3, M1, SHIFT1]));
  check('a reject shred refuses a bundle count', state === 'DP005', `got ${state}`);
});

// =============================================================================
section('shred_pipe — bundles pulled from stock');

await asUser(db, RAVI_AUTH, async () => {
  const r = await one(`select public.shred_pipe($1,$2,$3,$4,$5,$6,null,$7,$8) as j`,
    ['FINISHED_BUNDLE', TA, S1, 35.0, randomUUID(), 2, M1, SHIFT1]);
  check('a bundle shred reports expected against recovered',
    num(r.j.expected_kg) === 37 && num(r.j.recovered_kg) === 35, JSON.stringify(r.j));
});

const afterBundle = {
  regrind: num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity),
  bundles: num((await one(`select quantity_bundles from finished_goods_stock where pipe_type_id=$1 and pipe_size_id=$2`, [TA, S1])).quantity_bundles),
};
check('bundles leave finished goods', afterBundle.bundles === afterReject.bundles - 2,
  `${afterReject.bundles} -> ${afterBundle.bundles}`);
check('and the regrind enters raw stock in the same movement',
  afterBundle.regrind === afterReject.regrind + 35, `${afterReject.regrind} -> ${afterBundle.regrind}`);

const fgLedger = await one(`select transaction_type, bundle_quantity, previous_stock, resulting_stock
  from finished_goods_transactions where transaction_type='SHRED' order by created_at desc limit 1`);
check('the shred is a distinct ledger line, not an adjustment',
  fgLedger.transaction_type === 'SHRED' && num(fgLedger.bundle_quantity) === -2);

// =============================================================================
section('shred_pipe — the rules that protect the ledger');

await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.shred_pipe($1,$2,$3,$4,$5,$6,null,$7,$8)`,
    ['FINISHED_BUNDLE', TA, S1, 100, randomUUID(), 2, M1, SHIFT1]));
  check('shredding cannot create mass — 100 kg from 37 kg is refused',
    state === 'DP005', `got ${state}`);
});

// The atomicity test: ask for more bundles than exist. The regrind must not be
// created, and no shred row may survive.
const shredsBefore = num((await one(`select count(*) as n from shred_entries`)).n);
const regrindBefore = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity);

await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.shred_pipe($1,$2,$3,$4,$5,$6,null,$7,$8)`,
    ['FINISHED_BUNDLE', TA, S1, 18000, randomUUID(), 1000, M1, SHIFT1]));
  check('shredding more bundles than exist is refused', state === 'DP002', `got ${state}`);
});

const shredsAfter = num((await one(`select count(*) as n from shred_entries`)).n);
const regrindAfter = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity);
check('ATOMICITY: the failed shred left no entry row', shredsAfter === shredsBefore,
  `${shredsBefore} -> ${shredsAfter}`);
check('ATOMICITY: the failed shred created no regrind', regrindAfter === regrindBefore,
  `${regrindBefore} -> ${regrindAfter}`);

// Idempotency.
const ref = randomUUID();
let firstId;
await asUser(db, RAVI_AUTH, async () => {
  const a = await one(`select public.shred_pipe($1,$2,$3,$4,$5,null,null,$6,$7) as j`,
    ['PRODUCTION_REJECT', TA, S1, 4.0, ref, M1, SHIFT1]);
  firstId = a.j.id;
  const b = await one(`select public.shred_pipe($1,$2,$3,$4,$5,null,null,$6,$7) as j`,
    ['PRODUCTION_REJECT', TA, S1, 4.0, ref, M1, SHIFT1]);
  check('a retry returns the original shred instead of a second one',
    b.j.duplicate === true && b.j.id === firstId, JSON.stringify(b.j));
});
const dupCount = num((await one(`select count(*) as n from shred_entries where client_ref=$1`, [ref])).n);
check('and only one row exists for that submission', dupCount === 1, `${dupCount} rows`);

// Regrind must not be posted into a virgin material.
await asUser(db, RAVI_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.shred_pipe($1,$2,$3,$4,$5,null,$6,$7,$8)`,
    ['PRODUCTION_REJECT', TA, S1, 5, randomUUID(), RAIZIN, M1, SHIFT1]));
  check('shredded pipe cannot be posted into a virgin-material pool',
    state === 'DP005', `got ${state}`);
});

// =============================================================================
section('The loop closes — regrind is an ordinary raw material');

const regrindStock = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity);
// Material entry is recorded by an administrator (A30).
await asUser(db, ADMIN_AUTH, async () => {
  const r = await one(`select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [M1, SHIFT1,
      JSON.stringify([{ raw_material_id: RAIZIN, quantity: 20 },
      { raw_material_id: REGRIND_A, quantity: 15 }]),
      randomUUID()]);
  check('a mixture can feed regrind in alongside virgin material',
    num(r.j.total_quantity) === 35, JSON.stringify(r.j));
});
const regrindLeft = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity);
check('and the regrind is drawn down like any other input',
  regrindLeft === regrindStock - 15, `${regrindStock} -> ${regrindLeft}`);

// A basket short on one material must deduct none of the others.
const raizinBefore = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [RAIZIN])).quantity);
await asUser(db, ADMIN_AUTH, async () => {
  const state = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M1, SHIFT1,
      JSON.stringify([{ raw_material_id: RAIZIN, quantity: 10 },
      { raw_material_id: REGRIND_A, quantity: 99999 }]),
      randomUUID()]));
  check('a mixture short on one material is refused', state === 'DP001', `got ${state}`);
});
const raizinAfter = num((await one(`select quantity from raw_material_stock where raw_material_id=$1`, [RAIZIN])).quantity);
check('ATOMICITY: and none of the other materials moved',
  raizinAfter === raizinBefore, `${raizinBefore} -> ${raizinAfter}`);

// =============================================================================
section('Row level security');

await asUser(db, RAVI_AUTH, async () => {
  const s1 = await sqlstate(() => db.query(
    `insert into shred_entries (source,pipe_type_id,pipe_size_id,recovered_kg,recycled_material_id,client_ref)
     values ('PRODUCTION_REJECT',$1,$2,999,$3,$4)`, [TA, S1, REGRIND_A, randomUUID()]));
  check('an operator cannot insert a shred directly', s1 === '42501', `got ${s1}`);

  // An UPDATE that no policy permits touches zero rows rather than raising:
  // Postgres only raises 42501 on a WITH CHECK violation. The property that
  // matters is that the value did not move, so assert that directly.
  const u2 = await db.query(
    `update raw_material_stock set quantity = 999999 where raw_material_id=$1`, [REGRIND_A]);
  check('an operator cannot write a stock balance', u2.affectedRows === 0,
    `${u2.affectedRows} rows updated`);

  const u3 = await db.query(`update pipe_products set bundle_weight_kg = 1 where sku='TA-S1'`);
  check('an operator cannot retune a bundle weight', u3.affectedRows === 0,
    `${u3.affectedRows} rows updated`);

  const s4 = await sqlstate(() => db.query(
    `select public.set_machine_products($1, '{}'::uuid[])`, [M1]));
  check('an operator cannot change machine capabilities', s4 === 'DP004', `got ${s4}`);

  const visible = await all(`select * from pipe_products`);
  check('but an operator can read the products and their weights', visible.length >= 8);

  const wh = await all(`select * from pipe_product_weight_history`);
  check('the weight audit trail is admin-only', wh.length === 0, `${wh.length} rows visible`);
});

const shredsPreDelete = num((await one(`select count(*) as n from shred_entries`)).n);
await asUser(db, ADMIN_AUTH, async () => {
  const wh = await all(`select * from pipe_product_weight_history`);
  check('an admin can read the weight audit trail', wh.length > 0);

  const d = await db.query(`delete from shred_entries`);
  check('not even an admin can delete a shred', d.affectedRows === 0,
    `${d.affectedRows} rows deleted`);

  const u = await db.query(`update shred_entries set recovered_kg = 1`);
  check('not even an admin can rewrite a shred', u.affectedRows === 0,
    `${u.affectedRows} rows updated`);
});
const shredsPostDelete = num((await one(`select count(*) as n from shred_entries`)).n);
check('the shred log is intact after those attempts',
  shredsPostDelete === shredsPreDelete, `${shredsPreDelete} -> ${shredsPostDelete}`);

// The balances the operator tried to overwrite must be exactly as they were.
const untouched = num((await one(
  `select quantity from raw_material_stock where raw_material_id=$1`, [REGRIND_A])).quantity);
check('the stock balance an operator tried to overwrite is unchanged',
  untouched !== 999999 && untouched === regrindLeft, `${untouched}`);
check('the bundle weight an operator tried to retune is unchanged',
  num((await one(`select bundle_weight_kg from pipe_products where sku='TA-S1'`)).bundle_weight_kg) === 18.5);

// =============================================================================
section('Material balance');

const bal = await one(`select * from v_production_material_balance
  where machine_id=$1 and entry_date=current_date`, [M1]);
check('the balance view returns a row for today', !!bal);
if (bal) {
  const expected = num(bal.consumed_kg) - num(bal.produced_kg) - num(bal.wastage_kg) - num(bal.reject_shred_kg);
  check('unaccounted_kg = consumed − produced − wastage − reject regrind',
    Math.abs(num(bal.unaccounted_kg) - expected) < 0.001,
    `${bal.unaccounted_kg} vs ${expected}`);
  check('recycled input is split out from virgin',
    num(bal.recycled_consumed_kg) > 0
    && Math.abs(num(bal.virgin_consumed_kg) + num(bal.recycled_consumed_kg) - num(bal.consumed_kg)) < 0.001,
    JSON.stringify({ v: bal.virgin_consumed_kg, r: bal.recycled_consumed_kg, c: bal.consumed_kg }));
  check('bundle shreds are reported separately, not folded into the day',
    num(bal.bundle_shred_kg) > 0 && num(bal.bundles_shredded) > 0);
  check('yield is a percentage of consumption',
    num(bal.yield_pct) > 0, `${bal.yield_pct}`);
}

const daily = await all(`select * from v_daily_material_balance order by entry_date desc limit 1`);
check('the factory-wide daily rollup works', daily.length === 1 && num(daily[0].consumed_kg) > 0);

const shredView = await all(`select * from v_shred_entries where source='FINISHED_BUNDLE' limit 1`);
check('recovery percentage is reported per shred',
  shredView.length === 1 && num(shredView[0].recovery_pct) > 0 && num(shredView[0].lost_kg) > 0,
  JSON.stringify(shredView[0] && { r: shredView[0].recovery_pct, l: shredView[0].lost_kg }));

const recycledView = await all(`select * from v_recycled_material_stock`);
check('recycled stock is reported apart from virgin stock',
  recycledView.length === 2 && recycledView.some(r => num(r.total_recovered_kg) > 0));

// =============================================================================
section('A37 — a run belongs to the batch that fed it');

await asUser(db, RAVI_AUTH, async () => {
  const own = await chargeBatch(db,
    { machineId: M1, shiftId: SHIFT1, materialId: RAIZIN, quantity: 60 });

  const r = await one(
    `select public.record_production($1,$2,$3,$4,$5,$6,
       p_mixture_entry_id => $7) as j`,
    [M1, SHIFT1, TA, S1, 2, randomUUID(), own]);
  const stored = await one(
    `select mixture_entry_id from production_entries where id=$1`, [r.j.id]);
  check('the link is stored on the entry', stored.mixture_entry_id === own);

  // The factory said one batch usually feeds one run, but asked not to forbid
  // a second — a batch that yields two sizes is two entries by A11.
  const second = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TA, S3, 1, randomUUID(), own]));
  check('a second run against the same batch is allowed', second === null,
    `got ${second}`);

  const missing = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TA, S1, 1, randomUUID(), randomUUID()]));
  check('a batch that does not exist is refused', missing === 'DP005',
    `got ${missing}`);
});

// A batch belongs to a machine, and a run cannot borrow another machine's.
const foreignBatch = await (async () => {
  let id;
  await asUser(db, ADMIN_AUTH, async () => {
    id = await chargeBatch(db,
      { machineId: M4, shiftId: SHIFT1, materialId: RAIZIN, quantity: 10 });
  });
  return id;
})();

await asUser(db, RAVI_AUTH, async () => {
  const wrong = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M1, SHIFT1, TA, S1, 1, randomUUID(), foreignBatch]));
  check('a batch charged into another machine is refused', wrong === 'DP005',
    `got ${wrong}`);
});

// The payoff: yield for one batch, not an average over a machine-day.
const yields = await all(
  `select * from v_batch_yield where runs > 0 order by created_at desc limit 1`);
check('v_batch_yield reports a batch that has produced', yields.length === 1);
if (yields.length === 1) {
  const y = yields[0];
  check('it puts kilograms in against kilograms out',
    num(y.charged_kg) > 0 && num(y.produced_kg) > 0,
    JSON.stringify({ in: y.charged_kg, out: y.produced_kg }));
  check('unaccounted = charged − produced − wastage',
    Math.abs(num(y.unaccounted_kg) -
      (num(y.charged_kg) - num(y.produced_kg) - num(y.wastage_kg))) < 0.001);
  check('yield is a percentage of what was charged',
    num(y.yield_pct) > 0, `${y.yield_pct}`);
}

// A batch still running has no runs against it yet, and says so rather than
// reporting a yield of zero as though the run had failed.
const openBatch = await all(
  `select * from v_batch_yield where runs = 0 limit 1`);
check('a batch with no production yet reports no yield',
  openBatch.length === 0 || openBatch[0].yield_pct === null,
  JSON.stringify(openBatch[0] ?? {}));

// The requirement is configurable, for back-filling and corrections.
await db.query(`update app_settings set value='false' where key='production_requires_batch'`);
await asUser(db, RAVI_AUTH, async () => {
  const relaxed = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6)`,
    [M1, SHIFT1, TA, S1, 1, randomUUID()]));
  check('turning the rule off allows an unlinked entry', relaxed === null,
    `got ${relaxed}`);
});
await db.query(`update app_settings set value='true' where key='production_requires_batch'`);

const finalDrift = await all(`select * from v_stock_reconciliation where not ok`);
check('after every movement, ledgers still explain every balance',
  finalDrift.length === 0, JSON.stringify(finalDrift.slice(0, 3)));

// =============================================================================
section('Phase 7 reporting — opening, movement, closing');

await asUser(db, ADMIN_AUTH, async () => {
  const rm = await all(`select * from raw_material_report($1, $2)`,
    ['2000-01-01', '2100-01-01']);
  check('the raw material report covers every active material', rm.length >= 5,
    `${rm.length} rows`);

  // Over an all-time window, opening is zero and closing must equal the live
  // balance. If those disagree the report is walking the ledger incorrectly.
  const live = await all(`select raw_material_id, quantity from raw_material_stock`);
  const byId = Object.fromEntries(live.map(r => [r.raw_material_id, num(r.quantity)]));
  const agree = rm.every(r => num(r.opening_qty) === 0
    && Math.abs(num(r.closing_qty) - (byId[r.raw_material_id] ?? 0)) < 0.001);
  check('all-time closing equals the live balance for every material', agree,
    JSON.stringify(rm.map(r => [r.material_code, r.closing_qty, byId[r.raw_material_id]])));

  const regrind = rm.find(r => r.material_code === 'RM-REGRIND-A');
  check('shredded returns are reported on their own line',
    num(regrind.shred_return_qty) > 0 && num(regrind.consumed_qty) > 0,
    JSON.stringify(regrind));

  const fg = await all(`select * from finished_goods_report($1, $2)`,
    ['2000-01-01', '2100-01-01']);
  const fgLive = await all(`select pipe_type_id, pipe_size_id, quantity_bundles from finished_goods_stock`);
  const fgById = Object.fromEntries(fgLive.map(r => [`${r.pipe_type_id}|${r.pipe_size_id}`, num(r.quantity_bundles)]));
  check('all-time closing bundles equal live finished-goods stock',
    fg.every(r => num(r.closing_bundles) === (fgById[`${r.pipe_type_id}|${r.pipe_size_id}`] ?? 0)),
    JSON.stringify(fg.map(r => [r.sku, r.closing_bundles, fgById[`${r.pipe_type_id}|${r.pipe_size_id}`]])));

  const shredded = fg.find(r => num(r.shredded_bundles) > 0);
  check('bundles destroyed by shredding are a separate report column', !!shredded,
    JSON.stringify(fg.map(r => [r.sku, r.shredded_bundles])));

  // Opening + movements = closing, on a window that splits the history.
  const half = await all(`select * from raw_material_report($1, $2)`,
    ['2000-01-01', new Date(Date.now() - 86400000).toISOString().slice(0, 10)]);
  check('a partial window still balances: opening + net = closing',
    half.every(r => Math.abs(
      num(r.opening_qty) + num(r.stock_in_qty) - num(r.consumed_qty) - num(r.wastage_qty)
      + num(r.recovered_qty) + num(r.shred_return_qty) + num(r.adjustment_qty)
      - num(r.closing_qty)) < 0.001),
    JSON.stringify(half.map(r => r.material_code)));

  const pr = await all(`select * from production_report($1, $2)`,
    ['2000-01-01', '2100-01-01']);
  check('the production report returns rows with weight', pr.length > 0
    && pr.every(r => num(r.output_kg) > 0));

  const filtered = await all(`select * from production_report($1, $2, $3)`,
    ['2000-01-01', '2100-01-01', M1]);
  check('the production report filters by machine',
    filtered.length > 0 && filtered.every(r => r.machine_id === M1)
    && filtered.length < pr.length);

  const bad = await sqlstate(() => db.query(
    `select * from raw_material_report($1, $2)`, ['2026-01-10', '2026-01-01']));
  check('a backwards date range is refused', bad === 'DP005', `got ${bad}`);
});

await asUser(db, RAVI_AUTH, async () => {
  // An operator's RLS view of the ledger is partial, so a report run as one
  // would return confident, wrong totals. It must refuse instead.
  const s = await sqlstate(() => db.query(
    `select * from raw_material_report($1, $2)`, ['2000-01-01', '2100-01-01']));
  check('an operator cannot run a stock report', s === 'DP004', `got ${s}`);
});

// =============================================================================
section('Phase 2 — linking a login to a profile');

// Creating the login is the dashboard's job and needs privileges the app role
// does not have; only the linking half is exercised as an admin.
const newAuth = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1, 'suresh@dp.local')`, [newAuth]);

await asUser(db, ADMIN_AUTH, async () => {
  const r = await one(`select public.link_profile_to_auth_user($1, $2) as j`,
    ['EMP-102', 'SURESH@DP.LOCAL']);
  check('an admin can attach a login to a profile, case-insensitively',
    r.j.employee_code === 'EMP-102' && r.j.auth_user_id === newAuth,
    JSON.stringify(r.j));

  const dupe = await sqlstate(() => db.query(
    `select public.link_profile_to_auth_user($1, $2)`, ['EMP-103', 'suresh@dp.local']));
  check('the same login cannot be attached to a second person',
    dupe === 'DP005', `got ${dupe}`);

  const noUser = await sqlstate(() => db.query(
    `select public.link_profile_to_auth_user($1, $2)`, ['EMP-103', 'nobody@dp.local']));
  check('linking to a login that does not exist is refused', noUser === 'DP005', `got ${noUser}`);

  const noProfile = await sqlstate(() => db.query(
    `select public.link_profile_to_auth_user($1, $2)`, ['EMP-999', 'suresh@dp.local']));
  check('linking a staff code that does not exist is refused',
    noProfile === 'DP005', `got ${noProfile}`);
});

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.link_profile_to_auth_user($1, $2)`, ['EMP-104', 'ravi@dp.local']));
  check('an operator cannot attach logins to profiles', s === 'DP004', `got ${s}`);
});

// =============================================================================
console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach(f => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
