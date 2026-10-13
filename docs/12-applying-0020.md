# Applying migration 0020 to the live project

`0020_worker_profiles_and_salary_payments.sql` adds the half of payroll that was
missing: recording that a worker was actually **paid**.

```
outstanding = net payable − what has been handed over
```

and with it the two profile fields payroll needed — when somebody joined, and
which day of the month they are paid on. The reasoning is in
[`08-packaging-shifts-access.md`](08-packaging-shifts-access.md) under A39.

Roughly five minutes.

---

## Read this first

**This one only adds.** Unlike 0019, it drops no columns and deletes no rows: two
nullable columns on `profiles`, one new table, three new functions, one new
setting, and five read models rebuilt with more columns than they had. There is
nothing here that can lose data.

**The app and the database move together.** The current app expects 0020. An APK
built from `main` will fail on `v_salary_payments` and `save_worker_profile`
until this is applied. Apply the migration first, then hand out the new APK.

**One visible change the moment it lands:** any month you have already finalised
starts showing as unpaid, because until now there was no way to say otherwise.
Row 07 of the preflight tells you how many. That is the point of the migration,
not a problem with it — record the payments and the months settle.

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups** → *Download backup*.

Less critical than for 0019, since nothing is dropped, but a minute well spent.

## 2. Pre-flight check

Supabase dashboard → **SQL Editor** → **New query**. Paste the contents of:

```
supabase/checks/0020_preflight.sql
```

Seven rows. Rows **01** and **02** must say true:

| Row | What it means if `ok` is false |
|---|---|
| 01. Migration 0019 applied | Stop. Apply 0019 first — see [11-applying-0019.md](11-applying-0019.md). |
| 02. 0020 not applied yet | It is already applied. Skip to step 4. |
| 03–07 | Informational: staff, salaries, payslips and advances are all kept, and row 07 says how many finalised months become payable. |

## 3. Apply the migration

SQL Editor → **New query**. Paste the whole of:

```
supabase/migrations/0020_worker_profiles_and_salary_payments.sql
```

Run it. One transaction in the editor, so either all of it lands or none of it
does. It should finish in a second or two.

Or from a terminal with the database URL:

```bash
cd "supabase/tests" && npm run apply -- --only=0020
```

## 4. Verify

SQL Editor → **New query**. Paste:

```
supabase/checks/0020_verify.sql
```

Seventeen rows, every `ok` column true:

| Row | Confirms |
|---|---|
| 01–02 | A profile records a joining date and a salary day, and the day is a real one |
| 03 | The payments ledger exists |
| 04 | A draft rebuild cannot delete payment history |
| 05–06 | A payment cannot be zero, and can be reversed once |
| 07–08 | Append-only: a SELECT policy and nothing else, with RLS on |
| 09–10 | The three new functions exist with one signature each and are callable |
| 11–13 | The read models report where a payslip stands, and still run as the caller |
| 14 | A salary day past the end of a short month lands on its last day |
| 15–17 | Nothing on file is overpaid, every month reconciles, the slip footer is configurable |

## 5. Fill in the profile fields

In the admin app, **More → Operators**. Tap each person and set:

- **Joining date** — leave blank for anyone whose start date you do not have.
  It stays genuinely blank rather than guessing.
- **Salary day** — the day of the month they are paid on. "No fixed day" is a
  real choice; a day past the end of a short month falls on its last day.
- **Monthly salary** — if it is not already set. Anyone without one is named in
  a banner on **Salary → Salaries** and is left off the payroll rather than paid
  zero.

## 6. Pay a month

**Salary → Pay** → pick the month → *Calculate* → read the payslips →
*Finalise and pay*.

Each payslip then offers:

- **Pay** — record what was handed over, in full or in part, as many times as it
  takes. The sheet shows what is left and what has already gone out, so a second
  payment is safe to make.
- **Slip** — share or print the PDF salary slip.

Give advances any time through **Salary → Advances → Give advance**; they come
off the next payslip automatically.

A worker sees their own side of all this at **Profile → My pay** once they have
a login, including their own slip to share. Nothing extra to switch on — the
policies already allowed it.

## 7. Hand out the new APK

The GitHub Actions workflow builds it. The per-ABI `arm64-v8a` APK is the one
for a modern phone, around 19 MB.

Optionally set **More → Configuration → `salary_slip_footer`** first, so the
slips carry whatever line the factory wants at the foot.

---

## If something goes wrong

**The app says a function is missing (`PGRST203`).** Two functions of one name
exist. Verify row 09 catches it. This migration creates all three with
`create or replace` and none of them changes an existing signature, so it should
not happen — but if it does, drop the duplicate by hand and reload the schema
cache from **API Docs**.

**A payment is refused with "has not been finalised yet".** Working as intended:
a draft's figures can still change. Finalise the month, then pay.

**A payment went in wrong.** Open **Pay** on that payslip and use the undo arrow
beside it. The payment and the reversal both stay on the record, and the slip
prints both.

**The slip prints "Rs." instead of ₹.** Also intended — see A39. The standard
PDF font has no rupee glyph, and dropping it silently would have printed the
amount with no currency at all.
