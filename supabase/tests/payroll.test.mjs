// Phase 8: attendance and payroll.
//
// Kept in its own file because the failure mode is different from the rest of
// the system. A stock bug shows up as a number that looks wrong; a payroll bug
// shows up as somebody being paid the wrong amount, and nobody notices until
// they complain.
import { build, asUser } from './harness.mjs';
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
const SURESH_AUTH = randomUUID();
await db.query(`insert into auth.users (id, email) values
  ($1,'admin@dp.local'), ($2,'ravi@dp.local'), ($3,'suresh@dp.local')`,
  [ADMIN_AUTH, RAVI_AUTH, SURESH_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-001'`, [ADMIN_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-101'`, [RAVI_AUTH]);
await db.query(`update profiles set auth_user_id=$1 where employee_code='EMP-102'`, [SURESH_AUTH]);

const one = async (s, p = []) => (await db.query(s, p)).rows[0];
const all = async (s, p = []) => (await db.query(s, p)).rows;
const num = (v) => v === null || v === undefined ? null : Number(v);
// A `date` arrives as a JS Date, whose toString() is local and unhelpful. Every
// date assertion below compares the calendar day, which is what was stored.
const day = (v) => v === null || v === undefined
  ? null
  : new Date(v).toISOString().slice(0, 10);

const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const SURESH = (await one(`select id from profiles where employee_code='EMP-102'`)).id;

// June 2026: a completed month, chosen so nothing collides with today's date.
const MONTH = '2026-06-01';
const SALARY = 26000;

// =============================================================================
section('Salary structure — effective dated, never overwritten');

await asUser(db, ADMIN_AUTH, async () => {
  const r = await one(`select public.set_salary_structure($1,$2,$3) as j`,
    [RAVI, SALARY, '2026-01-01']);
  check('an admin can set a salary', num(r.j.monthly_salary) === SALARY, JSON.stringify(r.j));

  await db.query(`select public.set_salary_structure($1,$2,$3)`, [SURESH, 21000, '2026-01-01']);

  // A raise must close the old period, not edit it.
  const raise = await one(`select public.set_salary_structure($1,$2,$3) as j`,
    [RAVI, 30000, '2026-08-01']);
  check('a raise closes the previous period rather than editing it',
    raise.j.previous_closed !== null, JSON.stringify(raise.j));

  const rows = await all(
    `select monthly_salary, effective_from, effective_to from salary_structures
     where profile_id=$1 order by effective_from`, [RAVI]);
  check('the old rate is kept with an end date',
    rows.length === 2 && num(rows[0].monthly_salary) === SALARY
    && rows[0].effective_to !== null && rows[1].effective_to === null,
    JSON.stringify(rows));

  const back = await sqlstate(() => db.query(
    `select public.set_salary_structure($1,$2,$3)`, [RAVI, 40000, '2026-07-01']));
  check('a change cannot start before the period already open', back === 'DP005', `got ${back}`);
});

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.set_salary_structure($1,$2)`, [RAVI, 99000]));
  check('an operator cannot set their own salary', s === 'DP004', `got ${s}`);
});

// =============================================================================
section('Attendance — punches, night shifts, corrections');

await asUser(db, RAVI_AUTH, async () => {
  const a = await one(`select public.punch_in($1,$2,null,$3) as j`,
    [RAVI, '2026-06-01T06:00:00+05:30', '2026-06-01']);
  check('an operator can punch themselves in', a.j.duplicate === false);

  const dup = await one(`select public.punch_in($1,$2,null,$3) as j`,
    [RAVI, '2026-06-01T06:05:00+05:30', '2026-06-01']);
  check('punching in twice is a double tap, not a second shift',
    dup.j.duplicate === true, JSON.stringify(dup.j));

  const out = await one(`select public.punch_out($1,$2,$3) as j`,
    [RAVI, '2026-06-01T14:30:00+05:30', '2026-06-01']);
  check('worked hours are derived from the punch pair',
    num(out.j.worked_hours) === 8.5, JSON.stringify(out.j));

  const s = await sqlstate(() => db.query(`select public.punch_in($1,$2,null,$3)`,
    [SURESH, '2026-06-01T06:00:00+05:30', '2026-06-01']));
  check('an operator cannot punch a colleague in', s === 'DP004', `got ${s}`);
});

// A night shift starts on one calendar day and ends on the next. It must stay
// one attendance row on the day it started (A16).
await asUser(db, RAVI_AUTH, async () => {
  await db.query(`select public.punch_in($1,$2,null,$3)`,
    [RAVI, '2026-06-02T22:00:00+05:30', '2026-06-02']);
  const out = await one(`select public.punch_out($1,$2) as j`,
    [RAVI, '2026-06-03T06:00:00+05:30']);
  check('a night shift punched out after midnight closes the same row',
    num(out.j.worked_hours) === 8, JSON.stringify(out.j));
});
const nightRows = await all(
  `select work_date, worked_hours from attendance_days
   where profile_id=$1 and work_date in ('2026-06-02','2026-06-03')`, [RAVI]);
check('and does not open a second row on the next day',
  nightRows.length === 1 && num(nightRows[0].worked_hours) === 8,
  JSON.stringify(nightRows));

await asUser(db, ADMIN_AUTH, async () => {
  for (const d of ['2026-06-10', '2026-06-11', '2026-06-12']) {
    await db.query(`select public.set_attendance($1,$2,'ABSENT')`, [RAVI, d]);
  }
  const marked = await one(
    `select count(*)::int n from attendance_days where profile_id=$1 and status='ABSENT'`, [RAVI]);
  check('an admin can mark absences', num(marked.n) === 3);

  // Correcting a mis-punch to "absent" must clear the punches, not be refused.
  await db.query(`select public.set_attendance($1,'2026-06-01','ABSENT')`, [RAVI]);
  const cleared = await one(
    `select status, punch_in_at, punch_out_at from attendance_days
     where profile_id=$1 and work_date='2026-06-01'`, [RAVI]);
  check('marking a punched day absent clears its punches',
    cleared.status === 'ABSENT' && cleared.punch_in_at === null,
    JSON.stringify(cleared));

  // Put it back and give the month 4 hours of overtime.
  await db.query(`select public.set_attendance($1,'2026-06-01','PRESENT',$2,$3,4)`,
    [RAVI, '2026-06-01T06:00:00+05:30', '2026-06-01T14:30:00+05:30']);
});

// =============================================================================
section('Advances — a money ledger, same discipline as stock');

const advRef = randomUUID();
await asUser(db, ADMIN_AUTH, async () => {
  const a = await one(`select public.issue_salary_advance($1,$2,$3) as j`, [RAVI, 5000, advRef]);
  check('an advance can be issued', num(a.j.outstanding) === 5000, JSON.stringify(a.j));

  const again = await one(`select public.issue_salary_advance($1,$2,$3) as j`, [RAVI, 5000, advRef]);
  check('a retried advance does not hand out the money twice',
    again.j.duplicate === true && num(again.j.outstanding) === 5000, JSON.stringify(again.j));

  const bad = await sqlstate(() => db.query(
    `select public.issue_salary_advance($1,$2,$3)`, [RAVI, -100, randomUUID()]));
  check('a negative advance is refused', bad === 'DP005', `got ${bad}`);
});

const advLedger = await all(
  `select amount, previous_outstanding, resulting_outstanding from advance_transactions
   where profile_id=$1`, [RAVI]);
check('the advance ledger records previous and resulting outstanding',
  advLedger.length === 1 && num(advLedger[0].previous_outstanding) === 0
  && num(advLedger[0].resulting_outstanding) === 5000);

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.issue_salary_advance($1,$2,$3)`, [RAVI, 1000, randomUUID()]));
  check('an operator cannot issue themselves an advance', s === 'DP004', `got ${s}`);
});

// =============================================================================
section('Payroll — salary, less what was taken');

await asUser(db, ADMIN_AUTH, async () => {
  const bonus = await sqlstate(() => db.query(
    `select public.add_staff_adjustment($1,$2,'BONUS','Festival bonus',$3,$4)`,
    [RAVI, MONTH, 500, randomUUID()]));
  check('nothing can be added to a salary any more', bonus === 'DP005', `got ${bonus}`);

  await db.query(`select public.add_staff_adjustment($1,$2,'DEDUCTION','Canteen',$3,$4)`,
    [RAVI, MONTH, 200, randomUUID()]);

  const r = await one(`select public.run_payroll($1) as j`, [MONTH]);
  check('payroll runs and produces a payslip per person with a salary',
    num(r.j.payslips) === 2, JSON.stringify(r.j));
});

const slip = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`, [RAVI, MONTH]);

// Ravi was marked absent for three days of June and worked four hours of
// overtime. Under the old engine that made his basic 23400 and added 1000 of
// overtime. Neither moves the figure now: the month's salary is the month's
// salary (A38).
check('a month pays the monthly salary, whatever the attendance says',
  num(slip.monthly_salary) === SALARY, `${slip.monthly_salary}`);

check('a deduction entered by hand subtracts',
  num(slip.deductions_amount) === 200, `${slip.deductions_amount}`);

check('the outstanding advance is recovered',
  num(slip.advance_recovered) === 5000, `${slip.advance_recovered}`);

check('net is the salary less the deduction and the advance',
  num(slip.net_payable) === SALARY - 200 - 5000, `${slip.net_payable}`);

// The columns the old engine needed are gone, not merely unused. A later
// migration that wants proration back has to add them deliberately.
const gone = await all(
  `select column_name from information_schema.columns
   where table_schema='public' and table_name='payslips'
     and column_name in ('basic_amount','gross_amount','overtime_amount',
                         'additions_amount','payable_days','present_days',
                         'absent_days','calendar_days','overtime_hours',
                         'overtime_rate_per_hour')`);
check('the proration and overtime columns are gone from payslips', gone.length === 0,
  JSON.stringify(gone.map(r => r.column_name)));

const settingsGone = await all(
  `select key from app_settings where key in
    ('payroll_fixed_days','payroll_overtime_multiplier',
     'payroll_proration_basis','payroll_unmarked_day_policy')`);
check('and the settings that drove them are gone too', settingsGone.length === 0,
  JSON.stringify(settingsGone.map(r => r.key)));

const comps = await all(
  `select component_type, amount from payslip_components where payslip_id=$1 order by sort_order`,
  [slip.id]);
const compSum = comps.reduce((a, c) => a + num(c.amount), 0);
check('the itemised lines add up to net pay',
  Math.abs(compSum - (SALARY - 200 - 5000)) < 0.01,
  `${compSum} from ${JSON.stringify(comps.map(c => [c.component_type, c.amount]))}`);

// Suresh has no attendance marked at all for June. He is paid in full, which is
// now the ordinary case rather than a policy setting.
const sureshSlip = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`, [SURESH, MONTH]);
check('somebody with no attendance marked is paid in full',
  num(sureshSlip.net_payable) === 21000, `${sureshSlip.net_payable}`);

// A deduction bigger than the salary is somebody's slip of the keyboard. It has
// to be a sentence naming the person, not a constraint violation.
await asUser(db, ADMIN_AUTH, async () => {
  const ref = randomUUID();
  const typo = await one(
    `select public.add_staff_adjustment($1,$2,'DEDUCTION','Typo',$3,$4) as j`,
    [SURESH, MONTH, 99000, ref]);
  const over = await sqlstate(() => db.query(`select public.run_payroll($1)`, [MONTH]));
  check('deductions larger than the salary are refused by name', over === 'DP005', `got ${over}`);

  // And can be taken back, which is the whole reason removal exists: a mistyped
  // deduction otherwise stops the month's payroll and nothing can clear it.
  const undo = await one(`select public.remove_staff_adjustment($1) as j`, [typo.j.id]);
  check('a mistyped deduction can be taken back', undo.j.removed === true,
    JSON.stringify(undo.j));

  const twice = await one(`select public.remove_staff_adjustment($1) as j`, [typo.j.id]);
  check('removing it twice is not an error', twice.j.removed === false,
    JSON.stringify(twice.j));

  await db.query(`select public.run_payroll($1)`, [MONTH]);
});

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(`select public.remove_staff_adjustment($1)`,
    [randomUUID()]));
  check('an operator cannot remove a deduction', s === 'DP004', `got ${s}`);
});

// =============================================================================
section('The two numbers the factory works from');

await asUser(db, ADMIN_AUTH, async () => {
  const pay = await all(`select * from v_staff_pay order by employee_code`);
  const ravi = pay.find(r => r.profile_id === RAVI);
  const suresh = pay.find(r => r.profile_id === SURESH);
  check('v_staff_pay lists everyone with their salary and what they have drawn',
    pay.length >= 2 && num(suresh.monthly_salary) === 21000
    && num(ravi.outstanding_advance) === 5000,
    JSON.stringify({ suresh, ravi }));

  // A raise dated ahead of today is not what somebody is on today. Dated far
  // enough out that the assertion does not depend on when the suite is run.
  await db.query(`select public.set_salary_structure($1,$2,$3)`, [SURESH, 25000, '2099-01-01']);
  const later = (await all(`select * from v_staff_pay where profile_id=$1`, [SURESH]))[0];
  check('a raise dated ahead is reported apart from the current salary',
    num(later.monthly_salary) === 21000 && num(later.upcoming_salary) === 25000,
    JSON.stringify(later));

  const ded = await all(`select * from v_staff_deductions where period_month=$1`, [MONTH]);
  check('v_staff_deductions shows the deductions waiting on a payslip',
    ded.length === 1 && ded[0].label === 'Canteen' && num(ded[0].amount) === 200,
    JSON.stringify(ded));
});

await asUser(db, RAVI_AUTH, async () => {
  const pay = await all(`select * from v_staff_pay`);
  check('a worker sees their own pay row and nobody else\'s',
    pay.length === 1 && pay[0].profile_id === RAVI, `${pay.length} rows`);

  const ded = await all(`select * from v_staff_deductions`);
  check('and cannot see the deductions ledger', ded.length === 0, `${ded.length} rows`);
});

// =============================================================================
section('Payroll — recalculating a draft must not recover twice');

const beforeRecalc = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [RAVI])).outstanding);

await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.run_payroll($1)`, [MONTH]);
  await db.query(`select public.run_payroll($1)`, [MONTH]);
});

const afterRecalc = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [RAVI])).outstanding);
check('calculating a draft never touches the advance ledger',
  beforeRecalc === 5000 && afterRecalc === 5000, `${beforeRecalc} -> ${afterRecalc}`);

const slipCount = num((await one(
  `select count(*)::int n from payslips p join payroll_periods pp on pp.id=p.payroll_period_id
   where pp.period_month=$1`, [MONTH])).n);
check('recalculating replaces the payslips rather than duplicating them', slipCount === 2,
  `${slipCount} payslips`);

// =============================================================================
section('Payroll — finalising');

await asUser(db, ADMIN_AUTH, async () => {
  const f = await one(`select public.finalise_payroll($1) as j`, [MONTH]);
  check('finalising posts the advance recoveries',
    f.j.duplicate === false && num(f.j.recoveries_posted) === 1, JSON.stringify(f.j));
});

const afterFinal = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [RAVI])).outstanding);
check('and the advance is now cleared', afterFinal === 0, `${afterFinal}`);

const recTxn = await all(
  `select transaction_type, amount, previous_outstanding, resulting_outstanding
   from advance_transactions where profile_id=$1 order by created_at`, [RAVI]);
check('the recovery is a ledger row that explains the balance',
  recTxn.length === 2 && num(recTxn[1].amount) === -5000
  && num(recTxn[1].resulting_outstanding) === 0,
  JSON.stringify(recTxn));

await asUser(db, ADMIN_AUTH, async () => {
  const again = await one(`select public.finalise_payroll($1) as j`, [MONTH]);
  check('finalising twice is idempotent, not a second recovery',
    again.j.duplicate === true, JSON.stringify(again.j));

  const recalc = await sqlstate(() => db.query(`select public.run_payroll($1)`, [MONTH]));
  check('a finalised month cannot be recalculated', recalc === 'DP011', `got ${recalc}`);

  const late = await sqlstate(() => db.query(
    `select public.add_staff_adjustment($1,$2,'DEDUCTION','Late',$3,$4)`,
    [RAVI, MONTH, 100, randomUUID()]));
  check('and cannot take new deductions', late === 'DP011', `got ${late}`);

  const canteen = await one(
    `select id from staff_adjustments where profile_id=$1 and period_month=$2`, [RAVI, MONTH]);
  const lateRemove = await sqlstate(() => db.query(
    `select public.remove_staff_adjustment($1)`, [canteen.id]));
  check('nor can an existing one be taken back once paid', lateRemove === 'DP011',
    `got ${lateRemove}`);
});

const stillZero = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [RAVI])).outstanding);
check('the second finalise moved no money', stillZero === 0, `${stillZero}`);

// =============================================================================
section('Payroll — advance recovery cannot push pay negative');

await asUser(db, ADMIN_AUTH, async () => {
  // Somebody who has drawn far more than a month's pay.
  await db.query(`select public.issue_salary_advance($1,$2,$3)`, [SURESH, 100000, randomUUID()]);
  await db.query(`select public.run_payroll($1)`, ['2026-07-01']);
});

const big = await one(
  `select * from v_payslips where profile_id=$1 and period_month='2026-07-01'`, [SURESH]);
check('recovery is capped at a month\'s salary',
  num(big.net_payable) === 0 && num(big.advance_recovered) === num(big.monthly_salary),
  JSON.stringify({ net: big.net_payable, rec: big.advance_recovered, sal: big.monthly_salary }));

await asUser(db, ADMIN_AUTH, () => db.query(`select public.finalise_payroll($1)`, ['2026-07-01']));
const carried = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [SURESH])).outstanding);
check('the rest of the advance carries forward to next month',
  carried === 100000 - num(big.monthly_salary), `${carried}`);

// =============================================================================
section('Privacy — pay is nobody else\'s business');

await asUser(db, RAVI_AUTH, async () => {
  const mine = await all(`select * from v_payslips`);
  check('an operator sees only their own payslips',
    mine.length > 0 && mine.every(r => r.profile_id === RAVI),
    `${mine.length} rows, ids ${JSON.stringify([...new Set(mine.map(r => r.profile_id))])}`);

  const sal = await all(`select * from salary_structures`);
  check('an operator sees only their own salary structure',
    sal.every(r => r.profile_id === RAVI), `${sal.length} rows`);

  const adv = await all(`select * from staff_advance_balance`);
  check('an operator sees only their own advance balance',
    adv.every(r => r.profile_id === RAVI), `${adv.length} rows`);

  const att = await all(`select * from v_attendance_days`);
  check('an operator sees only their own attendance',
    att.every(r => r.profile_id === RAVI), `${att.length} rows`);

  const adj = await all(`select * from staff_adjustments`);
  check('an operator cannot read the adjustments ledger at all', adj.length === 0,
    `${adj.length} rows visible`);

  // A worker can see the months they were paid in — their payslip view joins
  // the period — but nothing about months they were not part of.
  const per = await all(`select * from payroll_periods`);
  const myPeriods = new Set(mine.map(r => r.payroll_period_id));
  check('an operator sees only periods they have a payslip in',
    per.length > 0 && per.every(p => myPeriods.has(p.id)),
    `${per.length} rows`);

  const summary = await all(`select * from v_payroll_summary`);
  check('an operator cannot read factory-wide payroll totals', summary.length === 0,
    `${summary.length} rows`);

  const comp = await all(`select * from payslip_components`);
  const mineIds = new Set(mine.map(r => r.id));
  check('an operator sees only the lines of their own payslips',
    comp.length > 0 && comp.every(c => mineIds.has(c.payslip_id)));

  const w = await db.query(`update payslips set net_payable = 999999`);
  check('an operator cannot rewrite a payslip', w.affectedRows === 0,
    `${w.affectedRows} rows updated`);
});

await asUser(db, ADMIN_AUTH, async () => {
  const allSlips = await all(`select * from v_payslips`);
  check('an admin sees every payslip', allSlips.length >= 3, `${allSlips.length} rows`);

  const d = await db.query(`delete from payslips`);
  check('not even an admin can delete a payslip directly', d.affectedRows === 0,
    `${d.affectedRows} deleted`);
});

// =============================================================================
section('Payroll summary');

await asUser(db, ADMIN_AUTH, async () => {
  const s = await one(`select * from v_payroll_summary where period_month=$1`, [MONTH]);
  check('the summary totals the month',
    num(s.payslip_count) === 2
    && num(s.salary_total) === SALARY + 21000
    && num(s.deductions_total) === 200
    && num(s.net_total) === (SALARY - 200 - 5000) + 21000
    && s.status === 'FINALISED',
    JSON.stringify(s));

  // Attendance is still recorded and still rolls up. It simply no longer
  // decides what anybody is paid.
  const att = await one(
    `select * from v_monthly_attendance where profile_id=$1 and period_month=$2`, [RAVI, MONTH]);
  check('attendance is still kept, it just no longer pays',
    num(att.absent_days) === 3 && num(att.overtime_hours) === 4, JSON.stringify(att));
});

// =============================================================================
section('Worker profiles — created and edited by an admin');

let WORKER_A;

await asUser(db, ADMIN_AUTH, async () => {
  // Called with named arguments, which is how PostgREST calls it: the app
  // supplies a subset and the defaults fill the rest.
  const made = await one(
    `select public.save_worker_profile(
       p_name => $1, p_employee_code => $2, p_role => 'OPERATOR',
       p_active => true, p_phone => $3, p_joined_on => $4,
       p_salary_day => $5::smallint, p_monthly_salary => $6,
       p_salary_from => $4) as j`,
    ['Worker A', 'EMP-901', '9876543210', '2026-07-01', 7, 5000]);
  WORKER_A = made.j.id;
  check('an admin can create a worker with a salary in one go',
    made.j.created === true && WORKER_A != null, JSON.stringify(made.j));

  const row = await one(
    `select * from v_staff_pay where profile_id = $1`, [WORKER_A]);
  check('the profile carries the joining date, salary day and salary',
    row.staff_name === 'Worker A' && num(row.monthly_salary) === 5000
    && num(row.salary_day) === 7
    && day(row.joined_on) === '2026-07-01',
    JSON.stringify(row));

  // The salary lives in an effective-dated table, so the first one starts on
  // the joining date rather than on whatever day the form was filled in.
  const first = await one(
    `select effective_from, monthly_salary from salary_structures
     where profile_id = $1`, [WORKER_A]);
  check('the first salary starts on the joining date',
    day(first.effective_from) === '2026-07-01', JSON.stringify(first));

  const dup = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Someone Else', p_employee_code => 'EMP-901',
       p_role => 'OPERATOR', p_active => true)`));
  check('a worker ID already in use is refused', dup === 'DP005', `got ${dup}`);

  const future = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Time Traveller', p_employee_code => 'EMP-902',
       p_role => 'OPERATOR', p_active => true,
       p_joined_on => (current_date + 30))`));
  check('a joining date in the future is refused', future === 'DP005', `got ${future}`);

  const badDay = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Bad Day', p_employee_code => 'EMP-903',
       p_role => 'OPERATOR', p_active => true, p_salary_day => 32::smallint)`));
  check('a salary day outside a month is refused', badDay === 'DP005', `got ${badDay}`);

  // Editing the profile without touching the salary must not write a new
  // salary row — that would litter the history and hide a real raise.
  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Worker A', p_employee_code => 'EMP-901',
       p_role => 'OPERATOR', p_active => true, p_phone => '9000000000',
       p_joined_on => '2026-07-01', p_salary_day => 10::smallint,
       p_monthly_salary => 5000)`, [WORKER_A]);

  const unchanged = num((await one(
    `select count(*)::int n from salary_structures where profile_id=$1`,
    [WORKER_A])).n);
  check('re-saving the same salary writes no new salary row', unchanged === 1,
    `${unchanged} rows`);

  const edited = await one(`select phone, salary_day from profiles where id=$1`,
    [WORKER_A]);
  check('but the profile edits land',
    edited.phone === '9000000000' && num(edited.salary_day) === 10,
    JSON.stringify(edited));

  // Put the salary day back to the 7th for the worked example below.
  await db.query(
    `select public.save_worker_profile(
       p_id => $1, p_name => 'Worker A', p_employee_code => 'EMP-901',
       p_role => 'OPERATOR', p_active => true, p_phone => '9000000000',
       p_joined_on => '2026-07-01', p_salary_day => 7::smallint)`, [WORKER_A]);
});

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.save_worker_profile(
       p_name => 'Sneaky', p_employee_code => 'EMP-999',
       p_role => 'ADMIN', p_active => true)`));
  check('an operator cannot create a worker', s === 'DP004', `got ${s}`);
});

// =============================================================================
section("The factory's worked example: 5000, 2000 taken, 3000 paid");

// "Worker A has a monthly salary of 5000 and receives a 2000 advance during the
//  month. The system should display Monthly Salary 5000, Advance Paid 2000,
//  Remaining Salary 3000. When the salary date arrives, the admin can record
//  the remaining 3000 payment, completing that month's salary."
const AUG = '2026-08-01';

await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.issue_salary_advance($1,$2,$3,$4)`,
    [WORKER_A, 2000, randomUUID(), '2026-08-10']);
  await db.query(`select public.run_payroll($1)`, [AUG]);
});

let slipA = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`,
  [WORKER_A, AUG]);

check('the three figures the factory asked to see',
  num(slipA.monthly_salary) === 5000
  && num(slipA.advance_recovered) === 2000
  && num(slipA.net_payable) === 3000,
  JSON.stringify({ salary: slipA.monthly_salary, advance: slipA.advance_recovered,
                   remaining: slipA.net_payable }));

check('salary falls due on their own salary day',
  day(slipA.salary_due_on) === '2026-08-07', `${slipA.salary_due_on}`);

check('a draft says so rather than reading as unpaid',
  slipA.payment_status === 'DRAFT', slipA.payment_status);

await asUser(db, ADMIN_AUTH, async () => {
  const early = await sqlstate(() => db.query(
    `select public.record_salary_payment($1,$2,$3)`, [slipA.id, 3000, randomUUID()]));
  check('and cannot be paid against, because its figures can still move',
    early === 'DP005', `got ${early}`);

  await db.query(`select public.finalise_payroll($1)`, [AUG]);
});

slipA = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`,
  [WORKER_A, AUG]);
check('once finalised it is owed in full', slipA.payment_status === 'UNPAID'
  && num(slipA.outstanding) === 3000 && num(slipA.paid_amount) === 0,
  JSON.stringify({ s: slipA.payment_status, o: slipA.outstanding }));

// The advance was recovered on finalise, so nothing is left on the ledger.
check('the advance came off the ledger when the month closed',
  num((await one(`select outstanding from staff_advance_balance where profile_id=$1`,
    [WORKER_A])).outstanding) === 0);

// =============================================================================
section('Paying — partial, repeated, and never twice');

const payRef = randomUUID();
let firstPayment;

await asUser(db, ADMIN_AUTH, async () => {
  const part = await one(`select public.record_salary_payment($1,$2,$3,$4) as j`,
    [slipA.id, 1000, payRef, '2026-08-07']);
  firstPayment = part.j.id;
  check('a partial payment leaves the rest outstanding',
    num(part.j.paid) === 1000 && num(part.j.outstanding) === 2000
    && part.j.settled === false, JSON.stringify(part.j));

  const retry = await one(`select public.record_salary_payment($1,$2,$3,$4) as j`,
    [slipA.id, 1000, payRef, '2026-08-07']);
  check('a retried payment does not hand over the money twice',
    retry.j.duplicate === true && num(retry.j.paid) === 1000,
    JSON.stringify(retry.j));
});

check('the month now reads as partly paid',
  (await one(`select payment_status, paid_amount, outstanding from v_payslips
              where id=$1`, [slipA.id])).payment_status === 'PARTIAL');

await asUser(db, ADMIN_AUTH, async () => {
  const rest = await one(`select public.record_salary_payment($1,$2,$3,$4) as j`,
    [slipA.id, 2000, randomUUID(), '2026-08-07']);
  check('paying the remainder settles the month',
    num(rest.j.paid) === 3000 && num(rest.j.outstanding) === 0
    && rest.j.settled === true, JSON.stringify(rest.j));

  const over = await sqlstate(() => db.query(
    `select public.record_salary_payment($1,$2,$3)`, [slipA.id, 1, randomUUID()]));
  check('and a rupee more is refused by name', over === 'DP013', `got ${over}`);

  const nothing = await sqlstate(() => db.query(
    `select public.record_salary_payment($1,$2,$3)`, [slipA.id, 0, randomUUID()]));
  check('a payment of nothing is refused', nothing === 'DP005', `got ${nothing}`);
});

const settled = await one(
  `select payment_status, paid_amount, outstanding from v_payslips where id=$1`,
  [slipA.id]);
check('the payslip reads as paid in full',
  settled.payment_status === 'PAID' && num(settled.paid_amount) === 3000
  && num(settled.outstanding) === 0, JSON.stringify(settled));

const history = await all(
  `select amount, paid_on, is_reversal from v_salary_payments
   where payslip_id=$1 order by created_at`, [slipA.id]);
check('and the slip can print both payments with their dates',
  history.length === 2 && num(history[0].amount) === 1000
  && num(history[1].amount) === 2000, JSON.stringify(history));

const advHistory = await all(
  `select entry_date, amount from v_salary_advances
   where profile_id=$1 and period_month=$2`, [WORKER_A, AUG]);
check('the advance history is there for the slip too, with its date',
  advHistory.length === 1 && num(advHistory[0].amount) === 2000
  && day(advHistory[0].entry_date) === '2026-08-10',
  JSON.stringify(advHistory));

// =============================================================================
section('Reversing a payment — undone, not erased');

await asUser(db, ADMIN_AUTH, async () => {
  const back = await one(`select public.reverse_salary_payment($1,$2) as j`,
    [firstPayment, randomUUID()]);
  check('a payment can be reversed', num(back.j.amount) === -1000
    && num(back.j.paid) === 2000, JSON.stringify(back.j));

  const twice = await sqlstate(() => db.query(
    `select public.reverse_salary_payment($1,$2)`, [firstPayment, randomUUID()]));
  check('but not twice', twice === 'DP005', `got ${twice}`);

  const rev = await one(`select id from salary_payments where reverses=$1`,
    [firstPayment]);
  const chain = await sqlstate(() => db.query(
    `select public.reverse_salary_payment($1,$2)`, [rev.id, randomUUID()]));
  check('and a reversal is not itself reversible', chain === 'DP005', `got ${chain}`);
});

const afterReversal = await one(
  `select payment_status, paid_amount, outstanding from v_payslips where id=$1`,
  [slipA.id]);
check('the month is owed again, by exactly what was taken back',
  afterReversal.payment_status === 'PARTIAL'
  && num(afterReversal.paid_amount) === 2000
  && num(afterReversal.outstanding) === 1000, JSON.stringify(afterReversal));

const kept = await all(
  `select amount, is_reversal, is_reversed from v_salary_payments
   where payslip_id=$1 order by created_at`, [slipA.id]);
check('all three rows are kept — the wrong one, the right one, and the undo',
  kept.length === 3 && kept.filter((r) => r.is_reversal).length === 1
  && kept.filter((r) => r.is_reversed).length === 1, JSON.stringify(kept));

// =============================================================================
section('Payment edge cases the factory will actually hit');

// Somebody who drew more than a month's pay has nothing left to hand over. That
// is "paid", not "unpaid" — the money went out earlier, as advances.
const sureshAug = await one(
  `select net_payable, payment_status from v_payslips
   where profile_id=$1 and period_month=$2`, [SURESH, AUG]);
check('a salary entirely taken as advances reads as paid, not owed',
  num(sureshAug.net_payable) === 0 && sureshAug.payment_status === 'PAID',
  JSON.stringify(sureshAug));

// A worker paid on the 31st is due on the 28th of February, not on a date that
// does not exist.
const shortMonth = await one(
  `select app.salary_due_on(date '2027-02-01', 31::smallint) as d,
          app.salary_due_on(date '2027-02-01', 7::smallint)  as e,
          app.salary_due_on(date '2027-02-01', null)         as f`);
check('a salary day past the end of a short month lands on its last day',
  day(shortMonth.d) === '2027-02-28'
  && day(shortMonth.e) === '2027-02-07'
  && shortMonth.f === null, JSON.stringify(shortMonth));

await asUser(db, RAVI_AUTH, async () => {
  const s = await sqlstate(() => db.query(
    `select public.record_salary_payment($1,$2,$3)`, [slipA.id, 100, randomUUID()]));
  check('an operator cannot pay themselves', s === 'DP004', `got ${s}`);

  const seen = await all(`select * from v_salary_payments`);
  check('and sees no payment but their own', seen.every((r) => r.profile_id === RAVI),
    `${seen.length} rows`);

  // Everything the operator's own pay screen reads, and its salary slip with
  // it. A worker can produce their own slip, so each of these has to answer
  // for them — and answer about nobody else.
  const myAdv = await all(`select * from v_salary_advances`);
  check('a worker can read their own advances, and only those',
    myAdv.length > 0 && myAdv.every((r) => r.profile_id === RAVI),
    `${myAdv.length} rows, ids ${JSON.stringify([...new Set(myAdv.map(r => r.profile_id))])}`);

  const myPay = await all(`select * from v_payslips order by period_month`);
  check('and their own payslips, with what is paid and what is left',
    myPay.length > 0 && myPay.every((r) => r.profile_id === RAVI)
    && myPay.every((r) => r.payment_status !== null),
    `${myPay.length} rows`);

  const myRow = await all(`select * from v_staff_pay`);
  check('and their own salary, salary day and advance balance',
    myRow.length === 1 && myRow[0].profile_id === RAVI
    && num(myRow[0].monthly_salary) !== null,
    JSON.stringify(myRow));

  const w = await db.query(`update salary_payments set amount = 99999`);
  check('nor can anyone rewrite a payment by hand', w.affectedRows === 0,
    `${w.affectedRows} rows updated`);
});

await asUser(db, ADMIN_AUTH, async () => {
  const d = await db.query(`delete from salary_payments`);
  check('not even an admin can delete one', d.affectedRows === 0,
    `${d.affectedRows} deleted`);

  // August holds three payslips: Ravi owed in full, Suresh settled by advances,
  // Worker A part paid. One of each status, which is what the overview is for.
  const sum = await one(`select * from v_payroll_summary where period_month=$1`, [AUG]);
  check('the monthly overview counts a worker in each state',
    num(sum.payslip_count) === 3 && num(sum.paid_count) === 1
    && num(sum.partial_count) === 1 && num(sum.unpaid_count) === 1,
    JSON.stringify(sum));

  // The identity that makes the overview trustworthy: nothing is counted twice
  // and nothing is lost between the two columns.
  check('and what is paid plus what is left is exactly what is owed',
    num(sum.paid_total) + num(sum.outstanding_total) === num(sum.net_total)
    && num(sum.paid_total) === 2000,
    JSON.stringify({ paid: sum.paid_total, left: sum.outstanding_total,
                     net: sum.net_total }));
});

// Balances must still be explained by their ledgers after all of that.
const advDrift = await all(`
  select b.profile_id, b.outstanding, coalesce(sum(t.amount), 0) as ledger
  from staff_advance_balance b
  left join advance_transactions t on t.profile_id = b.profile_id
  group by b.profile_id, b.outstanding
  having b.outstanding <> coalesce(sum(t.amount), 0)`);
check('every advance balance is explained by its ledger', advDrift.length === 0,
  JSON.stringify(advDrift));

console.log(`\n${'═'.repeat(64)}`);
console.log(`  ${pass} passed, ${fail} failed`);
if (fail) { console.log('\n  Failures:'); failures.forEach(f => console.log(`   - ${f}`)); }
console.log(`${'═'.repeat(64)}`);
process.exit(fail ? 1 : 0);
