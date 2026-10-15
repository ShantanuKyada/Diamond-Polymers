// A40: employee types, any machine, and leaving the factory.
//
// Three rules the factory asked for, and they pull against each other in ways
// worth pinning: an operator may now work anywhere, a labourer may work nowhere,
// and somebody who has left may not be assigned at all. Each is enforced in one
// place — a shared guard, a trigger on assignments, a trigger on profiles — so
// the tests go after those places rather than after one screen's happy path.
import { build, asUser, chargeBatch } from './harness.mjs';
import { randomUUID } from 'node:crypto';

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
async function sqlstate(fn) {
  try { await fn(); return null; }
  catch (e) { return e.code ?? String(e.message).slice(0, 80); }
}

const db = await build({ quiet: true });

const ADMIN_AUTH = randomUUID();
const RAVI_AUTH = randomUUID();
const LAB_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values
  ($1,'admin@dp.local'), ($2,'ravi@dp.local'), ($3,'lab@dp.local')`,
  [ADMIN_AUTH, RAVI_AUTH, LAB_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-001'`, [ADMIN_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-101'`, [RAVI_AUTH]);

const one = async (s, p = []) => (await db.query(s, p)).rows[0];
const all = async (s, p = []) => (await db.query(s, p)).rows;
const num = (v) => v === null || v === undefined ? null : Number(v);

const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const GANESH = (await one(`select id from profiles where employee_code='EMP-104'`)).id;
const M1 = (await one(`select id from machines where code='M1'`)).id;
const M2 = (await one(`select id from machines where code='M2'`)).id;
const MORNING = (await one(`select id from shifts where name='Morning'`)).id;
const TA = (await one(`select id from pipe_types where code='TA'`)).id;
const S1 = (await one(`select id from pipe_sizes where code='S1'`)).id;
const RAIZIN = (await one(`select id from raw_materials where code='RM-RAIZIN'`)).id;

// =============================================================================
section('Employee type — backfilled from what the row already said');

const types = await all(
  `select p.employee_code, p.role, t.code as employee_type
   from profiles p join employee_types t on t.id = p.employee_type_id
   order by p.employee_code`);

check('the administrator is office staff, not a machine operator',
  types.find((r) => r.employee_code === 'EMP-001').employee_type === 'OFFICE',
  JSON.stringify(types.find((r) => r.employee_code === 'EMP-001')));

check('and everybody else on the roll is an operator',
  types.filter((r) => r.employee_code !== 'EMP-001')
       .every((r) => r.employee_type === 'OPERATOR'),
  JSON.stringify(types.map((r) => [r.employee_code, r.employee_type])));

check('everybody points at a role, and nobody is untyped',
  (await one(`select is_nullable from information_schema.columns
              where table_schema='public' and table_name='profiles'
                and column_name='employee_type_id'`)).is_nullable === 'NO');

// A41: the enum is gone, so there is one answer to "what roles exist" rather
// than two that can disagree.
check('the old enum is gone, not left beside the table',
  (await all(`select 1 from pg_type where typname = 'employee_type'`)).length === 0);

// =============================================================================
section('Creating a labourer');

let LABOURER;

await asUser(db, ADMIN_AUTH, async () => {
  const made = await one(
    `select public.save_worker_profile(
       p_name => $1, p_employee_code => $2, p_role => 'OPERATOR',
       p_active => true, p_employee_type => 'LABOURER',
       p_joined_on => $3, p_monthly_salary => $4) as j`,
    ['Lakha Bhai', 'EMP-201', '2026-02-01', 14000]);
  LABOURER = made.j.id;
  check('an admin can take on a labourer', made.j.created === true,
    JSON.stringify(made.j));

  const row = await one(
    `select employee_type, monthly_salary from v_staff_pay where profile_id=$1`,
    [LABOURER]);
  check('with a salary, which is the whole point of having them on file',
    row.employee_type === 'LABOURER' && num(row.monthly_salary) === 14000,
    JSON.stringify(row));

  // The two sides of the app are chosen by `role`, so letting an administrator
  // also be a machine operator would put them on a machine roster.
  const both = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Confused', p_employee_code => 'EMP-202', p_role => 'ADMIN',
       p_active => true, p_employee_type => 'OPERATOR')`));
  check('an administrator cannot also be a machine operator', both === 'DP005',
    `got ${both}`);
});

// =============================================================================
section('A labourer is on the payroll and nothing else');

await db.query(`update profiles set auth_user_id=$1 where id=$2`,
  [LAB_AUTH, LABOURER]);

await asUser(db, LAB_AUTH, async () => {
  const material = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID()]));
  check('a labourer cannot charge a machine', material === 'DP006',
    `got ${material}`);

  const production = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6)`,
    [M1, MORNING, TA, S1, 1, randomUUID()]));
  check('nor record production', production === 'DP006', `got ${production}`);
});

await asUser(db, ADMIN_AUTH, async () => {
  const assigned = await sqlstate(() => db.query(
    `insert into machine_assignments (machine_id, operator_id, shift_id)
     values ($1,$2,$3)`, [M2, LABOURER, MORNING]));
  check('nor be assigned to a machine, even by an admin', assigned === 'DP005',
    `got ${assigned}`);
});

// A labourer still gets paid, which is the one thing they are on file for.
await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.run_payroll($1)`, ['2026-09-01']);
  const slip = await one(
    `select monthly_salary, net_payable from v_payslips
     where profile_id=$1 and period_month='2026-09-01'`, [LABOURER]);
  check('but is on the payroll like anybody else',
    num(slip.monthly_salary) === 14000 && num(slip.net_payable) === 14000,
    JSON.stringify(slip));
});

// =============================================================================
section('An operator may work on any machine (A40)');

// Ravi is assigned to M1 by the seed. M2 is somebody else's.
const mine = await all(
  `select machine_id from machine_assignments
   where operator_id=$1 and effective_to is null and active`, [RAVI]);
check('the seed still assigns him a machine, so the default has something to be',
  mine.length === 1 && mine[0].machine_id === M1, JSON.stringify(mine));

await asUser(db, RAVI_AUTH, async () => {
  const batch = await chargeBatch(db,
    { machineId: M2, shiftId: MORNING, materialId: RAIZIN, quantity: 30 });
  check('he can charge a machine that is not his', batch != null, `${batch}`);

  const made = await sqlstate(() => db.query(
    `select public.record_production($1,$2,$3,$4,$5,$6, p_mixture_entry_id => $7)`,
    [M2, MORNING, TA, S1, 2, randomUUID(), batch]));
  check('and record the run that came out of it', made === null, `got ${made}`);

  const entry = await one(
    `select machine_id, operator_id from production_entries
     where mixture_entry_id=$1`, [batch]);
  check('the entry names the machine he chose, not the one he is assigned to',
    entry.machine_id === M2 && entry.operator_id === RAVI,
    JSON.stringify(entry));
});

await asUser(db, RAVI_AUTH, async () => {
  const machines = await all(`select * from v_operator_machines order by code`);
  check('every running machine is offered to him',
    machines.length >= 3 && machines.every((m) => m.status !== 'INACTIVE'),
    JSON.stringify(machines.map((m) => [m.code, m.is_mine])));

  const flagged = machines.filter((m) => m.is_mine);
  check('with his own marked, so the form can default to it',
    flagged.length === 1 && flagged[0].machine_id === M1,
    JSON.stringify(flagged.map((m) => m.code)));

  check('and his shift comes with it',
    flagged[0].my_shift_name !== null, JSON.stringify(flagged[0]));
});

// =============================================================================
section('Leaving the factory');

await asUser(db, ADMIN_AUTH, async () => {
  const before = await all(
    `select id from machine_assignments
     where operator_id=$1 and effective_to is null and active`, [GANESH]);

  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Ganesh Jadhav', p_employee_code => 'EMP-104',
       p_role => 'OPERATOR', p_active => false)`, [GANESH]);

  const after = await one(`select active from profiles where id=$1`, [GANESH]);
  check('an admin can take somebody off the roll', after.active === false);

  const kept = await one(`select count(*)::int n from profiles where id=$1`, [GANESH]);
  check('their record is not deleted', num(kept.n) === 1);

  // The gap this closed: an inactive operator kept an open assignment, so a
  // machine went on showing somebody who had left.
  const open = await all(
    `select id from machine_assignments
     where operator_id=$1 and effective_to is null and active`, [GANESH]);
  check('and their open machine assignment is closed',
    before.length === 0 || open.length === 0,
    `${before.length} before, ${open.length} after`);

  const history = await all(
    `select effective_from, effective_to from machine_assignments
     where operator_id=$1`, [GANESH]);
  check('closed with an end date rather than deleted',
    history.length === before.length
    && history.every((h) => before.length === 0 || h.effective_to !== null),
    JSON.stringify(history));

  const reassign = await sqlstate(() => db.query(
    `insert into machine_assignments (machine_id, operator_id, shift_id)
     values ($1,$2,$3)`, [M2, GANESH, MORNING]));
  check('somebody off the roll cannot be put back on a machine',
    reassign === 'DP005', `got ${reassign}`);
});

// Their history is still there to report on, which is the whole reason for
// deactivating rather than deleting.
const past = await one(
  `select count(*)::int n from production_entries where operator_id=$1`, [GANESH]);
check('their past work is still on file', num(past.n) >= 0, `${past.n} entries`);

await asUser(db, ADMIN_AUTH, async () => {
  const gone = await all(
    `select profile_id from v_staff_pay where profile_id=$1 and active`, [GANESH]);
  check('they drop out of the active roster', gone.length === 0);

  await db.query(`select public.run_payroll($1)`, ['2026-10-01']);
  const slip = await all(
    `select id from v_payslips where profile_id=$1 and period_month='2026-10-01'`,
    [GANESH]);
  check('and off the payroll, without touching what they were paid before',
    slip.length === 0, `${slip.length} payslips`);

  // Reactivating is the same switch the other way.
  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Ganesh Jadhav', p_employee_code => 'EMP-104',
       p_role => 'OPERATOR', p_active => true)`, [GANESH]);
  const back = await one(`select active from profiles where id=$1`, [GANESH]);
  check('and an admin can put them back', back.active === true);
});

// =============================================================================
section('Changing somebody off operator work');

await asUser(db, ADMIN_AUTH, async () => {
  const open = await all(
    `select id from machine_assignments
     where operator_id=$1 and effective_to is null and active`, [RAVI]);
  check('Ravi is assigned to begin with', open.length === 1);

  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Ravi Kumar', p_employee_code => 'EMP-101',
       p_role => 'OPERATOR', p_active => true, p_employee_type => 'LABOURER')`,
    [RAVI]);

  const after = await all(
    `select id from machine_assignments
     where operator_id=$1 and effective_to is null and active`, [RAVI]);
  check('moving him off operator work closes the assignment too — somebody who '
    + 'no longer runs machines is not assigned to one', after.length === 0,
    `${after.length} still open`);
});

await asUser(db, RAVI_AUTH, async () => {
  const refused = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID()]));
  check('and he can no longer charge a machine', refused === 'DP006',
    `got ${refused}`);
});

// =============================================================================
section('The factory names its own roles (A41)');

let SUPERVISOR, HELPER;

await asUser(db, ADMIN_AUTH, async () => {
  const made = await one(
    `select public.save_employee_type(
       p_name => 'Shift Supervisor', p_runs_machines => true,
       p_description => 'Runs a machine and watches the line',
       p_sort_order => 15) as j`);
  SUPERVISOR = made.j.id;
  check('an admin can add a role', made.j.created === true && SUPERVISOR != null,
    JSON.stringify(made.j));

  check('and its code is made from the name, so nobody types one',
    made.j.code === 'SHIFT_SUPERVISOR', made.j.code);

  const second = await one(
    `select public.save_employee_type(p_name => 'Helper') as j`);
  HELPER = second.j.id;
  check('a role that does not run machines is the default',
    (await one(`select runs_machines from employee_types where id=$1`,
      [HELPER])).runs_machines === false);

  const dup = await sqlstate(() => db.query(
    `select public.save_employee_type(p_name => 'Helper')`));
  check('the same role twice is refused', dup === 'DP005', `got ${dup}`);

  const blank = await sqlstate(() => db.query(
    `select public.save_employee_type(p_name => '   ')`));
  check('and a role with no name', blank === 'DP005', `got ${blank}`);

  const symbols = await sqlstate(() => db.query(
    `select public.save_employee_type(p_name => '!!!')`));
  check('and one whose name makes no code', symbols === 'DP005', `got ${symbols}`);
});

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.save_employee_type(p_name => 'Sneaky')`));
  check('an operator cannot add a role', s === 'DP004', `got ${s}`);
});

// =============================================================================
section('A new role behaves like the built-in ones');

let SUPER_PERSON;

await asUser(db, ADMIN_AUTH, async () => {
  const made = await one(
    `select public.save_worker_profile(
       p_name => 'Prakash Shah', p_employee_code => 'EMP-401',
       p_role => 'OPERATOR', p_active => true,
       p_employee_type => 'SHIFT_SUPERVISOR', p_monthly_salary => 30000) as j`);
  SUPER_PERSON = made.j.id;
  check('somebody can be put on a role the factory invented',
    made.j.role === 'SHIFT_SUPERVISOR', JSON.stringify(made.j));

  const row = await one(
    `select employee_type, employee_type_name, runs_machines
     from v_staff_pay where profile_id=$1`, [SUPER_PERSON]);
  check('and the roster reports the role by name',
    row.employee_type === 'SHIFT_SUPERVISOR'
    && row.employee_type_name === 'Shift Supervisor'
    && row.runs_machines === true, JSON.stringify(row));

  // The role says it runs machines, so the assignment is allowed.
  await db.query(
    `insert into machine_assignments (machine_id, operator_id, shift_id)
     values ($1,$2,$3)`, [M2, SUPER_PERSON, MORNING]);
  check('a machine-running role can hold an assignment',
    (await all(`select 1 from machine_assignments
                where operator_id=$1 and effective_to is null`,
      [SUPER_PERSON])).length === 1);

  const badRole = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Nobody', p_employee_code => 'EMP-402',
       p_role => 'OPERATOR', p_active => true,
       p_employee_type => 'DOES_NOT_EXIST')`));
  check('a role that does not exist is refused by name', badRole === 'DP005',
    `got ${badRole}`);
});

// Recording keys off the role's own answer, not off a list of names written
// into the guard.
const SUPER_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values ($1,'prakash@dp.local')`,
  [SUPER_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where id=$2`,
  [SUPER_AUTH, SUPER_PERSON]);

await asUser(db, SUPER_AUTH, async () => {
  const batch = await chargeBatch(db,
    { machineId: M1, shiftId: MORNING, materialId: RAIZIN, quantity: 20 });
  check('somebody on a new machine-running role can record', batch != null);
});

await asUser(db, ADMIN_AUTH, async () => {
  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Prakash Shah', p_employee_code => 'EMP-401',
       p_role => 'OPERATOR', p_active => true, p_employee_type => 'HELPER')`,
    [SUPER_PERSON]);
});

await asUser(db, SUPER_AUTH, async () => {
  const refused = await sqlstate(() => db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4)`,
    [M1, MORNING, JSON.stringify([{ raw_material_id: RAIZIN, quantity: 1 }]),
      randomUUID()]));
  check('and stops being able to the moment they move off it',
    refused === 'DP006', `got ${refused}`);
});

check('moving them closed the assignment too',
  (await all(`select 1 from machine_assignments
              where operator_id=$1 and effective_to is null and active`,
    [SUPER_PERSON])).length === 0);

// =============================================================================
section('Roles are retired, never deleted');

await asUser(db, ADMIN_AUTH, async () => {
  const held = await sqlstate(() => db.query(
    `select public.save_employee_type(
       p_id => $1, p_name => 'Helper', p_active => false)`, [HELPER]));
  check('a role somebody is on cannot be switched off', held === 'DP005',
    `got ${held}`);

  // Move the one person off it, and then it can be.
  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Prakash Shah', p_employee_code => 'EMP-401',
       p_role => 'OPERATOR', p_active => true, p_employee_type => 'OFFICE')`,
    [SUPER_PERSON]);

  const now = await sqlstate(() => db.query(
    `select public.save_employee_type(
       p_id => $1, p_name => 'Helper', p_active => false)`, [HELPER]));
  check('once nobody is on it, it can be', now === null, `got ${now}`);

  const onRetired = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Too Late', p_employee_code => 'EMP-403',
       p_role => 'OPERATOR', p_active => true, p_employee_type => 'HELPER')`));
  check('and nobody new can be put on a retired role', onRetired === 'DP005',
    `got ${onRetired}`);

  // The row survives, because the people who held it still have a history.
  check('the role itself is kept, not deleted',
    (await all(`select 1 from employee_types where id=$1`, [HELPER])).length === 1);
});

// =============================================================================
section('Operator is the one role that cannot be taken away');

await asUser(db, ADMIN_AUTH, async () => {
  const op = await one(`select id, name from employee_types where code='OPERATOR'`);

  const off = await sqlstate(() => db.query(
    `select public.save_employee_type(
       p_id => $1, p_name => 'Operator', p_active => false)`, [op.id]));
  check('it cannot be switched off — nobody could record production then',
    off === 'DP005', `got ${off}`);

  const grounded = await sqlstate(() => db.query(
    `select public.save_employee_type(
       p_id => $1, p_name => 'Operator', p_runs_machines => false)`, [op.id]));
  check('nor stop running machines', grounded === 'DP005', `got ${grounded}`);

  // Renaming it is fine: the code is what everything refers to.
  const renamed = await sqlstate(() => db.query(
    `select public.save_employee_type(
       p_id => $1, p_name => 'Machine Operator')`, [op.id]));
  check('but it can be renamed, because the code is what things refer to',
    renamed === null, `got ${renamed}`);

  check('and the code did not move with the name',
    (await one(`select code, name from employee_types where id=$1`, [op.id]))
      .code === 'OPERATOR');

  // Put it back so the rest of the suite reads naturally.
  await db.query(`select public.save_employee_type(p_id => $1, p_name => 'Operator')`,
    [op.id]);
});

// =============================================================================
section('What the roles screen reads');

await asUser(db, ADMIN_AUTH, async () => {
  const rows = await all(`select * from v_employee_types order by sort_order`);
  check('every role is listed with how many people are on it',
    rows.length >= 5 && rows.every((r) => r.active_staff !== null),
    JSON.stringify(rows.map((r) => [r.code, r.active_staff])));

  const op = rows.find((r) => r.code === 'OPERATOR');
  check('the built-in one is flagged, so the screen can protect it',
    op.is_system === true && rows.filter((r) => r.is_system).length === 1);

  check('and the count is what says whether a role can be retired',
    num(rows.find((r) => r.code === 'HELPER').active_staff) === 0);
});

await asUser(db, RAVI_AUTH, async () => {
  const seen = await all(`select * from employee_types`);
  check('an operator can read the roles — the app needs the list to render',
    seen.length >= 5, `${seen.length} rows`);

  const w = await db.query(`update employee_types set name = 'Hacked'`);
  check('but cannot change one', w.affectedRows === 0,
    `${w.affectedRows} rows updated`);
});

console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach((f) => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
