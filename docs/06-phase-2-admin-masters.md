# Phase 2 — Admin master data

The first frontend phase. Machines, Operators and Settings: the things an
administrator configures once, so that Phases 3 and 4 have dropdowns to fill and
the database has the weights it needs to calculate anything.

Phase 1 (sign-in, dashboards, notifications, profile) was already built. This is
the next unbuilt one.

---

## What was built

| Screen | Route | What it does |
|---|---|---|
| Machines | `/admin/machines` | Add and edit lines, status, and which products each can run |
| Operators | `/admin/operators` | Staff, machine assignment, attaching a login |
| Settings | `/admin/settings` | Hub: catalogues, plus the rules the database calculates by |
| Products | `/admin/settings/products` | **Bundle weights** and reorder levels |
| Pipe types | `/admin/settings/pipe-types` | Grades, and the regrind pool each returns to |
| Pipe sizes | `/admin/settings/pipe-sizes` | Diameters and lengths |
| Raw materials | `/admin/settings/materials` | Inputs, thresholds, regrind pools |
| Shifts | `/admin/settings/shifts` | Working hours |

Every route sits under `/admin`, so `route_guard` protects it by prefix rather
than by anyone remembering to add a check — and the existing guard test, which
iterates `AppRoute.values`, covered all eight the moment they were added.

---

## Decisions worth knowing

**Master data is written directly, not through RPCs.** RLS grants administrators
`for all` on master tables because they describe the factory rather than record
what happened in it. Operational tables still have no INSERT policy at all, so
nothing on these screens can move a gram of stock.

Three operations do go through RPCs, because each is more than one row:

- `upsert_pipe_product` also seeds the finished-goods row, so a new product
  appears in stock views at zero rather than vanishing from them.
- `set_machine_products` swaps a machine's whole capability list under a lock, so
  the line is never briefly able to run nothing.
- `link_profile_to_auth_user` refuses to steal a login that already belongs to
  someone else — which a raw `UPDATE` would do silently, locking that person out.

**Assignments end, they never delete.** Reassigning an operator closes the open
row with an end date and opens a new one. Past production points at the old
assignment, so deleting it would orphan history.

**"No login" is a state, not a fault.** An operator can exist as a factory record
with no app account at all (A3) — common where one shared handset sits on the
floor. The tile shows that as information alongside the machine they are on, not
as a warning.

**Type and size cannot be changed on an existing product.** They are the
product's identity and every stock row is keyed by the pair. The form disables
them and says to create a new product instead.

**Settings show the database's own description.** The `app_settings` rows carry
the explanation of what each key does, written next to the function that reads
it. The screen renders that text rather than a copy, so the two cannot drift.

---

## Verification

```
flutter analyze   No issues found
flutter test      55 passed
npm test          158 assertions across three suites
```

`supabase/tests/app_contract.test.mjs` is new and is the one worth explaining.
Dart has no idea whether `pipe_product_id` exists until PostgREST returns a 400
on a real handset, and PostgREST binds RPC arguments **by name**, so a renamed
parameter fails the same way. The contract test copies every column list and
every parameter name out of the repository and runs them against the real
schema. If a migration renames something, it fails and names the query that has
to change with it. 36 assertions.

The widget tests cover the states a happy-path demo never shows: a machine
nobody is assigned to, a person with no login, a product with no reorder level,
and a Postgres `numeric` arriving as a `String` (which, parsed as a `num`, would
render every bundle weight as zero).

Three of them render at **360×780** — a real handset — because the default test
surface is 800×600 and a row that fits there can still overflow on a phone.

---

## Testing on a phone

> **Update, September 2026:** this is no longer true. Release APKs have since
> been built on this machine several times with `flutter build apk --release`
> in about two to four minutes. The notes below are kept for the record, in
> case the loopback problem comes back.

**The APK could not be built on this machine at the time.** Gradle needs `Selector.open()`,
which creates an internal loopback socket pair on Windows, and something on this
machine blocks exactly that:

```
Pipe.open()     OK
Selector.open() java.io.IOException: Unable to establish loopback connection
```

It is not Flutter, not the SDK, not memory, and not a sandbox — it fails for a
plain JVM too, and it will stop Android Studio building as well. The usual cause
is antivirus or a stale Winsock LSP chain left by a VPN. The fix, in an
Administrator terminal, then a reboot:

```
netsh winsock reset
```

Failing that, add an antivirus exclusion for
`C:\Program Files\Android\Android Studio\jbr\bin\java.exe`.

Until then, the web build runs on a handset over WiFi:

```bash
cd app
flutter build web --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-PUBLISHABLE-KEY
node tool/serve_web.mjs
```

It prints every address it is reachable on; open the non-localhost one on a
phone on the same network. This is a stopgap for testing, not a deployment
mechanism.

---

## Not built

- **Production history per machine and per operator.** The placeholder promised
  it; the views (`v_machine_production_summary`, `v_operator_production_summary`)
  exist, but the screens belong with Phase 4, where production records are
  presented properly.
- **Creating a login from inside the app.** Needs the service-role key, which
  must never ship in an APK (§56). Administrators create the user in the
  Supabase dashboard and attach it here.
