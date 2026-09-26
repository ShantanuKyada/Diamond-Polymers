# Context

A handoff document. Everything a new session needs to pick this up without
re-deriving it, and the things that are easy to get wrong.

Last updated: 14 September 2026, at commit `cb9b9ba` on `main`.

---

## What this is

Factory management for **Diamond Polymers**, a braided plastic pipe factory.
Flutter (Android-first) on Supabase. Two applications behind one sign-in:
**Admin** (factory-wide) and **Operator** (record a batch in a couple of taps).

Two modules were asked for:

1. **Pipe manufacturing** — raw material in by the kilogram, pipe out in
   bundles, defective pipe shredded and fed back in as material.
2. **Employee salary** — monthly pay prorated by attendance.

Both have a complete, tested database behind them. The remaining work is UI.

```
app/                     Flutter application
supabase/migrations/     0001–0014, run in order
supabase/seed*.sql       demo data
supabase/tests/          runs the migrations against a real Postgres and tests them
docs/                    decisions, setup, and one file per module/phase
.github/workflows/       build-apk.yml
```

- Repo: `ShantanuKyada/Diamond-Polymers` (public). Push access is via the
  `vedant-chauhan` account.
- Supabase project: `rlldysoukevcumhmtmdm`, PostgreSQL 17.6, schema applied and
  seeded.

---

## Read these first

| Doc | What it covers |
|---|---|
| [docs/01-ambiguities-and-decisions.md](docs/01-ambiguities-and-decisions.md) | Every place the spec was ambiguous, decided, with reasons. A1–A23. |
| [docs/02-setup.md](docs/02-setup.md) | Create the project, apply the schema, link logins, run the app |
| [docs/03-phase-status.md](docs/03-phase-status.md) | Phase-by-phase state |
| [docs/04-pipe-manufacturing.md](docs/04-pipe-manufacturing.md) | Weights, the shredding loop, material balance |
| [docs/05-payroll.md](docs/05-payroll.md) | Attendance, proration, advances, pay privacy |
| [docs/06-phase-2-admin-masters.md](docs/06-phase-2-admin-masters.md) | Phase 2 screens |
| [docs/07-phase-3-inventory.md](docs/07-phase-3-inventory.md) | Phase 3 screens |

---

## Where the work stands

The app has **8 phases**, taken from `AppRoute` and the phase badge each
placeholder screen shows.

| Phase | Screens | Database | UI |
|---|---|---|---|
| 1 | Login, dashboards, notifications, profile | ✅ | ✅ |
| 2 | Machines, Operators, Settings, Products, catalogues | ✅ | ✅ |
| 3 | Inventory, Raw Material Entry | ✅ | ✅ |
| 4 | Production records, Production Entry, My Entries | ✅ | ❌ **next** |
| 5 | Dispatch | ✅ | ❌ |
| 6 | Wastage | ✅ | ❌ |
| 7 | Reports | ✅ | ❌ |
| 8 | Staff → Punches, Salary | ✅ | ❌ |

**Every phase has a tested API already.** Phases 4–8 are UI work against
functions that exist, are applied to the live project, and are covered by tests.

Routes still on `PlaceholderScreen`: `adminProduction`, `productionEntry`,
`myEntries` (Phase 4), `adminDispatch` (5), `adminWastage` (6), `adminReports`
(7), `adminStaffPunches`, `adminStaffSalary` (8).

---

## The rules the design rests on

These are not style preferences. Breaking one causes a class of bug that is very
hard to find later.

**Inventory correctness comes before everything.**

- **Every stock movement is one `SECURITY DEFINER` function.** No operational
  table grants INSERT to a client. An operator with a stolen anon key and a
  hand-crafted REST call cannot move a gram of stock — there is no policy that
  permits the write.
- **Ledgers are the truth; balances are a cache.** Every movement row carries
  `previous` and `resulting`, with a `CHECK` that they agree with the delta.
  `v_stock_reconciliation` re-derives each balance from history, so the cache can
  be *proven* correct. It should always return zero rows.
- **Nothing partially executes.** A mixture short on one material deducts none of
  the others.
- **Nothing is overwritten.** Ledgers and entry tables have no UPDATE or DELETE
  policy for anyone, admins included. Corrections are reversing entries.
- **Retries are safe.** Every write RPC takes `p_client_ref`; the same reference
  returns the existing record instead of creating a second one.

**Lock order, to avoid deadlock:**

```
finished_goods_stock  →  raw_material_stock  →  reusable_wastage_stock
```

and within raw materials, ascending id. `shred_pipe()` is the only operation
that moves finished goods and raw material together, which is what makes this
load-bearing rather than merely tidy.

**Master data is the exception.** `machines`, `shifts`, `pipe_types`,
`pipe_sizes`, `raw_materials`, `profiles`, `app_settings`, `machine_products`,
`pipe_products` grant `for all` to admins and are written directly from the app.
They describe the factory rather than record what happened in it.

---

## The two module-specific ideas

**A bundle has a weight** (`pipe_products.bundle_weight_kg`). It is the only
bridge between kilograms in and bundles out — without it, "we consumed 900 kg and
made 30 bundles" is not a statement anyone can check. It is `NOT NULL`, and
production of a product without one is refused (`DP008`). Entries **snapshot**
the weight they used, so retuning a spec cannot re-value last month's output.

**Shredded pipe is a raw material**, not a separate inventory. Regrind is an
ordinary `raw_materials` row with `is_recycled = true`, held in
`raw_material_stock` in kg, mixed by `consume_raw_materials()` with no special
case. One pool per grade (`pipe_types.recycled_material_id`) so black regrind
cannot end up in a white pipe.

`v_production_material_balance` then answers the question the whole system
exists for: `consumed − produced − wastage − regrind = unaccounted`.

---

## Error codes

The database raises documented SQLSTATEs so the UI never string-matches Postgres
internals. `app/lib/core/error/app_exception.dart` maps them.

| Code | Meaning | Maps to |
|---|---|---|
| `DP001` | Insufficient raw material | `insufficientStock` |
| `DP002` | Insufficient finished goods | `insufficientStock` |
| `DP003` | Insufficient reusable wastage | `insufficientStock` |
| `DP004` | Not authorised | `authorization` |
| `DP005` | Invalid input | `validation` |
| `DP006` | Operator not assigned to that machine | `authorization` |
| `DP007` | Feature not configured | `notConfigured` |
| `DP008` | No bundle weight for that product | `notConfigured` |
| `DP009` | Machine not set up to run that product | `validation` |
| `DP010` | Advance over-recovery | `insufficientStock` |
| `DP011` | Payroll month already finalised | `conflict` |

Adding a value to `AppErrorKind` breaks an exhaustive `switch` in
`core/widgets/state_views.dart`. That is the compiler doing its job — add the
case.

---

## Assumptions the factory should confirm

Each is an `app_settings` key, read in exactly one place, changeable without a
migration. Getting one wrong costs money, so they are called out rather than
buried.

| Key | Default | What it assumes |
|---|---|---|
| `payroll_unmarked_day_policy` | `PAYABLE` | A day with no attendance row is **paid**. Factories mark exceptions; the opposite default would silently halve wages the first month somebody was slow with attendance. |
| `payroll_proration_basis` | `CALENDAR_DAYS` | Basic = monthly × payable ÷ days in month |
| `payroll_overtime_multiplier` | `2.0` | Statutory factory rate in India |
| `payroll_fixed_days` | `26` | Divisor for the derived hourly rate |
| `shred_recovery_tolerance_pct` | `20` | Headroom on the mass-conservation check |
| `factory_timezone` | `Asia/Kolkata` | Report day boundaries. Supabase runs in UTC and a factory day is not a UTC day. |
| `enforce_machine_product` | `true` | A machine with no configured products is unconstrained |

Also assumed: production wastage is **kilograms of scrap** and does *not* reduce
bundle count (A7); and `RAW_MATERIAL_LOSS` deducts raw stock while
`PRODUCTION_SCRAP` does not, because that material already left stock when it
entered a mixture (A8 — the most likely rule to need correction).

---

## Architecture of the Flutter app

```
lib/core/       config, theme, routing, errors, shared widgets
lib/features/<feature>/
   domain/      plain value types with a `.from(Map)` factory
   data/        repository + Riverpod providers; the ONLY place that touches Supabase
   presentation/ ConsumerWidgets, AsyncView, RefreshIndicator
```

- No query in a widget. Repositories funnel every call through `ErrorMapper`, so
  a raw `PostgrestException` cannot reach a screen.
- Route protection keys off the `/admin` path prefix, so a screen is protected by
  **where it sits**, not by anyone remembering a check. `route_guard_test`
  iterates `AppRoute.values`, so a new admin route is covered automatically.
- Shared widgets live in `core/widgets/`: `AsyncView`, `StatTile`, `StatusChip`,
  `SectionHeader`, `DataRow2`, `EmptyView`, `InlineBanner`. Master screens share
  `features/masters/presentation/widgets/master_scaffold.dart`
  (`MasterScaffold`, `showEditSheet`, `SheetField`, `SheetDropdown`).

**Postgres numerics arrive over PostgREST as `String`, not `num`.** Every model
parses both. Parsed as `num` they silently become zero, which on a stock screen
is the worst kind of failure — it looks like an answer.

---

## Testing

```bash
cd app && flutter analyze && flutter test        # 69 tests
cd supabase/tests && npm install && npm test     # 171 assertions, 3 suites
```

`supabase/tests/` applies all 14 migrations to a real Postgres compiled to
WebAssembly (PGlite) — no Docker, no Supabase CLI, no network.

| Suite | Covers |
|---|---|
| `manufacturing.test.mjs` | atomicity, idempotency, RLS, material balance (70) |
| `payroll.test.mjs` | proration, advances, finalise, pay privacy (52) |
| `app_contract.test.mjs` | **the Dart↔SQL contract** (49) |

The contract suite is the one worth understanding. Dart has no idea whether
`pipe_product_id` exists until PostgREST returns a 400 on a real handset, and
**PostgREST binds RPC arguments by name**, so a renamed parameter fails the same
silent way. It copies every column list and parameter name out of the
repositories and runs them against the real schema. It also pins the *shape* of
the `p_lines` jsonb payload, where a renamed key would pass every signature check
and still fail on the floor.

**If you rename a column or an RPC parameter, that suite tells you which query
has to change.** Keep it updated as new screens are built.

Not covered anywhere: genuine multi-connection concurrency (PGlite is a single
connection), and driving the screens against live rows.

---

## Applying migrations

```bash
cd supabase/tests
PGHOST=db.rlldysoukevcumhmtmdm.supabase.co PGUSER=postgres PGDATABASE=postgres \
  PGPASSWORD='...' node apply.mjs --from=0015
```

- `--from=NNNN` / `--only=NNNN` for incremental work. The full list only replays
  against an empty database, because `0001` creates types unconditionally.
- `--reset` drops and recreates `public` and `app`. It refuses once any auth user
  exists.
- `0006` must run **outside a transaction** — it adds enum values, and Postgres
  will not let a new label be used in the transaction that created it. `apply.mjs`
  already handles this.
- Pass credentials as `PGHOST`/`PGPASSWORD` rather than a URL: the password
  contains `*` and `!`, which a URL mangles, and the failure looks like a wrong
  password.

**The database password used during development was pasted into a chat
transcript and must be treated as compromised.** Reset it under Project Settings
→ Database if that has not already been done.

---

## Building an APK

**Use CI.** An APK cannot be built on the current Windows machine: Gradle needs
`java.nio.channels.Selector`, which on Windows is implemented with a socket pair,
and something there blocks it —

```
Pipe.open()     OK
Selector.open() java.io.IOException: Unable to establish loopback connection
```

It is not Flutter, the SDK, memory or a sandbox: a bare JVM fails too, and
Android Studio will not build either. The fix is `netsh winsock reset` as
administrator plus a reboot, or an antivirus exclusion for the Android Studio
`java.exe`. **This is not required** — CI sidesteps it.

```bash
gh workflow run "Build APK" --ref main \
  -f supabase_url=https://rlldysoukevcumhmtmdm.supabase.co \
  -f supabase_anon_key=sb_publishable_IV_b4ciKsmfha5domm0XZQ_JF9qN7MR
```

Or **Actions → Build APK → Run workflow**. Setting `SUPABASE_URL` and
`SUPABASE_ANON_KEY` as repository secrets makes every push to `main` build one.

Three APKs are produced: `app-arm64-v8a-release.apk` (~19 MB, any phone from
~2015 — the usual choice), `app-armeabi-v7a-release.apk` (~17 MB), and the
universal `app-release.apk` (~53 MB).

The publishable key is designed to ship inside a client app. The **service-role
key must never** be built into the APK.

For quick testing without an APK, `node app/tool/serve_web.mjs` serves a web
build on the local network so a phone can open it over WiFi.

---

## Accounts

The seed creates staff **profiles** but no logins, because an operator can exist
as a factory record with no app account (A3) — common where one shared handset
sits on the floor.

Creating an auth user needs the admin API and a service-role key, which must not
ship in the app. So: create the user in **Supabase → Authentication → Users**
with *Auto Confirm User* ticked, then attach it from **Operators → ⋮ → Attach a
login**, which calls `link_profile_to_auth_user()`.

Currently linked: `chauhanvedant34@gmail.com` → `EMP-001` Factory Admin.

**There is no operator login yet.** Raw Material Entry cannot be exercised until
one exists and is assigned to a machine.

---

## Things that cost time to discover

- **`find.text` does not match `Text.rich`.** Pass `findRichText: true`, or the
  test fails on a widget that is plainly on screen.
- **Riverpod 3 keeps `Override` sealed and out of its public exports.** A test
  helper cannot name the type; take `List<Object>` and `.cast()`. Adding the
  `riverpod` package does not help — it is not exported there either.
- **The default widget-test surface is 800×600**, wider than any phone. Overflow
  bugs only appear if a test calls `setSurfaceSize(const Size(360, 780))`.
- **An UPDATE or DELETE that RLS forbids affects zero rows silently** — Postgres
  only raises `42501` on a WITH CHECK violation. Assert the data is unchanged,
  not that an error was thrown.
- **Test the positive, not only the leak.** An admin-only policy on
  `payroll_periods` looked safer and silently hid every worker's own payslip from
  them, because `security_invoker` views join that table. Only a test asserting a
  worker *can* see their own payslip caught it.
- **The seed data was physically impossible** before bundles had weights — 2.3
  tonnes of pipe out of a 67 kg batch. It now sizes each mixture from the
  production it yields, and opening stock is derived from what the month
  consumes. A regression test asserts every seeded machine-day yields 90–100%
  and balances to within a kilogram.
- Views must be created `WITH (security_invoker = on)`, or they run as their
  owner and hand every user the whole table.

---

## Suggested next step

**Phase 4 — Production Entry, production records, My Entries.**

It is the natural next increment: `record_production()` exists, snapshots the
bundle weight, enforces machine capability (`DP009`) and refuses a product with
no weight (`DP008`). Phase 3 already built the pattern the operator form should
follow — assignment-driven context, a confirmation summary, and a submission
reference reused across retries.

`shred_pipe()` also has no UI yet and belongs near production, since a reject at
the line is recorded by the same person in the same minute.

When building it, follow the Phase 3 mixture screen for the idempotency
handling — `_attemptRef ??= ...`, reused on retry, cleared only on success. It
carries a comment saying why, because it is exactly the kind of line somebody
tidies into a double-deduction bug.
