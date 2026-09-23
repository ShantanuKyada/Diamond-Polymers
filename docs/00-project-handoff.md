# Project Handoff — Diamond Polymers Factory Management

**Read this first.** It is the whole picture in one place: what the product is,
what exists, what works, what has been verified, what is still open, and how to
pick the work up without starting over.

Last updated: 23 September 2026.

---

## 1. What this is

A mobile factory-management app for a manufacturer of braided plastic pipes
(Diamond Polymers). Android-first **Flutter** app on a **Supabase** (Postgres)
backend.

Two applications behind one sign-in, chosen by the role stored in the database:

- **Admin** — factory-wide visibility: dashboard, inventory, production,
  dispatch, material entry, wastage, reports, masters, staff, settings.
- **Operator** — record production for their assigned machine, see their own
  week of entries, their attendance, and edit their own profile.

It was built from a long written specification (the "master development
prompt", §1–§68) and then extended by a September 2026 change request
(bags, two shifts, wastage used, admin-only material entry, operator
attendance, editable profile). Section references like §22 in the code and docs
point to that specification.

## 2. Where everything lives

```
Diamond-Polymers-main/
├── app/                      Flutter application (the one to build)
│   ├── lib/core/             config, theme, routing, errors, widgets, demo mode
│   ├── lib/features/         one folder per feature: data / domain / presentation
│   │     auth dashboard dispatch inventory masters mixture
│   │     notifications production reports shell staff wastage
│   ├── test/                 10 Flutter test files
│   └── tool/serve_web.mjs    serves a web build on the local network
├── supabase/
│   ├── migrations/           0001 … 0015, applied in order
│   ├── seed.sql              demo data (masters, a week of activity)
│   ├── seed_manufacturing.sql
│   └── tests/                database tests on in-process Postgres (PGlite)
├── docs/                     decisions, setup, status, module write-ups
├── .github/workflows/        build-apk.yml (live), build-demo-apk.yml (demo)
└── Diamond-Polymers-main/    ⚠ an OLDER duplicate copy — see §9
```

Size: about 16,400 lines of Dart and 7,500 lines of SQL.

## 3. Architecture in one paragraph

Screens never touch Supabase. They watch **Riverpod** providers, which call a
**repository** per feature, which calls Supabase. Every stock-changing write is
a `SECURITY DEFINER` Postgres function (RPC) that checks authorisation and
stock, then commits or rolls back as a unit — no operational table has an
INSERT policy, so an operator with the anon key and a hand-crafted request still
cannot move stock. Stock balances are a cache over append-only ledgers, and
`v_stock_reconciliation` proves the two agree. Errors carry custom SQLSTATEs
(`DP001`–`DP008`) that the app maps to plain sentences. Navigation is
`go_router`, with admin screens under `/admin` and operator screens under `/op`;
a guard keyed on that prefix keeps operators out, and row level security keeps
them out again in the database.

**Demo mode** (`--dart-define=DEMO_MODE=true`) swaps every repository for an
in-memory twin (`lib/core/demo/`) that implements the same interface and
enforces the same rules. No Supabase client is created. Every screen shows an
orange **DEMO DATA** ribbon.

## 4. Status by area

| Area | App screens | Database | Notes |
|---|---|---|---|
| Sign-in, roles, route guard | ✅ | ✅ | Session restore; operator refused `/admin/*` |
| Admin dashboard | ✅ | ✅ | One RPC round trip |
| Operator home | ✅ | ✅ | Production shortcut + **Attendance** section |
| Notifications | ✅ | ✅ | Per-person read state |
| Profile | ✅ | ✅ | **Name and phone editable** (`update_my_profile`) |
| Masters: machines, operators, settings, pipe types, sizes, raw materials | ✅ | ✅ | |
| Products & Packaging (type → size → pipes per bundle / bag) | ✅ | ✅ | |
| Shifts | ✅ | ✅ | **Morning and Night only**, times editable |
| Inventory (raw, finished bundles **and bags**, recycled) | ✅ | ✅ | |
| Material Entry | ✅ | ✅ | **Admin-only** since 0015 |
| Production Entry | ✅ | ✅ | Bundles, **bags**, **wastage used Yes/No + kg**, scrap |
| My Entries | ✅ | ✅ | **Last 7 days, oldest first**, own entries only |
| Production records (admin) | ✅ | ✅ | Filters by period, machine, operator, type |
| Dispatch | ✅ | ✅ | **Buyer, vehicle (required), bundles and bags** per product |
| Wastage | ✅ | ✅ | Material loss vs production scrap, reusable flag |
| Reports | ✅ | ✅ | Production (incl. bags, wastage used, by shift), dispatch, wastage, closing stock |
| Staff → Punches, Salary | ✅ read-only | ✅ | See §8 |
| Pipe manufacturing (weights, shredding, regrind) | partly surfaced | ✅ | `docs/04-pipe-manufacturing.md` |
| Payroll engine | read-only views | ✅ | `docs/05-payroll.md` |

There are no placeholder screens left. `PlaceholderScreen` was deleted.

## 5. Verification — the current numbers

| Check | Command | Result |
|---|---|---|
| Static analysis | `cd app && flutter analyze` | No issues |
| Flutter tests | `cd app && flutter test` | **103 passed** |
| Database tests | `cd supabase/tests && npm install && npm test` | **328 passed** (70 + 52 + 59 + 78 + 69) |
| Release APK | `flutter build apk --release …` | Builds locally in ~2–4 min |

One of those suites (`api_coverage.test.mjs`) reads every Supabase call out of
the Dart source and checks it against the schema, so an API the app calls but
the database lacks fails the build. See `docs/09-screens-and-configuration.md`.

The database tests run the real migrations on a real Postgres engine (PGlite,
in-process — no Docker needed) and cover atomicity, row level security, the
material balance, payroll, the app's exact column and parameter names, and the
upgrade of a database that still has the retired Afternoon shift.

**What these do not prove:** the live app against the live Supabase project,
end to end. Every new feature is tested at the database layer and in the UI
against demo data, but not together over the network.

## 6. The live Supabase project

- No credentials are stored anywhere in this folder, by design. A live build
  needs `SUPABASE_URL` and `SUPABASE_ANON_KEY` passed at build time.
- Earlier project notes (`docs/03-phase-status.md`) record migrations through
  **0014** and the seeds as applied to the live project. That was done in an
  earlier session and cannot be confirmed from this machine.
- **`0015_packaging_shifts_access.sql` has not been applied to the live
  project.** Until it is, a live build of the current app will fail on the new
  columns and parameters. It is written to be safe on a database with history —
  see §6 of `docs/08-packaging-shifts-access.md`.

## 7. How to run and build

```bash
# Tests
cd app && flutter analyze && flutter test
cd supabase/tests && npm install && npm test

# Frontend-only demo (no backend)
cd app
flutter run --dart-define=DEMO_MODE=true
flutter build apk --release --split-per-abi --dart-define=DEMO_MODE=true --dart-define=APP_ENV=demo

# Against the live backend
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY \
  --dart-define=APP_ENV=production
```

APKs land in `app/build/app/outputs/flutter-apk/`. Send
`app-arm64-v8a-release.apk` (~18 MB) for modern phones; `app-release.apk`
(~52 MB) installs on anything.

Demo sign-in: any password. An email containing `admin` opens the admin app;
anything else opens the operator app as Ravi Kumar on Machine 1.

The two GitHub Actions workflows build the same APKs on a Linux runner. They
only help once the project is in a GitHub repository (see §9).

Toolchain on this machine: Flutter 3.38.7, Dart 3.10.7. CI pins 3.41.6.

## 8. Decisions a reader must know

All 33 are recorded with reasons in `docs/01-ambiguities-and-decisions.md`
(A1–A23) and `docs/08-packaging-shifts-access.md` (A24–A33). The ones most
likely to be questioned:

- **A8 — wastage source.** Material lost before mixing comes off raw stock;
  scrap from a run does not (it was already consumed).
- **A20 — regrind is a raw material.** Shredded pipe is stocked and mixed like
  any other input.
- **A25 — bags are their own stock**, never converted from bundles.
- **A27 — production records bags**, because bag stock has to come from
  somewhere.
- **A28 — "wastage material used" moves no stock**; material entry already
  accounts for it.
- **A29 — two shifts**, enforced by a database trigger. Afternoon is retired,
  not deleted. Times were moved to 06:00–18:00 and 18:00–06:00.
- **A30 — Material Entry is admin-only**, refused in the UI, the router and the
  database function.
- **A32 — My Entries is oldest first** (the request said "chronological"). A
  one-line change if newest first is preferred.
- **A33 / Staff screens are read-only.** Attendance marking, punching in from
  the phone, and running payroll exist in the database (`punch_in`,
  `punch_out`, `set_attendance`, `run_payroll`, `finalise_payroll`) but have no
  screens yet.

## 9. Open items and risks

In rough order of importance:

1. **Push to a remote.** The project is now a git repository on branch `main`
   with one commit covering everything, but it exists only on this machine.
   Until it is pushed to a private remote, a disk failure still loses it, and
   the GitHub Actions workflows cannot run.
2. **Apply 0015 to the live Supabase project**, then build a live APK and walk
   through the new features against real data.
3. **Duplicate folder.** `Diamond-Polymers-main/Diamond-Polymers-main/` is an
   older copy of the app (before demo mode and the latest screens). It is not
   used by anything. Delete it once you are sure, so nobody edits the wrong
   copy.
4. **Staff actions.** No UI yet for marking attendance, operator punch in/out,
   issuing advances or running payroll — the database functions exist.
5. **Creating an operator login from the app.** Admin can create a profile and
   link it to an existing login (`link_profile_to_auth_user`); creating the
   Supabase auth user itself still happens in the Supabase dashboard. In demo
   mode, linking a login shows a "needs the live backend" message.
6. **DEMO DATA ribbon** is on every screen of the demo APK — deliberate, easy to
   remove if unwanted for client demos.
7. **Demo data does not persist.** Restarting the demo app restores the seed.
8. **APKs are signed with the debug key.** Fine for sideloading; a Play Store
   release needs a proper signing key.
9. Not modelled at all, by design: recipes and expected yield, repacking
   bundles into bags, mixture-to-production linkage, accounting, GST, CRM.

## 10. Picking the work up

1. Read this file, then `docs/08-packaging-shifts-access.md` for the latest
   change set.
2. Run both test suites (§7). If both are green, the codebase is in the state
   described here.
3. For any schema change: add `0016_…sql`, add it to the file list in
   `supabase/tests/harness.mjs`, add checks to a test file, and add any new
   columns or RPC parameters the app uses to `app_contract.test.mjs`.
4. For any new repository method: implement it in the demo twin under
   `app/lib/core/demo/` as well — the compiler will insist.
5. Every write goes through an RPC with a `p_client_ref` so retries are safe.
   Do not add INSERT, UPDATE or DELETE policies on operational tables.

## 11. Document index

| File | What it covers |
|---|---|
| `00-project-handoff.md` | This overview |
| `01-ambiguities-and-decisions.md` | Decisions A1–A23 with reasoning |
| `02-setup.md` | Creating the project, applying migrations, linking logins |
| `03-phase-status.md` | Phase-by-phase status and the screen list |
| `04-pipe-manufacturing.md` | Bundle weights, shredding, regrind, machine capabilities |
| `05-payroll.md` | Attendance and payroll module |
| `06-phase-2-admin-masters.md` | Master-data screens |
| `07-phase-3-inventory.md` | Inventory and material entry |
| `08-packaging-shifts-access.md` | September 2026 change request, A24–A33, verification |
| `09-screens-and-configuration.md` | Screen inventory, what is configurable, what stays a literal |
