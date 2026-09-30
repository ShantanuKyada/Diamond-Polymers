# Applying migration 0019 to the live project

`0019_simple_payroll.sql` replaces the payroll calculation with the one the
factory actually uses:

```
net payable = monthly salary − advances taken − deductions entered by hand
```

Roughly ten minutes. The reasoning is in
[`08-packaging-shifts-access.md`](08-packaging-shifts-access.md) under A38.

---

## Read this first

**0019 drops columns.** `drop column if exists` guards against erroring on a
second run; it does not guard the data. Anything in `basic_amount`,
`gross_amount`, `overtime_amount`, `additions_amount` and the day counts goes
with them, and a payslip reprinted afterwards would be a different document from
the one that was paid.

**On this project there is nothing to lose.** Every payroll table was empty when
this was written: no payslip, salary structure, advance, adjustment or attendance
row existed. The preflight in step 2 confirms that before you commit to it.

**The app and the database move together.** The current app expects 0019. An APK
built from `main` will fail on `v_staff_pay` and the new `set_salary_structure`
signature until this is applied. Apply the migration first, then hand out the
new APK.

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups** → *Download backup*.

Unlike 0015, this one deletes things. If the backup option is not on your plan,
use the connection string from **Project Settings → Database** with `pg_dump`
before going further.

## 2. Pre-flight check

Supabase dashboard → **SQL Editor** → **New query**. Paste the contents of:

```
supabase/checks/0019_preflight.sql
```

Run it. Nine rows come back. Read the `ok` column:

| Row | What it means if `ok` is false |
|---|---|
| 01. Payroll 0012–0014 applied | Stop. Apply those first. |
| 02. Migrations through 0018 applied | Stop. Apply 0015–0018 first. |
| 03. 0019 not applied yet | It is already applied. Skip to step 4. |
| **04. No payslip has been issued** | **Stop.** Somebody has been paid, and 0019 would drop the figures behind it. Ask before going further. |
| **05. No salary carries an overtime rate** | **Stop.** That rate is recorded nowhere else. |
| 06–08 | Informational: salaries, advances and attendance are all kept. |
| 09. Adjustments that are not deductions | Stop. The new `CHECK` refuses bonus and incentive rows, so the migration will fail until they are removed. |

Rows 04 and 05 are the ones that decide whether this is safe.

## 3. Apply the migration

SQL Editor → **New query**. Paste the whole of:

```
supabase/migrations/0019_simple_payroll.sql
```

Run it. It is one transaction in the editor, so either all of it lands or none
of it does. Expect it to finish in a second or two — there is no data to rewrite.

Alternatively, from a terminal with the database URL:

```bash
cd "supabase/tests" && npm run apply -- --only=0019_simple_payroll.sql
```

## 4. Verify

SQL Editor → **New query**. Paste:

```
supabase/checks/0019_verify.sql
```

Fourteen rows, every `ok` column true:

| Row | Confirms |
|---|---|
| 01–02 | A payslip is now four figures and the old ten are gone |
| 03 | `payslip_net_ck` enforces the arithmetic |
| 04 | `salary_structures` carries a salary, not a rate card |
| 05–06 | The proration settings are gone; advance recovery is still on |
| 07 | An adjustment can only subtract |
| 08 | `set_salary_structure` has exactly one signature — two would be an overload PostgREST cannot choose between, and every call from the app would fail |
| 09 | `remove_staff_adjustment` exists |
| 10–11 | The four read models exist and still run as the caller |
| 12 | Attendance is untouched |
| 13–14 | Nothing on file contradicts itself |

## 5. Set the salaries

Payroll has never been usable from the app before, so nobody is on a salary yet.
In the admin app:

**Salary → Salaries** — tap each person and set their monthly figure. Anyone left
unset is named in a banner at the top of that tab and will be left off the
payroll rather than paid zero.

Then, whenever somebody draws against it:

**Salary → Advances → Give advance**.

And at month end:

**Salary → Pay** — pick the month, *Calculate*, read the payslips, *Finalise and
pay*. Finalising is the point the advances come off the ledger, so it happens
once; calculating can be repeated as often as you like before that.

## 6. Hand out the new APK

The GitHub Actions workflow builds it. The per-ABI `arm64-v8a` APK is the one
for a modern phone, around 19 MB.

---

## If something goes wrong

**The migration half-ran.** It cannot: the SQL editor wraps it in a transaction.
If the editor times out, run the whole file again — every step is guarded.

**The app says a function is missing (`PGRST203`).** Two `set_salary_structure`
overloads exist, which means the `drop function` at the top of that section did
not match the old signature. Verify row 08 catches this. Drop the six-argument
form by hand:

```sql
drop function if exists public.set_salary_structure(uuid, numeric, date, numeric, numeric, text);
```

Then reload the schema cache: Dashboard → **API Docs** → any endpoint, or wait
about a minute.

**The app says a column does not exist.** The APK predates the migration. Build
and install the new one.
