# Phase Status

Measured against the Definition of Done in §68.

## The eight phases, and whether the database can serve them

Taken from `AppRoute`, so this table and the app cannot drift apart.

| Phase | Screens | Database |
|---|---|---|
| 1 | Login, dashboards, notifications, profile | Complete |
| 2 | Machines, Operators, Settings | Complete — **screens built**, see [06-phase-2-admin-masters.md](06-phase-2-admin-masters.md) |
| 3 | Inventory, Material Entry (admin-only since 0015) | Complete — **screens built**, see [07-phase-3-inventory.md](07-phase-3-inventory.md) |
| 4 | Production, Production Entry, My Entries | Complete |
| 5 | Dispatch | Complete |
| 6 | Wastage | Complete |
| 7 | Reports | Complete (opening/movement/closing added in 0011) |
| 8 | Staff → Punches, Salary | Complete (0012–0014, see [05-payroll.md](05-payroll.md)) |
| — | Packaging (bags), two shifts, wastage used, profile editing, operator attendance | Complete (0015, see [08-packaging-shifts-access.md](08-packaging-shifts-access.md)) |

All eight phases now have a database behind them, tested. What is left is UI:
every screen from Phase 2 onward calls an API that already exists. Both modules
the factory asked for — pipe manufacturing and salary — are built and applied.

## Phase 1 — Project foundation: **complete**

| §62 requirement | State |
|---|---|
| Flutter project | Done — `app/`, feature-based structure (§54) |
| Material 3 theme | Done — industrial palette, 52dp targets, tabular figures |
| Supabase initialisation | Done — build-time config, explicit screen when absent |
| Authentication | Done — sign in, sign out, session persistence and restoration |
| Role handling | Done — role read from `profiles`, never from the client |
| Navigation | Done — separate admin and operator shells, guarded by path prefix |
| Base architecture | Done — UI → Riverpod → repository → Supabase; no query in a widget |
| Reusable components | Done — `AsyncView`, `StatTile`, `StatusChip`, `DataRow2`, `SectionHeader`, `InlineBanner` |
| Error handling | Done — SQLSTATE-driven mapping, no raw driver text on screen |
| Loading states | Done — via `AsyncView` everywhere |
| Demo / seed data | Done — `supabase/seed*.sql`, applied and verified |

Working end to end, against real data:

- Sign in, sign out, session restore across restarts
- Admin dashboard — production, stock, consumption, dispatch, wastage, machines,
  alerts, unread count. Every figure comes from `admin_dashboard()`.
- Operator home — assignment, today's totals, material used, recent entries
- Notification centre — list, mark one read, mark all read
- Profile for both roles
- Route protection in both directions

## Pipe manufacturing module — **built and tested**

Migrations `0006`–`0010`, described in
[04-pipe-manufacturing.md](04-pipe-manufacturing.md).

| Added | Why |
|---|---|
| `pipe_products.bundle_weight_kg` | the kg ↔ bundle conversion; nothing balances without it |
| weight snapshot on `production_entries` | a spec change must not re-value past output |
| `pipe_product_weight_history` | every weight change is auditable |
| `RECYCLED` raw materials | shredded pipe is a raw material, mixed like any other |
| `shred_entries` + `shred_pipe()` | rejects at the line and bundles pulled from stock |
| `machine_products` | a machine cannot be credited with a product it cannot run |
| `v_production_material_balance` | kg in vs kg out, per machine per day |

UI for this module is not built. The API it will call is.

## Database layer — written for all phases, **executed and tested**

`supabase/tests/` applies every migration to a real Postgres (PGlite, in process)
and asserts the behaviour that matters:

```
npm test    70 manufacturing + 52 payroll, all passed
```

Including the four the whole design rests on:

- a failed shred leaves no entry row and creates no regrind
- a mixture short on one material deducts none of the others
- a retry with the same client ref returns the original record
- after every movement, the ledgers still explain every balance

A19 is closed. What remains untested is genuine multi-connection concurrency:
PGlite is a single connection, so the `FOR UPDATE` ordering is verified by
inspection, not by two racing transactions.

### The original five migrations

The schema is not limited to Phase 1: the tables, views, RLS and the atomic RPCs
for phases 3 to 6 are all written, so later phases are UI work against an API
that already exists.

| Function | Purpose |
|---|---|
| `consume_raw_materials()` | Validates the whole basket, then deducts (§16) |
| `record_production()` | Entry, weight snapshot and finished-goods increase, one transaction |
| `create_dispatch()` | Stock check, deduction, notification, atomically (§22) |
| `record_wastage()` | Applies the A8 rule for raw loss vs production scrap |
| `consume_reusable_wastage()` | Draws down reusable stock (A9 `SEPARATE` mode) |
| `add_raw_material_stock()` / `adjust_*()` | Admin stock maintenance, audited |
| `admin_dashboard()` / `operator_dashboard()` | One round trip per dashboard |

These execute cleanly and are covered by the test suite above.

## Verification performed

```
flutter analyze          No issues found
flutter test             45 tests, all passed
npm test (supabase/tests) 122 assertions, all passed
```

Test coverage is concentrated where correctness is not obvious:

- **Route protection** — every `/admin` route is refused to an operator, driven
  off `AppRoute.values` so a future admin screen is covered automatically
- **Error mapping** — each `DP00x` SQLSTATE maps to the right kind; RLS denials
  and unique violations never reach the user as raw text
- **Role parsing** — unknown, null or wrongly cased roles fail closed to operator
- **Dashboard parsing** — Postgres numerics arriving as strings, empty factory,
  operator with no machine assigned
- **Login form** — validation before any network call, obscured password

Stock arithmetic, atomicity, RLS enforcement and the RPCs are no longer a gap —
`supabase/tests` covers them against a real Postgres. What neither suite reaches
is genuine multi-connection concurrency, and the Flutter screens for phases 2
onward, which do not exist yet.

## Screens

Every route in `AppRoute` now resolves to a working screen. There are no
placeholder screens left in the app, and `PlaceholderScreen` has been deleted.

| Area | Screen | What it does |
|---|---|---|
| Admin | Dashboard | Today's production, stock, machines, alerts |
| Admin | Inventory | Raw materials, finished goods (bundles and bags), recycled stock |
| Admin | Production | Every entry, grouped by day, with filters |
| Admin | Dispatch | Buyer, vehicle, bundles and bags per product |
| Admin | Material Entry | Mixture batches — admin-only (A30) |
| Admin | Wastage | Loss vs recoverable scrap, and recording it |
| Admin | Reports | Production (incl. bags and wastage used), dispatch, wastage, closing stock |
| Admin | Products & Packaging | Type → size → pipes per bundle and per bag |
| Admin | Shifts | Morning and Night only; timings editable (A29) |
| Admin | Machines, Operators, Settings, Pipe types/sizes, Raw materials | Master data |
| Admin | Punches, Salary | Attendance and payroll |
| Operator | Home | Assignment, today's totals, attendance, recent entries |
| Operator | Production Entry | Bundles, bags, wastage used, confirmation |
| Operator | My Entries | Own last 7 days, oldest first, read-only |
| Both | Notifications, Profile (name and phone editable) | |

Punches and Salary are read-only. Marking attendance and running payroll are
real operations with real consequences, and they belong behind the same
deliberate confirmation flows the stock operations have — so these screens
surface what the payroll module computes rather than offering a half-built way
to change it.

## Recommended next step

Phase 2 (admin masters: machines, shifts, pipe types and sizes, operators) is the
natural next increment — it is straightforward CRUD against tables whose RLS
already restricts writes to admins, and it produces the data Phase 3 and 4 forms
need to populate their dropdowns.

Phase 3 is the more valuable one to reach, because `consume_raw_materials()` is
where the insufficient-stock rule (§16) becomes visible to an operator. Worth
writing an integration test against a real project at that point, since the
atomic behaviour is the part unit tests cannot reach.
