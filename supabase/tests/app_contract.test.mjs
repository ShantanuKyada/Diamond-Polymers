// The contract between the Flutter app and the database.
//
// Every column list and RPC parameter name below is copied from
// `app/lib/features/**/data/*_repository.dart`. Dart has no idea whether
// `pipe_product_id` exists until PostgREST returns a 400 on a real device, and
// a mistyped RPC parameter fails the same way — at the worst moment, in front
// of somebody trying to record a shift's work.
//
// Duplicating the names here is the point: it turns a runtime surprise into a
// failing test. If a migration renames a column, this file fails and names the
// query that has to change with it.
import { build, asUser } from './harness.mjs';
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

const db = await build({ quiet: true });

const ADMIN_AUTH = randomUUID();
const RAVI_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1,'admin@dp.local'),($2,'ravi@dp.local')`,
  [ADMIN_AUTH, RAVI_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-001'`, [ADMIN_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-101'`, [RAVI_AUTH]);

// =============================================================================
section('Read queries the masters repository issues');

// [relation, column list exactly as written in Dart]
const READS = [
  ['machines', 'id, code, name, description, status, active'],
  ['shifts', 'id, name, start_time, end_time, active'],
  ['pipe_types', 'id, code, name, description, active, recycled_material_id'],
  ['pipe_sizes', 'id, code, name, description, sort_order, diameter_mm, length_m, active'],
  ['machine_products', 'pipe_product_id, machine_id, active'],
  ['raw_material_categories', 'code, name'],
  ['profiles', 'id, name, employee_code, phone, role, active, auth_user_id'],
  ['app_settings', 'key, value, description'],
  ['finished_goods_stock', 'pipe_type_id, pipe_size_id, minimum_stock'],
  // Views are read with select(), so the model's field names are the contract.
  ['v_pipe_products',
    'pipe_product_id, sku, pipe_type_id, pipe_type_name, pipe_size_id, ' +
    'pipe_size_name, bundle_weight_kg, active, quantity_bundles, ' +
    'stock_weight_kg, minimum_stock, status, diameter_mm, pipes_per_bundle'],
  ['v_raw_material_stock',
    'raw_material_id, code, name, category, category_name, unit, ' +
    'minimum_stock, quantity, status, active'],
  ['v_current_machine_assignments',
    'assignment_id, operator_id, operator_name, employee_code, machine_id, ' +
    'machine_name, machine_code, shift_id, shift_name, effective_from'],
  // Phase 3 — inventory
  ['v_finished_goods_stock',
    'pipe_type_id, pipe_type_name, pipe_size_id, pipe_size_name, ' +
    'quantity_bundles, minimum_stock, status, sort_order'],
  ['v_recycled_material_stock',
    'raw_material_id, code, name, unit, quantity, total_recovered_kg, ' +
    'total_consumed_kg'],
  // Packaging, shifts and access (0015)
  ['v_pipe_products', 'pipes_per_bag, quantity_bags, bag_weight_kg'],
  ['v_finished_goods_stock', 'quantity_bags'],
  ['v_production_entries',
    'id, entry_date, machine_id, machine_name, operator_id, operator_name, ' +
    'shift_name, pipe_type_id, pipe_type_name, pipe_size_id, pipe_size_name, ' +
    'bundle_quantity, bag_quantity, wastage_quantity, wastage_used, ' +
    'wastage_used_kg, remarks, created_at'],
  ['v_dispatch_lines',
    'dispatch_id, dispatch_date, customer_name, reference, vehicle_number, ' +
    'remarks, created_at, pipe_type_id, pipe_type_name, pipe_size_id, ' +
    'pipe_size_name, bundle_quantity, bag_quantity'],
  ['v_attendance_days',
    'profile_id, staff_name, employee_code, work_date, status, worked_hours, ' +
    'overtime_hours, punch_in_at, punch_out_at, shift_name'],
];

await asUser(db, ADMIN_AUTH, async () => {
  for (const [relation, columns] of READS) {
    try {
      await db.query(`select ${columns} from public.${relation} limit 1`);
      check(`${relation} exposes every column the app selects`, true);
    } catch (e) {
      check(`${relation} exposes every column the app selects`, false, e.message);
    }
  }
});

// =============================================================================
section('RPC signatures the app calls by name');

// PostgREST binds RPC arguments by NAME, so a renamed parameter breaks the call
// even though the function still exists.
const RPCS = [
  ['upsert_pipe_product',
    ['p_pipe_type_id', 'p_pipe_size_id', 'p_sku', 'p_bundle_weight_kg',
      'p_pipes_per_bundle', 'p_coil_length_m', 'p_active', 'p_pipes_per_bag']],
  // Packaging, shifts and access (0015)
  ['record_production',
    ['p_machine_id', 'p_shift_id', 'p_pipe_type_id', 'p_pipe_size_id',
      'p_bundle_quantity', 'p_client_ref', 'p_entry_date', 'p_wastage_quantity',
      'p_remarks', 'p_bag_quantity', 'p_wastage_used', 'p_wastage_used_kg']],
  ['create_dispatch',
    ['p_customer_name', 'p_lines', 'p_client_ref', 'p_dispatch_date',
      'p_reference', 'p_vehicle_number', 'p_remarks']],
  ['update_my_profile', ['p_name', 'p_phone']],
  ['punch_in', ['p_profile_id']],
  ['set_machine_products', ['p_machine_id', 'p_pipe_product_ids']],
  ['link_profile_to_auth_user', ['p_employee_code', 'p_email']],
  ['admin_dashboard', ['p_date']],
  ['operator_dashboard', ['p_date']],
  ['mark_notification_read', ['p_notification_id']],
  // Phase 3
  ['consume_raw_materials',
    ['p_machine_id', 'p_shift_id', 'p_lines', 'p_client_ref', 'p_operator_id',
      'p_entry_date', 'p_remarks']],
  ['add_raw_material_stock',
    ['p_raw_material_id', 'p_quantity', 'p_client_ref', 'p_remarks']],
  ['adjust_raw_material_stock',
    ['p_raw_material_id', 'p_delta', 'p_client_ref', 'p_remarks']],
  ['adjust_finished_goods_stock',
    ['p_pipe_type_id', 'p_pipe_size_id', 'p_delta', 'p_client_ref', 'p_remarks']],
];

for (const [name, params] of RPCS) {
  const rows = await db.query(
    `select p.proname, coalesce(array_to_string(p.proargnames, ','), '') as args
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = $1`, [name]);

  if (rows.rows.length === 0) {
    check(`${name} exists`, false, 'function not found');
    continue;
  }
  const actual = rows.rows[0].args.split(',').filter(Boolean);
  const missing = params.filter((p) => !actual.includes(p));
  check(`${name}(${params.length} params) matches the app's call`,
    missing.length === 0, `missing: ${missing.join(', ')}`);
}

// =============================================================================
section('Writes an admin makes directly, under RLS');

await asUser(db, ADMIN_AUTH, async () => {
  const machineId = randomUUID();
  try {
    await db.query(
      `insert into machines (id, code, name, description, status, active)
       values ($1,'M9','Machine 9','Test line','ACTIVE',true)`, [machineId]);
    check('an admin can insert a machine', true);
  } catch (e) {
    check('an admin can insert a machine', false, e.message);
  }

  try {
    await db.query(
      `update machines set code='M9', name='Machine 9b', status='MAINTENANCE'
       where id=$1`, [machineId]);
    const row = (await db.query(`select status from machines where id=$1`, [machineId])).rows[0];
    check('an admin can update a machine', row.status === 'MAINTENANCE');
  } catch (e) {
    check('an admin can update a machine', false, e.message);
  }

  const profileId = randomUUID();
  try {
    await db.query(
      `insert into profiles (id, name, employee_code, role, active, phone)
       values ($1,'Test Person','EMP-900','OPERATOR',true,null)`, [profileId]);
    check('an admin can add a person', true);
  } catch (e) {
    check('an admin can add a person', false, e.message);
  }

  // Assignment: close any open row, then open a new one — exactly what
  // assignOperator() does.
  try {
    await db.query(
      `update machine_assignments set effective_to = current_date
       where operator_id=$1 and effective_to is null`, [profileId]);
    await db.query(
      `insert into machine_assignments (operator_id, machine_id, shift_id, effective_from)
       values ($1,$2,(select id from shifts limit 1), current_date)`,
      [profileId, machineId]);
    check('an admin can assign an operator to a machine', true);
  } catch (e) {
    check('an admin can assign an operator to a machine', false, e.message);
  }

  try {
    await db.query(`update app_settings set value='25' where key='shred_recovery_tolerance_pct'`);
    const row = (await db.query(
      `select value from app_settings where key='shred_recovery_tolerance_pct'`)).rows[0];
    check('an admin can change a setting', row.value === '25');
  } catch (e) {
    check('an admin can change a setting', false, e.message);
  }

  // The reorder threshold is writable; the quantity beside it is not.
  try {
    const r = await db.query(
      `update finished_goods_stock set minimum_stock = 12
       where pipe_type_id=(select id from pipe_types limit 1)
         and pipe_size_id=(select id from pipe_sizes limit 1)`);
    check('an admin can set a finished-goods reorder level', r.affectedRows === 1,
      `${r.affectedRows} rows`);
  } catch (e) {
    check('an admin can set a finished-goods reorder level', false, e.message);
  }

  const blocked = await db.query(
    `update finished_goods_stock set quantity_bundles = 9999
     where pipe_type_id=(select id from pipe_types limit 1)
       and pipe_size_id=(select id from pipe_sizes limit 1)`).then(() => null).catch((e) => e.code);
  check('but not the quantity beside it', blocked === 'DP004', `got ${blocked}`);
});

// =============================================================================
section('An operator can read masters but not change them');

await asUser(db, RAVI_AUTH, async () => {
  // Entry forms need these lists, so reading must work for everyone.
  for (const relation of ['machines', 'shifts', 'pipe_types', 'pipe_sizes',
    'v_pipe_products', 'v_raw_material_stock', 'machine_products']) {
    const rows = await db.query(`select * from public.${relation}`);
    check(`an operator can read ${relation}`, rows.rows.length > 0,
      `${rows.rows.length} rows`);
  }

  const u = await db.query(`update machines set name='Hijacked'`);
  check('an operator cannot rename a machine', u.affectedRows === 0,
    `${u.affectedRows} rows`);

  const i = await db.query(
    `insert into machines (code, name, status) values ('X1','X','ACTIVE')`)
    .then(() => null).catch((e) => e.code);
  check('an operator cannot add a machine', i === '42501', `got ${i}`);

  const s = await db.query(`update app_settings set value='0'`);
  check('an operator cannot change a setting', s.affectedRows === 0,
    `${s.affectedRows} rows`);

  const p = await db.query(`update profiles set role='ADMIN'`);
  check('an operator cannot promote themselves', p.affectedRows === 0,
    `${p.affectedRows} rows`);
});

// =============================================================================
section('The mixture payload, in the exact shape the app sends');

// p_lines is jsonb. The app builds `[{raw_material_id, quantity}, ...]`, and a
// renamed key inside that array would not be caught by any signature check —
// the function would simply read null and raise a validation error on the floor.
//
// Material entry is admin-only (A30), so the operator is refused first and the
// rest of the contract runs as the administrator.
await asUser(db, RAVI_AUTH, async () => {
  const machine = (await db.query(`select id from machines where code='M1'`)).rows[0].id;
  const shift = (await db.query(`select id from shifts where name='Morning'`)).rows[0].id;
  const raizin = (await db.query(`select id from raw_materials where code='RM-RAIZIN'`)).rows[0].id;
  const state = await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [machine, shift, JSON.stringify([{ raw_material_id: raizin, quantity: 1 }]),
      randomUUID()]).then(() => null).catch((e) => e.code);
  check('an operator cannot record a material entry', state === 'DP004',
    `got ${state}`);
});

await asUser(db, ADMIN_AUTH, async () => {
  const machine = (await db.query(`select id from machines where code='M1'`)).rows[0].id;
  const shift = (await db.query(`select id from shifts where name='Morning'`)).rows[0].id;
  const raizin = (await db.query(`select id from raw_materials where code='RM-RAIZIN'`)).rows[0].id;
  const chem = (await db.query(`select id from raw_materials where code='RM-CHEM'`)).rows[0].id;

  const payload = JSON.stringify([
    { raw_material_id: raizin, quantity: 12.5 },
    { raw_material_id: chem, quantity: 2.5 },
  ]);

  try {
    const r = await db.query(
      `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
      [machine, shift, payload, randomUUID()]);
    check('consume_raw_materials accepts the app\'s line shape',
      Number(r.rows[0].j.total_quantity) === 15, JSON.stringify(r.rows[0].j));
  } catch (e) {
    check('consume_raw_materials accepts the app\'s line shape', false, e.message);
  }

  // The same reference twice must return the first entry, not create a second.
  const ref = randomUUID();
  const first = await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [machine, shift, payload, ref]);
  const again = await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [machine, shift, payload, ref]);
  check('a retried submission returns the batch already recorded',
    again.rows[0].j.duplicate === true && again.rows[0].j.id === first.rows[0].j.id);

  // The failure the screen is built around: everything or nothing.
  const before = Number((await db.query(
    `select quantity from raw_material_stock where raw_material_id=$1`, [raizin]
  )).rows[0].quantity);

  const short = await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [machine, shift, JSON.stringify([
      { raw_material_id: raizin, quantity: 5 },
      { raw_material_id: chem, quantity: 9999999 },
    ]), randomUUID()]).then(() => null).catch((e) => e.code);

  const after = Number((await db.query(
    `select quantity from raw_material_stock where raw_material_id=$1`, [raizin]
  )).rows[0].quantity);

  check('a batch short on one material is refused', short === 'DP001', `got ${short}`);
  check('and the other materials in it are untouched', before === after,
    `${before} -> ${after}`);
});

// The admin stock movements, with the app's parameter names bound by position.
await asUser(db, ADMIN_AUTH, async () => {
  const raizin = (await db.query(`select id from raw_materials where code='RM-RAIZIN'`)).rows[0].id;
  const ref = randomUUID();

  const a = await db.query(
    `select public.add_raw_material_stock($1,$2,$3,$4) as j`,
    [raizin, 500, ref, 'Invoice 42']);
  check('stock-in posts and reports the new balance',
    Number(a.rows[0].j.resulting_stock) > 0, JSON.stringify(a.rows[0].j));

  const b = await db.query(
    `select public.add_raw_material_stock($1,$2,$3,$4) as j`,
    [raizin, 500, ref, 'Invoice 42']);
  check('a retried stock-in does not post it twice',
    b.rows[0].j.duplicate === true, JSON.stringify(b.rows[0].j));

  const neg = await db.query(
    `select public.adjust_raw_material_stock($1,$2,$3,$4)`,
    [raizin, -999999, randomUUID(), 'Impossible']).then(() => null).catch((e) => e.code);
  check('an adjustment cannot drive stock below zero', neg === 'DP001', `got ${neg}`);
});

console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach((f) => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
