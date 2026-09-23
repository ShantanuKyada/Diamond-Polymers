# Diamond Polymers — Factory Management

Production, inventory, dispatch and wastage tracking for a braided plastic pipe
factory. Flutter (Android-first) on Supabase.

Two applications behind one sign-in:

- **Admin** — factory-wide visibility, inventory, dispatch, master data
- **Operator** — record production, see their own week and attendance, edit their profile

> **Start with [docs/00-project-handoff.md](docs/00-project-handoff.md)** — the
> complete current picture: what is built, what is verified, what is open, and
> how to pick the work up.

## Status (September 2026)

**Every screen in the app is built** — no placeholders remain — and runs either
against Supabase or entirely offline in demo mode. The September change request
(bags alongside bundles, two shifts, wastage used, admin-only material entry,
operator attendance, editable profile) is complete.

- Flutter: `flutter analyze` clean, **103 tests** passing.
- Database: migrations `0001`–`0015` run on a real Postgres in process, **259
  checks** passing.
- `0015` has **not yet been applied** to the live Supabase project.
- The folder is **not under version control** yet.

Module write-ups: [pipe manufacturing](docs/04-pipe-manufacturing.md),
[payroll](docs/05-payroll.md),
[packaging, shifts and access](docs/08-packaging-shifts-access.md).

## See it running in one command

```bash
cd app && flutter run --dart-define=DEMO_MODE=true
```

The whole UI against in-memory data — no Supabase project needed. Any password;
an address containing `admin` opens the admin app. See
[docs/02-setup.md](docs/02-setup.md) for the real setup.

## Start here

1. [docs/02-setup.md](docs/02-setup.md) — create the project, apply the schema,
   link logins, run the app
2. [docs/04-pipe-manufacturing.md](docs/04-pipe-manufacturing.md) — the
   manufacturing loop: weights, shredding, material balance
3. [docs/05-payroll.md](docs/05-payroll.md) — attendance and payroll: proration,
   advances, and why pay privacy needed care
4. [docs/01-ambiguities-and-decisions.md](docs/01-ambiguities-and-decisions.md) —
   every place the spec was ambiguous, what was decided, and why
5. [docs/03-phase-status.md](docs/03-phase-status.md) — phase-by-phase state

## The rules the design is built around

Inventory correctness comes before everything else (§66), which drives most of
the structure:

- **Every stock movement is a database transaction.** No table grants an INSERT
  policy for operational data — writes go through `SECURITY DEFINER` functions
  that validate authorisation and stock, then commit or roll back as a unit. An
  operator with a stolen anon key and a hand-crafted REST call still cannot move
  a gram of stock.
- **Ledgers are the truth; balances are a cache.** Every movement records
  `previous` and `resulting` quantities, with a `CHECK` that they agree with the
  delta. `v_stock_reconciliation` re-derives each balance from history so the
  cache can be proven correct.
- **Nothing partially executes.** A mixture short on one material deducts none of
  the others.
- **Nothing is overwritten.** Ledgers and entries are append-only; corrections
  are reversing entries.
- **Retries are safe.** Every write RPC takes a client reference; the same
  reference returns the existing record instead of creating a second one.

## Layout

```
app/                    Flutter application
supabase/migrations/    schema, helpers, views, RPCs, RLS  (run in order)
supabase/seed*.sql      demo data
supabase/tests/         runs the migrations against a real Postgres and tests them
docs/                   decisions, setup, phase status, manufacturing
```

## Commands

```bash
cd app
flutter analyze
flutter test
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

```bash
cd supabase/tests
npm install
npm test                                              # 122 assertions, no network
DATABASE_URL="postgresql://..." npm run apply -- --seed
```
