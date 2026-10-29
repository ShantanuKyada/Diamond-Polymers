# Going live: clearing the demonstration factory

The database you have been using still holds the factory it was seeded with:
four machines, two pipe types, eight products, five raw materials and three
days of invented production, plus three operators who do not exist. None of it
is real. Before the floor starts entering real work, it has to go, or the first
real reading will be added to a stock balance that was never true.

This is a one-off. You run it once, on the day you start, and never again.

> **There are two cleanup scripts. This guide is for the thorough one.**
>
> `supabase/checks/clean_demo_data.sql` clears the records of work and keeps
> the catalogue — machines, pipe types, sizes, products, raw materials — so
> the factory can record an entry the moment it finishes. Use it if that
> catalogue is yours.
>
> `supabase/scripts/go_live_clear_demo_data.sql`, below, clears the catalogue
> too, because the seeded one is invented. Nothing can be recorded until you
> have entered the real one — step 5 says what to enter and in which order.
>
> Run one or the other, not both.

---

## What goes and what stays

**Cleared**

- Everything the floor records: production, mixtures, shredding, wastage,
  dispatch, every stock movement and every stock balance.
- Everything the office records: attendance, salary structures, advances,
  deductions, payroll runs, payslips and salary payments.
- Machine assignments and notifications.
- The demonstration catalogue: machines, pipe types, pipe sizes, pipe products
  and raw materials.
- Every employee except the two below.

**Kept**

| | Why |
|---|---|
| Your configuration (Configuration tab) | Decisions you have already made, factory name included |
| Employee roles (Operator, Labourer, Office, anything you added) | Same |
| Shifts (Morning, Night) | Same |
| Raw-material categories (Raizin, Chemical, Color, Recycled) | Your own taxonomy, and shredding stocks regrind against **Recycled** — deleting it would break shredding on day one |
| **EMP-001 Factory Admin** and **EMP-101 Shantanu Kyada**, logins intact | The two people who sign in |

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups**.

There is no undo. Everything cleared is gone for good. Do not skip this.

## 2. Pre-flight check

Open the SQL editor and run `supabase/checks/go_live_preflight.sql`.

It writes nothing. Read all ten rows, and these three in particular:

- **Row 01 and 02** must say `ok = true` and show an email beside each name. If
  either says `NO LOGIN LINKED`, stop: that person cannot sign in now and
  clearing the data will not change that. Fix the link first —
  `docs/02-setup.md` §"Linking logins" covers it.
- **Row 03** must say `ok = true`. If it is false it names somebody who is not
  on the keep list and who has a login — somebody real you added since. Add
  their employee code to the keep list in step 11 of the clearing script before
  you run it, or they lose their record and their access.

Rows 04 to 07 tell you what is about to be deleted. Row 04 names the people.

## 3. Clear it

Run `supabase/scripts/go_live_clear_demo_data.sql`.

The whole script is one transaction. If anything fails, nothing is deleted and
you can fix the problem and run it again. It finishes with *Success. No rows
returned*, which is what you want — it ends on `commit`, and a commit returns
no rows.

Running it twice is harmless.

## 4. Verify

Run `supabase/checks/go_live_verify.sql`.

Rows 01 to 08 must all say `ok = true`. Row 09 is information rather than a
pass or a fail: it lists any Supabase login left over with no employee record.
Deleting an employee does not delete the login behind them, and a leftover
login can still authenticate — it then finds no profile and gets nowhere,
because every access rule in this database reads through the employee record.
It is untidy rather than unsafe. Remove any that are listed under
**Authentication → Users**.

## 5. Build the factory back up, for real

Sign in as Factory Admin and enter the real thing, in this order — each screen
needs the one above it:

1. **Raw materials** — what you actually buy, with real minimum-stock levels.
2. **Pipe types** and **Pipe sizes**.
3. **Pipe products** — a type and a size together, with the real bundle weight.
4. **Machines**, and which products each one runs.
5. **Employees** — everybody, on the right role. Operators get a login; a
   labourer does not need one.
6. **Opening stock** — enter what is physically in the store today as a
   material receipt. Stock starts at zero, so whatever you do not enter, the
   app will think you do not have.

## 6. Hand out the APK

Same build for everyone. If you have not set up the signing key yet
(`docs/14-signing-the-apk.md`), every new APK still has to be installed over an
uninstall rather than as an update.

---

## If something goes wrong

**The clearing script failed with a foreign key error.** Nothing was deleted —
the transaction rolled back. Send the error text; it names the table and the
constraint, which says exactly which order was wrong.

**Row 03 of the verify says more than two employees.** Somebody was re-added
between the clearing and the verify, or the keep list was edited. Harmless;
check who, in the Employees screen.

**Somebody cannot sign in afterwards.** Run `supabase/checks/diagnose_login.sql`
— it reports, for one email, whether the login exists, whether an employee
record points at it, and whether that record is active.
