# Setup

## What state this is in

Phase 1 is implemented and the full database layer is written, including the pipe
manufacturing module (see [04-pipe-manufacturing.md](04-pipe-manufacturing.md)).

The SQL is no longer unrun. `supabase/tests/` executes the entire migration chain
against a real Postgres compiled to WebAssembly and exercises it — 122 assertions,
all passing, no Docker and no network required. A19 is closed.

## 0. Just want to see the app? Demo mode

Runs the entire UI against in-memory data. No Supabase project, no migrations,
no network:

```bash
cd app
flutter run --dart-define=DEMO_MODE=true
```

Or as a web build served to a phone on the same WiFi:

```bash
cd app
flutter build web --dart-define=DEMO_MODE=true
node tool/serve_web.mjs
```

Sign in with **any password**. An address containing `admin` opens the admin
application; anything else opens the operator application.

Every screen carries a `DEMO DATA` ribbon, because demo figures look exactly
like real ones and a screenshot of them must never be mistaken for production.
Nothing entered is saved — a reload restores the seeded state.

Demo mode swaps only the repository layer (`lib/core/demo/`). The router,
screens, controllers, validation and error handling are the real ones, and the
fakes enforce the same rules the database does: a mixture short on one material
deducts none of the others, a repeated client reference is reported as a
duplicate, and no adjustment can drive a balance below zero. `linkLogin` is the
one operation that refuses outright, because it genuinely needs a service-role
key.

This is for showing the app, not for testing the database. Everything below is
still required before it is any use to the factory.

## 1. Create a Supabase project

Any region. Note the project URL and the **anon / publishable** key from
*Project Settings → API*. The service-role key is never used by this app and must
not be built into it (§56).

## 2. Check the SQL before it touches anything

```bash
cd supabase/tests
npm install
npm test
```

Expect `70 passed` then `52 passed`, both with no failures. This runs every
migration in order and then tests the behaviour that matters — failed shreds
leaving no trace, short mixtures deducting nothing, retries returning the
original record, a recalculated payroll draft not recovering an advance twice,
and no worker able to read another's pay.

## 3. Apply the schema

Either let the script do it:

```bash
cd supabase/tests
DATABASE_URL="postgresql://..." npm run apply -- --seed
```

The connection string is in the Supabase dashboard under **Connect**. The script
reads it from the environment, wraps each file in its own transaction, and
finishes by proving the ledgers explain every balance.

If the password contains `*`, `!`, `#` or `@`, a URL will mangle it and the
failure looks like a wrong password. Pass the parts separately instead — the
direct host needs no region, unlike the pooler:

```bash
PGHOST=db.YOUR-REF.supabase.co PGUSER=postgres PGDATABASE=postgres \
  PGPASSWORD='...' node apply.mjs --seed
```

On Windows that is bash syntax: use Git Bash, or set `$env:PGPASSWORD` on a
preceding line in PowerShell. `cmd.exe` supports neither.

Add `--reset` to drop and recreate the `public` and `app` schemas first. It
refuses to run once any auth user exists, on the assumption that a project with
logins has real data behind them.

Or paste each file into the Supabase SQL editor, **in order**, as separate
executions:

```
supabase/migrations/0001_schema.sql               tables, enums, constraints, indexes
supabase/migrations/0002_helpers.sql              identity helpers and ledger movement
supabase/migrations/0003_views.sql                read models
supabase/migrations/0004_rpc.sql                  the atomic write API
supabase/migrations/0005_rls.sql                  row level security and grants
supabase/migrations/0006_manufacturing_enums.sql  enum extensions — run ALONE
supabase/migrations/0007_manufacturing_schema.sql products, weights, shred log
supabase/migrations/0008_manufacturing_rpc.sql    shred_pipe, record_production
supabase/migrations/0009_manufacturing_views.sql  material balance
supabase/migrations/0010_manufacturing_rls.sql    RLS and grants for the above
supabase/migrations/0011_reporting_and_identity.sql  reports, profile linking
supabase/migrations/0012_payroll_schema.sql       attendance, advances, payslips
supabase/migrations/0013_payroll_rpc.sql          punches, payroll run, finalise
supabase/migrations/0014_payroll_views_rls.sql    payroll RLS — privacy lives here
supabase/migrations/0015_packaging_shifts_access.sql  bags, two shifts, admin-only material entry
supabase/seed.sql                                 demo data
supabase/seed_manufacturing.sql                   products, weights, a closed loop
```

Order matters: 0005 grants `EXECUTE` on functions that 0004 creates, 0010 re-grants
`record_production` after 0008 replaces it, and the seeds call helpers from 0002.

**0006 must be run on its own**, not pasted together with another file. It adds
enum values, and Postgres will not let a new label be used in the same
transaction that created it.

Then confirm the ledgers agree with the cached balances:

```sql
select * from public.v_stock_reconciliation where not ok;
```

Zero rows is correct. Any row means a stock movement wrote a balance that its
ledger does not explain.

## 3. Create logins and link them to profiles

The seed creates staff *profiles* but no logins, because an operator can exist as
a factory record without an app account (A3).

**Dashboard → Authentication → Users → Add user**, with *Auto Confirm User*
ticked:

| Email | Links to | Role |
|---|---|---|
| `admin@diamondpolymers.local` | EMP-001 Factory Admin | ADMIN |
| `ravi@diamondpolymers.local` | EMP-101 Ravi Kumar | OPERATOR |

Then link each one. Signed in as an administrator, the app calls:

```sql
select public.link_profile_to_auth_user('EMP-001', 'admin@diamondpolymers.local');
select public.link_profile_to_auth_user('EMP-101', 'ravi@diamondpolymers.local');
```

It matches the email case-insensitively and refuses to move a login that already
belongs to another employee, which a raw UPDATE would do silently — locking that
person out with nothing recorded about why.

For the very first administrator there is no signed-in admin yet, so run the
UPDATE by hand once in the SQL editor to bootstrap:

```sql
update public.profiles p
set    auth_user_id = u.id
from   auth.users u
where  u.email = 'admin@diamondpolymers.local'
  and  p.employee_code = 'EMP-001';
```

Signing in with an account that has no linked profile is handled gracefully — the
app says so and signs you back out rather than showing an empty shell.

## 4. Run the app

```bash
cd app
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

Without those defines the app opens a "Backend not configured" screen explaining
what to pass — it does not show a login form that could never work (§65).

To avoid retyping them, put them in `app/.vscode/launch.json` or use a
`--dart-define-from-file` JSON file. Do not commit either.

## 5. Verify

```bash
cd app
flutter analyze     # expect: No issues found
flutter test        # expect: All tests passed
```

Then, signed in:

- **As admin** — the dashboard shows seeded production, stock, machines and
  alerts; Chemical should read LOW against its 400 kg threshold. Notifications
  contains the seeded dispatch and welcome messages.
- **As an operator** — home shows Machine 1, the Morning shift, today's bundles
  and recent entries.
- **Route protection** — while signed in as the operator, navigate to
  `/admin/dashboard`. You are returned to the operator home.

## Project layout

```
app/                        Flutter application
  lib/core/                 config, theme, routing, errors, shared widgets
  lib/features/<feature>/   data / domain / presentation per feature
  test/                     unit and widget tests
supabase/migrations/        schema, helpers, views, RPCs, RLS
supabase/seed*.sql          demo data
supabase/tests/             migration runner and database tests
docs/                       decisions, setup, phase status
```

## Notes for the next phase

- Every write goes through an RPC. There is deliberately no INSERT policy on any
  operational table, so a new form must call a function rather than insert a row.
- Pass a fresh `p_client_ref` UUID per submission attempt and reuse it on retry;
  that is what makes a double tap safe (§47).
- Do not add UPDATE or DELETE to ledger tables. Corrections are reversing entries.
