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

const RAVI = (await one(`select id from profiles where employee_code='EMP-101'`)).id;
const SURESH = (await one(`select id from profiles where employee_code='EMP-102'`)).id;

// June 2026: a completed month with 30 days, so the arithmetic is easy to check
// by hand and nothing collides with today's date.
const MONTH = '2026-06-01';
const DAYS = 30;
const SALARY = 26000;          // /26/8*2 gives a round 250/h of overtime
const OT_RATE = 250;

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
section('Payroll — the arithmetic');

await asUser(db, ADMIN_AUTH, async () => {
  await db.query(`select public.add_staff_adjustment($1,$2,'BONUS','Festival bonus',$3,$4)`,
    [RAVI, MONTH, 500, randomUUID()]);
  await db.query(`select public.add_staff_adjustment($1,$2,'DEDUCTION','Canteen',$3,$4)`,
    [RAVI, MONTH, 200, randomUUID()]);

  const r = await one(`select public.run_payroll($1) as j`, [MONTH]);
  check('payroll runs and produces a payslip per person with a salary',
    num(r.j.payslips) === 2 && num(r.j.calendar_days) === DAYS, JSON.stringify(r.j));
});

const slip = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`, [RAVI, MONTH]);

// 3 absent days out of 30, unmarked days paid: 27 payable.
check('absences prorate the basic pay',
  num(slip.payable_days) === 27 && num(slip.basic_amount) === 23400,
  `${slip.payable_days} days -> ${slip.basic_amount}`);

check('overtime is paid at the derived statutory rate',
  num(slip.overtime_rate_per_hour) === OT_RATE && num(slip.overtime_hours) === 4
  && num(slip.overtime_amount) === 1000,
  JSON.stringify({ r: slip.overtime_rate_per_hour, h: slip.overtime_hours, a: slip.overtime_amount }));

check('a bonus adds and a deduction subtracts',
  num(slip.additions_amount) === 500 && num(slip.deductions_amount) === 200);

// gross 23400 + 1000 + 500 = 24900; recovery capped at 24900-200 = 24700, so all 5000
check('gross is basic plus overtime plus additions',
  num(slip.gross_amount) === 24900, `${slip.gross_amount}`);
check('the outstanding advance is recovered',
  num(slip.advance_recovered) === 5000, `${slip.advance_recovered}`);
check('net is gross less deductions and recovery',
  num(slip.net_payable) === 19700, `${slip.net_payable}`);

const comps = await all(
  `select component_type, amount from payslip_components where payslip_id=$1 order by sort_order`,
  [slip.id]);
const compSum = comps.reduce((a, c) => a + num(c.amount), 0);
check('the itemised lines add up to net pay', Math.abs(compSum - 19700) < 0.01,
  `${compSum} from ${JSON.stringify(comps.map(c => [c.component_type, c.amount]))}`);

// Somebody with no attendance marked at all is paid in full under the PAYABLE
// policy — the documented assumption, asserted so a change to it is deliberate.
const sureshSlip = await one(
  `select * from v_payslips where profile_id=$1 and period_month=$2`, [SURESH, MONTH]);
check('an unmarked month pays the full salary (payroll_unmarked_day_policy)',
  num(sureshSlip.payable_days) === DAYS && num(sureshSlip.net_payable) === 21000,
  JSON.stringify({ d: sureshSlip.payable_days, n: sureshSlip.net_payable }));

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
    `select public.add_staff_adjustment($1,$2,'BONUS','Late',$3,$4)`,
    [RAVI, MONTH, 100, randomUUID()]));
  check('and cannot take new adjustments', late === 'DP011', `got ${late}`);
});

const stillZero = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [RAVI])).outstanding);
check('the second finalise moved no money', stillZero === 0, `${stillZero}`);

// =============================================================================
section('Payroll — advance recovery cannot push pay negative');

await asUser(db, ADMIN_AUTH, async () => {
  // An advance far larger than a month's pay.
  await db.query(`select public.issue_salary_advance($1,$2,$3)`, [SURESH, 100000, randomUUID()]);
  await db.query(`select public.run_payroll($1)`, ['2026-07-01']);
});

const big = await one(
  `select * from v_payslips where profile_id=$1 and period_month='2026-07-01'`, [SURESH]);
check('recovery is capped at what is actually payable',
  num(big.net_payable) === 0 && num(big.advance_recovered) === num(big.gross_amount),
  JSON.stringify({ net: big.net_payable, rec: big.advance_recovered, gross: big.gross_amount }));

await asUser(db, ADMIN_AUTH, () => db.query(`select public.finalise_payroll($1)`, ['2026-07-01']));
const carried = num((await one(
  `select outstanding from staff_advance_balance where profile_id=$1`, [SURESH])).outstanding);
check('the rest of the advance carries forward', carried === 100000 - num(big.gross_amount),
  `${carried}`);

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
  check('the summary totals the month', num(s.payslip_count) === 2
    && num(s.net_total) === 19700 + 21000 && s.status === 'FINALISED',
    JSON.stringify(s));

  const att = await one(
    `select * from v_monthly_attendance where profile_id=$1 and period_month=$2`, [RAVI, MONTH]);
  check('monthly attendance rolls up per person',
    num(att.absent_days) === 3 && num(att.overtime_hours) === 4, JSON.stringify(att));
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
