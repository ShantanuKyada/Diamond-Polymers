# Applying migration 0021 to the live project

`0021_employee_types_and_any_machine.sql` covers three of the four changes in
the October request:

- an operator may work on **any machine**, not only their assigned one
- staff have a **type** — operator, labourer or office
- **leaving the factory** closes a machine assignment instead of leaving it open

The fourth change, phones and tablets, is app-only and needs no migration.
Reasoning for all four is in
[`08-packaging-shifts-access.md`](08-packaging-shifts-access.md) under A40.

Roughly five minutes.

---

## Read this first

**This one only adds**, except for one rule it deliberately relaxes. It drops no
columns and deletes no rows: one new column on `profiles`, one enum, two
triggers, one view, and two functions replaced.

**One behaviour changes the moment it lands.** Every operator can record
material and production on **any** machine. Until now the database refused
anything but their assigned machine with `DP006`. That refusal is gone — the
assignment becomes the default on the entry form rather than a gate. Preflight
row 05 tells you how many operators that affects.

**The app and the database move together.** An APK built from `main` expects
0021 and will fail on `v_operator_machines` and the new `save_worker_profile`
signature. Apply the migration first, then hand out the new APK.

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups** → *Download backup*.

## 2. Pre-flight check

Supabase dashboard → **SQL Editor** → **New query**. Paste the contents of:

```
supabase/checks/0021_preflight.sql
```

Seven rows. Rows **01** and **02** must say true:

| Row | What it means |
|---|---|
| 01. Migration 0020 applied | False → stop, apply 0020 first ([12-applying-0020.md](12-applying-0020.md)) |
| 02. 0021 not applied yet | False → already applied, skip to step 4 |
| 03–04 | How the backfill will type each person: administrators become Office, everybody else becomes Operator |
| **05** | How many operators will be able to record on any machine afterwards |
| 06 | Open assignments, all kept |
| 07 | Open assignments held by people already off the roll — see the note in step 5 |

## 3. Apply the migration

SQL Editor → **New query**. Paste the whole of:

```
supabase/migrations/0021_employee_types_and_any_machine.sql
```

One transaction in the editor, so either all of it lands or none of it does.

Or from a terminal with the database URL:

```bash
cd "supabase/tests" && npm run apply -- --only=0021
```

## 4. Verify

SQL Editor → **New query**. Paste:

```
supabase/checks/0021_verify.sql
```

Fifteen rows, every `ok` column true:

| Row | Confirms |
|---|---|
| 01–04 | Everybody has a type, no administrator was filed as an operator, the enum has its three values, the salary-day rule survived |
| 05–06 | The guard no longer consults `machine_assignments`, and now checks the employee type instead |
| 07–08 | Triggers: only an operator may hold an assignment; leaving closes it |
| 09–10 | No open assignment belongs to somebody off the roll, or to a non-operator |
| 11–13 | `v_operator_machines` exists, runs as the caller, and the roster reports the type |
| 14 | `save_worker_profile` has exactly one signature — two would be an overload PostgREST cannot choose between |
| 15 | Past production is untouched |

**If row 09 is false**, it is left over from before the trigger existed — it only
fires on a change, and does not reach back. Re-save each of those people under
**More → Employees** and it clears.

## 5. Set the employee types

Everybody is currently an operator (or Office, for administrators), because that
is what the old data said. In the admin app:

**More → Employees** — tap anybody who is actually a labourer and change
**Employee type**. They keep their salary and payslips; what they lose is the
machine screens and the ability to be assigned to a machine.

The roster now shows each person's type, their salary, and — for operators — the
machine they usually run.

## 6. Check the new entry flow

Sign in as an operator. **Material** and **Production** both now show every
running machine, with theirs marked `· yours` and already selected. Picking a
different one is allowed and says so.

An operator with **no** assignment at all can now record — before this they were
shown "You are not assigned to a machine" and could do nothing.

## 7. Hand out the new APK

The GitHub Actions workflow builds it. On a tablet the app now puts navigation
on a side rail and keeps content in a centred column; on a phone it is unchanged.

---

## If something goes wrong

**An operator still cannot record on another machine.** Verify row 05 catches
this: it means `app.assert_can_record()` did not replace. Re-run the migration.

**"Only machine operators can record production or material."** Working as
intended — that person's employee type is not Operator. Change it under
**More → Employees**, or they are a labourer and should not be recording runs.

**"X is not a machine operator, so they cannot be assigned to a machine."** Also
intended. Change their type first if they really do run machines.

**An administrator cannot be saved as an operator.** Intended: the two sides of
the app are chosen by `role`, and letting them disagree would put an
administrator on a machine roster. Make them Office, or make them an operator
rather than an administrator.
