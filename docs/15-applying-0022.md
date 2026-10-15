# Applying migration 0022 to the live project

`0022_employee_roles_master.sql` turns the three fixed employee types into a
master table the factory can add to — a supervisor, a helper, a fitter,
whatever the roll actually has.

Reasoning is in [`08-packaging-shifts-access.md`](08-packaging-shifts-access.md)
under A41. Roughly five minutes.

---

## Read this first

**Nothing is lost.** Every profile keeps the role it already has, carried across
by code. What is dropped is the old enum column — after the people on it have
been moved to the new reference, which the preflight checks in advance.

**The app and the database move together.** An APK built from `main` expects
0022 and will fail on `employee_types` and the new `save_worker_profile`
signature. Apply the migration first, then install.

**Apply 0021 first** if you have not — [13-applying-0021.md](13-applying-0021.md).

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups** → *Download backup*.

## 2. Pre-flight check

**SQL Editor → New query**, paste:

```
supabase/checks/0022_preflight.sql
```

Five rows. Rows **01** and **02** must say true:

| Row | What it means |
|---|---|
| 01. Migration 0021 applied | False → stop, apply 0021 first |
| 02. 0022 not applied yet | False → already applied, skip to step 4 |
| 03 | Who is on each role today, for comparison afterwards |
| **04** | Every role in use is one the migration knows how to carry across. False → tell me before going on |
| 05 | Machine assignments, all unaffected |

## 3. Apply the migration

**SQL Editor → New query**, paste the whole of:

```
supabase/migrations/0022_employee_roles_master.sql
```

One transaction — all of it lands or none does.

Or from a terminal with the database URL:

```bash
cd "supabase/tests" && npm run apply -- --only=0022
```

## 4. Verify

**SQL Editor → New query**, paste:

```
supabase/checks/0022_verify.sql
```

Sixteen rows, every `ok` true:

| Row | Confirms |
|---|---|
| 01–02 | Roles are a table, and the three that existed came across |
| 03–04 | Everybody points at a role, and nobody changed role on the way |
| 05 | The old enum and its column are gone |
| 06 | A direct insert into `profiles` still works |
| 07–08 | Exactly one built-in role, and at least one that runs machines |
| 09 | The guard reads the role's own flag, not a list of names |
| 10–11 | A role that stops running machines frees its people |
| 12–13 | Both functions have one signature, taking a role code |
| 14–16 | The read models and the read policy are in place |

## 5. Add your own roles

In the admin app: **More → Employee roles → +**

| Field | What it does |
|---|---|
| **Role name** | What people see. A short code is made from it automatically and never changes, so renaming later is safe. |
| **Description** | Shown to whoever is filling in an employee's details. |
| **Runs machines** | The one that matters — see below. |
| **In use** | Switch off to retire a role. Only possible once nobody active is on it. |

**"Runs machines" decides everything else.** Turn it on and people on that role
get the Material and Production screens, can be put on a machine, and can record
runs. Leave it off and they are on the payroll and nothing more.

Turning it **off** on a role people already hold closes their machine
assignments, the same as moving somebody off operator work does.

**Operator cannot be switched off or grounded.** A factory with no
machine-running role is one where nobody can record production, so that one
switch is held down. You can still rename it.

## 6. Put people on the new roles

**More → Employees** — the type dropdown now lists whatever you created.

## 7. Hand out the new APK

Note the APK still needs an uninstall-first unless you have set up the signing
key — see [14-signing-the-apk.md](14-signing-the-apk.md).

---

## If something goes wrong

**"There is no role called X."** The code is derived from the name, so
`Shift Supervisor` becomes `SHIFT_SUPERVISOR`. Check **More → Employee roles**
for what it actually is.

**"N people are on the X role, so it cannot be switched off."** Working as
intended. Move them to another role first; the role is never deleted because
the people who held it still have a history.

**"Operator has to keep running machines."** Also intended — see step 5.

**An administrator cannot be saved on a machine-running role.** Unchanged from
A40: the app's two sides are chosen by access level, and letting them disagree
would put an administrator on a machine roster.
