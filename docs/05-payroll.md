# Attendance and Payroll

Phase 8. Migrations `0012`–`0014`, **simplified by `0019`** (A38), and
**paid by `0020`** (A39).

Staff are on a **monthly salary**. They get it on salary day. If somebody needs
part of it before then, they ask, they are given it, and it comes off the next
payslip. That is the whole module.

```
net payable = monthly salary − advances taken − deductions entered by hand
outstanding = net payable − what has been handed over
```

Attendance is captured separately as a punch in and a punch out per day. It is
a record of who was in. **It does not decide pay.**

> Migrations `0012`–`0014` originally built proration by attendance and
> statutory overtime. The factory uses neither, and `0019` removed both rather
> than leaving them switched off — a dormant rule is one somebody later assumes
> is running. The reasoning is in
> [`08-packaging-shifts-access.md`](08-packaging-shifts-access.md) under A38.

---

## The one assumption left

`payroll_recover_advances`, default `true`.

Outstanding advances come off a payslip automatically. Recovery is **capped at
what the month can cover**, so a payslip can never come out negative; somebody
who has drawn more than a month's pay carries the remainder forward.

Everything else the calculation used to assume — an unmarked-day policy, a
proration basis, a fixed divisor, an overtime multiplier — is gone, because
nothing reads it any more.

---

## Attendance

Still recorded in full, and still worth recording: the factory can see who was
in, when, and on which shift. It simply has no effect on a payslip.

One row per person per day. `worked_hours` is a `GENERATED ... STORED` column
over the punch pair, so it can never disagree with the times it summarises.

Punches are `timestamptz`, not `time`, which is what makes the **night shift**
work: a shift starting 22:00 and ending 06:00 is one row on the day it started,
not two halves to be stitched together (A16). `punch_out()` looks for an open
punch on the previous day before it gives up, so an operator clocking off at
dawn closes the right row without thinking about it.

Punching in twice returns the first punch rather than starting a second shift.

`set_attendance()` is the admin correction path. Marking a day `ABSENT` clears
its punches rather than refusing the correction — an admin fixing a mis-punch
should not have to delete data first.

---

## Advances

This is the part the factory actually described, and the part that has to be
right. Money is ledgered exactly as stock is: a `staff_advance_balance` row that
is the `FOR UPDATE` lock target, and an append-only `advance_transactions` table
where every row carries the previous and resulting outstanding with a `CHECK`
that they agree. Recovering more than is owed raises `DP010` rather than turning
an advance into a fine.

**Recovery happens on finalise, not on calculate.** This is the rule the module
turns on. `run_payroll()` can be run twenty times while the numbers are checked,
and each run only *proposes* a recovery on the payslip. `finalise_payroll()`
posts it to the ledger once. Recovering during calculation would drain a
worker's advance balance every time somebody reloaded the screen — and the
balance would be wrong with no record of why.

---

## Deductions

One lever, worked by hand: a labelled amount against one person for one month.
A long absence, damage, a canteen bill. It is a judgement, not arithmetic, which
is exactly why it is typed rather than computed.

Nothing **adds**. `add_staff_adjustment()` refuses anything but a `DEDUCTION`
(`DP005`), and the table's `CHECK` refuses it too. A bonus that the calculation
silently ignored would be worse than no bonus at all.

Deductions coming to more than the salary stop the run with `DP005` naming the
person, rather than storing a negative payslip. `remove_staff_adjustment()`
takes one back — admin-only, refused once the month is finalised, and safe
because a draft's payslips are rebuilt from scratch on every run.

---

## Paying

An advance and a salary payment are the same act, separated only by when it
happens (A39), so they are not modelled twice. An advance already reduced
`net_payable` through the ledger above; `salary_payments` records what is
handed over after that, and `outstanding` is the difference. Every rupee sits
in exactly one ledger, which is what makes double-counting impossible rather
than unlikely.

**Paying needs a finalised month.** A draft is rebuilt from scratch on every run
and its figures move; paying against a number that can still change is how a
system ends up paying one amount and reporting another. The foreign key is
`ON DELETE RESTRICT` so that if a later change ever broke that rule, the draft
rebuild would fail loudly rather than delete what somebody was paid.

Partial payments are expected, and repeated: pay what was handed over, as often
as it takes. `client_ref` makes a retry a no-op, and `DP013` refuses a payment
larger than what is left, naming the person and the amount.

A mistake is corrected by a **reversal** — a negative row pointing at what it
reverses, with a unique index so a double tap cannot reverse twice. The question
"what did we pay this worker in October" keeps the same answer a year from now,
including the wrong payment and its correction.

| Status | Means |
|---|---|
| `DRAFT` | The month is not agreed yet. Nothing is payable. |
| `UNPAID` | Agreed and owed in full. |
| `PARTIAL` | Something handed over, not all of it. |
| `PAID` | Nothing left. |

`DRAFT` is a separate state on purpose: a draft payslip with nothing paid would
otherwise read as a debt when nobody has decided the figure yet. A salary
entirely drawn as advances comes out `PAID` with no payment recorded, which is
honest — the money went out, just earlier.

---

## The payroll run

```
DRAFT  ──run_payroll()──▶  payslips computed, recomputable
  │
  └──finalise_payroll()──▶  FINALISED: frozen, advances posted to the ledger
```

A draft is rebuilt from scratch each run, so adding a deduction and
recalculating is safe. Once finalised, the month refuses recalculation
(`DP011`), refuses new deductions, and refuses the removal of existing ones.

Every figure a payslip depended on is **snapshotted onto it**. Reprinting a
payslip from two years ago produces the number that was paid then, not the
number today's master data implies. A raise is a new `salary_structures` row
that closes the previous period — never an edit.

The arithmetic is enforced by a `CHECK`, not merely intended:

```sql
net_payable = monthly_salary - deductions_amount - advance_recovered
```

A payslip that does not add up cannot be stored at all.

---

## Privacy

Stock is factory-wide; an operator seeing how much Raizin is in the shed costs
nothing. Pay is not like that.

Every payroll table is **yours or nobody's**: a worker reads their own row and
no one else's, an administrator reads all. There is no policy anywhere that lets
one worker read another's pay, advance balance or deductions.

Details that are easy to get wrong and are handled explicitly:

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
- `v_staff_pay` filters to the caller unless they are an admin. Under
  `security_invoker` alone a worker would see every colleague listed with a
  blank salary, since `profiles` is readable but `salary_structures` is not —
  again not a leak, but a roster that reads as though nobody is paid.

Deductions (`staff_adjustments`) are admin-only. One is visible to the worker as
a line on their payslip once it exists, not while it is still being decided.

---

## API

| Function | Who | What |
|---|---|---|
| `punch_in(...)` / `punch_out(...)` | self or admin | attendance, idempotent, night-shift aware |
| `set_attendance(...)` | admin | mark absent, leave, holiday; correct punches |
| `set_salary_structure(...)` | admin | a raise as a new effective-dated row |
| `issue_salary_advance(...)` | admin | ledgered, idempotent on `client_ref` |
| `add_staff_adjustment(...)` | admin | a deduction for one person in one month |
| `remove_staff_adjustment(id)` | admin | take one back while the month is a draft |
| `run_payroll(month)` | admin | compute or recompute a draft |
| `finalise_payroll(month)` | admin | freeze, and post advance recoveries once |
| `record_salary_payment(...)` | admin | pay a finalised payslip, in full or in part |
| `reverse_salary_payment(id)` | admin | undo a payment without erasing it |
| `save_worker_profile(...)` | admin | a worker and their salary, in one transaction |

### Views

`v_attendance_days` · `v_monthly_attendance` · `v_staff_advances` ·
`v_staff_pay` · `v_staff_deductions` · `v_payslips` · `v_payroll_summary` ·
`v_salary_payments` · `v_salary_advances`

`v_staff_pay` reports the salary **in force today**. A raise dated ahead arrives
separately as `upcoming_salary` / `upcoming_from`, so a roster never reads a
future figure as this month's pay.

### Error codes

| SQLSTATE | Meaning | Flutter maps to |
|---|---|---|
| `DP005` | Deductions exceed the salary; salary not greater than zero; an adjustment that is not a deduction | `validation` |
| `DP010` | Recovering more advance than is outstanding | `insufficientStock` |
| `DP011` | The payroll month is finalised | `conflict` |
| `DP013` | Paying more than is left on a payslip | `insufficientStock` |

---

## In the app

**Salary** (admin only) is the three things an administrator does, in the order
the work happens:

| Tab | What it does |
|---|---|
| **Pay** | Pick a month, calculate it, read the payslips, finalise, then pay |
| **Advances** | Give somebody part of their salary before salary day |
| **Salaries** | What each person is on; set it or change it |

Once a month is finalised each payslip offers **Pay** — full or partial, with the
payment history behind it so a second payment is safe to make — and **Slip**,
which shares or prints the PDF.

Anybody with no salary set is named on the Salaries tab rather than silently
left off the payroll. **Punches** is the attendance register.

A worker has their own side of this at **Profile → My pay**: their payslips with
the working shown, what they have drawn, when each payment arrived, and their own
slip to share. Draft months are left out — a figure the office has not agreed is
not a promise. The operator Home shows a row only when something is owed.

**More → Operators** is where a worker is created and edited: name, worker ID,
phone, joining date, monthly salary, salary day, role and whether they are on
the roll. The roster shows each person's salary or says plainly that they have
none.

### The salary slip

A worker asks "why is this the amount?", so the slip carries the monthly salary,
every advance with its date, anything deducted, every payment with its date,
what is left, and the status. A reversal prints as its own line rather than
being netted off.

One limitation, stated rather than hidden: the PDF draws with the standard
Helvetica, which has no glyph for a rupee sign or for any non-Latin script.
`Fmt.pdfSafe()` spells ₹ as "Rs." and drops what it cannot draw, so a name in
Gujarati would be *missing* rather than wrong — the employee code beside it is
always ASCII, so the worker stays identifiable. Bundling a Unicode font is the
real fix if the factory ever enters non-Latin names.

The demo twin runs the same arithmetic — the salary, the cap, the
recover-once-on-finalise rule — so a demo APK cannot disagree with the live one.

---

## Testing

```bash
cd supabase/tests
npm run test:payroll
```

**103 assertions**, including the ones that matter most:

- a month pays the monthly salary whatever the attendance says
- the proration and overtime columns, and the settings that drove them, are gone
- recalculating a draft never touches the advance ledger
- finalising twice does not recover the advance twice
- recovery is capped so net pay never goes negative, and the rest carries forward
- deductions larger than the salary are refused by name, and can be taken back
- a night shift punched out after midnight closes the same row
- an operator can see their own payslip, and nobody else's
- every advance balance is explained by its ledger
- the factory's own worked example end to end: 5,000 salary, 2,000 advance,
  3,000 remaining, paid in two instalments
- a payment against a draft month is refused
- a retried payment does not hand over the money twice
- a rupee more than is owed is refused by name
- a reversal gives the money back and keeps all three rows
- what is paid plus what is left is exactly what is owed, for every month

The Flutter side is covered by the `Payroll is a salary less what was taken
(A38)` and `Worker profiles and salary payments (A39)` groups in
`app/test/change_request_test.dart`, and the column and RPC names are pinned
against the real schema by `app_contract.test.mjs`. The migration-window SQL in
`supabase/checks/` is itself run by `migration_scripts.test.mjs`.

---

## Not built

- **A Unicode font in the PDF.** See the limitation above.
- **Statutory PF/ESI.** Would be ordinary `DEDUCTION` rows rather than
  calculated, because the rates and ceilings are policy the factory has not
  stated.
- **Leave balances.** `PAID_LEAVE` is honoured as a status when marked, but no
  entitlement is tracked or accrued — and since attendance no longer moves pay,
  it is a record rather than a calculation.
- **A holiday calendar.** Holidays are marked per person per day. A
  factory-wide calendar that marks everybody at once would be a convenience
  layer over the same table.
