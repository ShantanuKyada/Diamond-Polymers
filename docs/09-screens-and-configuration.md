# Screen Inventory and Configuration Audit

Written for a team taking this codebase over. Two questions answered:

1. **Is every screen actually built?** Yes — 25 routes, 26 routed screens, plus
   6 sheets and sub-screens. None is a stub.
2. **Is anything hard-coded that should not be?** Everything a factory would
   want to change now comes from the database or a build flag. What is left as a
   literal, and why, is listed in §3.

Verified on 23 September 2026. `flutter analyze` clean, 103 app tests, 328
database checks.

---

## 1. Screens

Every route in `AppRoute` resolves to a real screen; there are no placeholder
widgets left in the codebase (`PlaceholderScreen` was deleted). Each screen
loads real data through a repository and has loading, error and empty states via
`AsyncView`.

### Operator (`/op/*`)

| Screen | Route | Data source |
|---|---|---|
| Home | `/op/home` | `operatorDashboardProvider` → `operator_dashboard()`, `myAttendanceProvider` → `v_attendance_days` |
| Production Entry | `/op/production` | `record_production()`; masters for shifts, types, sizes, products |
| My Entries | `/op/entries` | `myProductionProvider` → `v_production_entries`, last 7 days |
| Profile | `/op/profile` | `currentUserProvider`; edits via `update_my_profile()` |

### Admin (`/admin/*`)

| Screen | Route | Data source |
|---|---|---|
| Dashboard | `/admin/dashboard` | `admin_dashboard()` |
| Inventory | `/admin/inventory` | `v_raw_material_stock`, `v_finished_goods_stock`, `v_recycled_material_stock` |
| Production records | `/admin/production` | `v_production_entries` with filters |
| Dispatch | `/admin/dispatch` | `v_dispatch_lines`; creates via `create_dispatch()` |
| Material Entry | `/admin/material` | `consume_raw_materials()` |
| Wastage | `/admin/wastage` | `v_wastage_entries`; creates via `record_wastage()` |
| Reports | `/admin/reports` | production, dispatch, wastage and stock reads for a period |
| Machines | `/admin/machines` | `machines`, `v_current_machine_assignments` |
| Operators | `/admin/operators` | `profiles`, assignments, `link_profile_to_auth_user()` |
| Punches | `/admin/staff/punches` | `v_attendance_days`, `v_monthly_attendance` |
| Salary | `/admin/staff/salary` | `v_payslips`, `v_staff_advances` |
| Settings | `/admin/settings` | `app_settings` |
| Products & Packaging | `/admin/settings/products` | `v_pipe_products`; saves via `upsert_pipe_product()` |
| Pipe types | `/admin/settings/pipe-types` | `pipe_types` |
| Pipe sizes | `/admin/settings/pipe-sizes` | `pipe_sizes` |
| Raw materials | `/admin/settings/materials` | `v_raw_material_stock`, `raw_materials` |
| Shifts | `/admin/settings/shifts` | `shifts` (Morning and Night only) |

### Shared and nested

`/splash`, `/login`, `/notifications`, `/profile`, plus `NewDispatchScreen`,
`RecordWastageScreen`, `EditProfileSheet`, and the confirmation and filter
sheets, which are pushed rather than routed.

## 2. What is configurable, and where

### From the database, at runtime — `app_settings`

Read through `features/masters/data/settings_values.dart`, which exposes one
provider per value with a fallback, so a missing row can never blank a label.
An administrator edits these in **Settings**.

| Key | Used by | Fallback |
|---|---|---|
| `factory_name` | app bar and reports | `AppConfig.factoryName` |
| `production_wastage_unit` | production entry, dashboard wastage tiles | `kg` |
| `currency_symbol` | payslips and advances | `₹` |
| `reusable_wastage_mode` | `consume_reusable_wastage()` (A9) | `SEPARATE` |
| `enforce_machine_product` | `record_production()` (A23) | `true` |
| `shred_recovery_tolerance_pct` | `shred_pipe()` (A22) | `20` |
| `factory_timezone` | attendance work dates | `Asia/Kolkata` |
| `low_stock_banner_enabled` | dashboard banner | `true` |

### From master data, not code

Machines, shifts (the two), pipe types, pipe sizes, products and their
packaging, raw materials, staff, machine assignments, reorder thresholds and
bundle weights are all rows an administrator maintains. No screen contains a
machine name, a product, a size or a person.

### At build time — `--dart-define`

| Flag | Purpose | Default |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | backend connection | none — app shows a configuration screen |
| `FACTORY_NAME` | name before sign-in, and fallback after | `Diamond Polymers` |
| `DEMO_MODE` | run with no backend at all | `false` |
| `APP_ENV` | environment label | `development` |

## 3. Literals that remain, deliberately

- **Field labels, button text, help sentences, icons, spacing, colours.** UI
  copy and layout belong in the widget. The theme (`core/theme/app_theme.dart`)
  holds every colour and the type scale; no screen defines its own palette.
- **`'Morning'` / `'Night'`** in the shifts screen's icon choice and subtitle.
  The two-shift rule is enforced by a database trigger (A29), so these names are
  a fact of the schema, not a configurable value.
- **Role wire values** are the `UserRole` enum (`UserRole.admin.wire`), not
  loose strings.
- **Status codes** (`PRESENT`, `LOW`, `OUT`, `DISPATCH`…) map to enums or to the
  `StatusChip` lookup in `core/widgets/panels.dart`, one place each.
- **Report periods** (today, 7 days, 30 days) are UI choices, not policy.
- **Demo data** under `lib/core/demo/` is sample data on purpose. It is compiled
  in only when `DEMO_MODE=true` and is the one place fixed names and numbers are
  expected. It never reaches a live build.

There are no `TODO`, `FIXME`, "coming soon" or dummy strings anywhere in
`app/lib`.

## 4. The automated guard

`supabase/tests/api_coverage.test.mjs` reads every Supabase call straight out of
`app/lib/**/data/*.dart` and checks each one against the migrated schema:

- the RPC exists, is not an ambiguous overload, accepts every parameter name the
  app sends, and is executable by `authenticated`;
- the table or view exists and has every column the app selects, filters, orders
  by, writes, or parses in its model.

Because it reads the source, a repository method added next month is covered the
moment it is written. Current run: **15 RPC calls and 42 table/view reads across
11 repositories — 69 checks, all passing.**

Run everything with:

```bash
cd app && flutter analyze && flutter test          # 103 tests
cd supabase/tests && npm test                      # 328 checks
```
