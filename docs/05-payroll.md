# Attendance and Payroll

Phase 8. Migrations `0012`–`0014`. The second of the two modules the factory
asked for, and the only phase that had no database behind it at all.

Staff are on a **monthly salary**, prorated by attendance. Attendance is captured
as a **punch in and a punch out** per day. Overtime, advances, deductions and
bonuses all apply.

---

## The three rules that are assumptions

Payroll arithmetic is where a wrong guess costs somebody real money, so the
places this design had to decide something are called out rather than buried.
Each is read in exactly one place — `run_payroll()` — and each is an
`app_settings` key, so the factory can correct it without a migration.

### 1. A day nobody marked is a day that gets paid

`payroll_unmarked_day_policy`, default `PAYABLE`.

Small factories mark exceptions — absence, leave — and say nothing about an
ordinary day. If unmarked days counted as unpaid, the first month somebody was
slow filling in attendance would silently halve everyone's wages.

Underpaying a worker is a worse failure than overpaying one, so the default fails
in the direction that does not take money out of somebody's pocket. Set it to
`UNPAID` if every day is genuinely marked.

### 2. Proration is by calendar days

`payroll_proration_basis`, default `CALENDAR_DAYS`.

```
basic = monthly salary × payable days ÷ days in the month
```

A fully present month therefore pays exactly the monthly salary, with no rounding
surprise. `FIXED_DAYS` divides by `payroll_fixed_days` (26) instead, which some
factories prefer.

### 3. Overtime is twice the ordinary hourly rate

`payroll_overtime_multiplier`, default `2.0` — the statutory factory rate in
India. Derived as `monthly ÷ 26 ÷ standard hours per day × 2` unless a person has
an explicit `overtime_rate_per_hour`.

Overtime hours are **entered, not derived**. How much of a long day counts as
overtime is a decision, not arithmetic — a worker who stayed late chatting has
not earned double time.

---

## Attendance

One row per person per day. `worked_hours` is a `GENERATED ... STORED` column
over the punch pair, so it can never disagree with the times it summarises.

Punches are `timestamptz`, not `time`, which is what makes the **night shift**
work: a shift starting 22:00 and ending 06:00 is one row on the day it started,
not two halves to be stitched together (A16). `punch_out()` looks for an open
punch on the previous day before it gives up, so an operator clocking off at dawn
closes the right row without thinking about it.

Punching in twice returns the first punch rather than starting a second shift.

`set_attendance()` is the admin correction path. Marking a day `ABSENT` clears
its punches rather than refusing the correction — an admin fixing a mis-punch
should not have to delete data first.

| Status | Payable |
|---|---|
| `PRESENT`, `PAID_LEAVE`, `HOLIDAY`, `WEEKLY_OFF` | 1.0 |
| `HALF_DAY` | 0.5 |
| `ABSENT`, `UNPAID_LEAVE` | 0 |

---

## Advances

Money is ledgered exactly as stock is: a `staff_advance_balance` row that is the
`FOR UPDATE` lock target, and an append-only `advance_transactions` table where
every row carries the previous and resulting outstanding with a `CHECK` that they
agree. Recovering more than is owed raises `DP010` rather than turning an advance
into a fine.

**Recovery happens on finalise, not on calculate.** This is the rule the module
turns on. `run_payroll()` can be run twenty times while the numbers are checked,
and each run only *proposes* a recovery on the payslip. `finalise_payroll()`
posts it to the ledger once. Recovering during calculation would drain a worker's
advance balance every time somebody reloaded the screen — and the balance would
be wrong with no record of why.

Recovery is capped so net pay can never be negative. Somebody who owes more than
they earned this month carries the rest forward.

---

## The payroll run

```
DRAFT  ──run_payroll()──▶  payslips computed, recomputable
  │
  └──finalise_payroll()──▶  FINALISED: frozen, advances posted to the ledger
```

A draft is rebuilt from scratch each run, so adding a bonus and recalculating is
safe. Once finalised, the month refuses recalculation (`DP011`) and refuses new
adjustments.

Every figure a payslip depended on is **snapshotted onto it**: the salary, the
overtime rate, the day counts. Reprinting a payslip from two years ago produces
the number that was paid then, not the number today's master data implies. A
raise is a new `salary_structures` row that closes the previous period — never an
edit.

The arithmetic is enforced by `CHECK` constraints, not merely intended:

```sql
gross_amount = basic_amount + overtime_amount + additions_amount
net_payable  = gross_amount - deductions_amount - advance_recovered
```

A payslip that does not add up cannot be stored at all.

---

## Privacy

Stock is factory-wide; an operator seeing how much Raizin is in the shed costs
nothing. Pay is not like that.

Every payroll table is **yours or nobody's**: a worker reads their own row and no
one else's, an administrator reads all. There is no policy anywhere that lets one
worker read another's pay, advance balance or deductions.

Two details that are easy to get wrong and are handled explicitly:

- Views are `security_invoker = on`. Without it a view runs as its owner and
  hands every worker the entire payroll.
- `payroll_periods` grants a worker read access to **periods they have a payslip
  in**. An admin-only policy there looks safer but is not: every payslip view
  joins the period, so it silently empties the join and hides a worker's payslip
  from themselves. That bug was caught by a test asserting the *positive* — that
  a worker can see their own payslip — not just the negative.
- `v_payroll_summary` is admin-only via an explicit `WHERE`. Under RLS alone a
  worker would see it aggregate their single payslip and read it as the
  factory's total payroll. Not a leak, but a number meaning something quite
  different from what it appears to say.

Adjustments (`staff_adjustments`) are admin-only. A fine is visible to the worker
as a line on their payslip once it exists, not while it is still being decided.

---

## API

| Function | Who | What |
|---|---|---|
| `punch_in(...)` / `punch_out(...)` | self or admin | attendance, idempotent, night-shift aware |
| `set_attendance(...)` | admin | mark absent, leave, holiday; correct punches |
| `set_salary_structure(...)` | admin | a raise as a new effective-dated row |
| `issue_salary_advance(...)` | admin | ledgered, idempotent on `client_ref` |
| `add_staff_adjustment(...)` | admin | bonus, incentive or deduction for a month |
| `run_payroll(month)` | admin | compute or recompute a draft |
| `finalise_payroll(month)` | admin | freeze, and post advance recoveries once |

### Views

`v_attendance_days` · `v_monthly_attendance` · `v_staff_advances` ·
`v_payslips` · `v_payroll_summary`

### Error codes

| SQLSTATE | Meaning | Flutter maps to |
|---|---|---|
| `DP010` | Recovering more advance than is outstanding | `insufficientStock` |
| `DP011` | The payroll month is finalised | `conflict` |

---

## Testing

```bash
cd supabase/tests
npm run test:payroll
```

**52 assertions**, including the ones that matter most:

- recalculating a draft never touches the advance ledger
- finalising twice does not recover the advance twice
- recovery is capped so net pay never goes negative, and the rest carries forward
- a night shift punched out after midnight closes the same row
- an operator can see their own payslip, and nobody else's
- every advance balance is explained by its ledger

---

## Not built

- **The UI.** Punches and Salary are still placeholder screens.
- **Statutory PF/ESI.** Modelled as ordinary `DEDUCTION` adjustments rather than
  calculated, because the rates and ceilings are policy the factory has not
  stated.
- **Leave balances.** `PAID_LEAVE` is honoured when marked, but no entitlement is
  tracked or accrued.
- **A holiday calendar.** Holidays are marked per person per day. A factory-wide
  calendar that marks everybody at once would be a convenience layer over the
  same table.
