# Ambiguity Register & Design Decisions

Section 67 Step 2. Every item below is a place where the specification is silent,
under-specified, or internally contradictory. Each has a decision, a rationale, and
a note on how the logic was isolated so it can be changed later (§61).

Status legend: **RESOLVED** = decided and implemented. **DEFERRED** = intentionally
not built now; structure exists so it can be added without restructuring.

---

## A1. "USER" vs "OPERATOR" role naming — RESOLVED

§5 names the roles `ADMIN` / `USER`. §10, §19, §29 and §32 call the same role
"Operator".

**Decision:** the enum is `user_role = ('ADMIN', 'OPERATOR')`. `OPERATOR` is
canonical; "User" is treated as UI vocabulary for the same thing. One enum keeps the
two names from drifting apart across RLS policies.

## A2. Is there a separate `operators` table? — RESOLVED

§36 lists `profiles` and `machine_assignments(operator_id)` but never an `operators`
table, while §10/§32 describe operator management as its own module.

**Decision:** an operator **is** a `profiles` row with `role = 'OPERATOR'`.
`machine_assignments.operator_id -> profiles.id`. There is no second identity table.

## A3. `profiles.id` vs `profiles.auth_user_id` — RESOLVED

§6 lists both, which is redundant if the profile is keyed by the auth user.

**Decision:** `profiles.id` is an independent `uuid` primary key; `auth_user_id` is a
**nullable, unique** foreign key to `auth.users`.

**Why nullable matters:** §32 requires Admin to "Add operator". Creating a Supabase
*auth* user requires the admin API and a service-role key, which §56 forbids shipping
inside the Flutter app. So Admin creates a *profile* — an operator who can be assigned
to a machine and credited with production immediately — and linking that profile to a
login is a separate privileged step. Operators who never log in (common where one
shared device sits on the floor) are therefore first-class.

**Consequence:** "create an operator *with* a login" needs an Edge Function holding
the service-role key. That is **DEFERRED**; the profile half works today.

**Correction (0011).** This entry previously claimed the
`link_profile_to_auth_user()` seam was "already in the schema". It was not — the
function had never been written, and the only documented way to attach a login to
a profile was two hand-written UPDATE statements in the SQL editor. It exists now,
in `0011_reporting_and_identity.sql`: admin-only, matches the email
case-insensitively, and refuses to move a login that already belongs to somebody
else rather than silently locking that person out.

## A4. `mixture_entries` hard-codes three materials — RESOLVED (deviation from §36)

§36 specifies `raizin_quantity`, `chemical_quantity`, `color_quantity` columns.
§12 requires that "the system should support additional raw materials later". These
contradict: a fourth raw material would need a schema migration plus a code change in
every layer.

**Decision:** `mixture_entries` (header: date, machine, operator, shift, total) plus
`mixture_entry_lines` (raw_material_id, quantity). The three-column shape is preserved
for reporting by the view `v_mixture_entries_wide`, which pivots the lines back into
`raizin_qty / chemical_qty / color_qty`. Nothing in §15 is lost and §12 is honoured.

## A5. Mutable stock columns vs. a pure ledger — RESOLVED

§12 gives `raw_materials.current_stock`; §37 says do **not** rely only on a mutable
current-stock field.

**Decision:** both, with a clear owner for each.

- `raw_material_stock`, `finished_goods_stock` and `reusable_wastage_stock` are
  **balance rows**: a fast-read cache and — more importantly — the **row-lock target**
  (`SELECT ... FOR UPDATE`) that makes concurrent stock movements safe (§4).
- The `*_transactions` tables are the **source of truth**, and every row carries
  `previous_stock` and `resulting_stock`.
- `v_stock_reconciliation` re-derives each balance from its ledger and reports drift,
  so the cache can always be proven correct against history.

Balance rows are never written by the client — only by `SECURITY DEFINER` functions.

## A6. Dispatch: one product line or many? — RESOLVED (deviation from §36)

§22 and §36 model a dispatch as a single pipe type + size + quantity. A physical
vehicle almost always carries several sizes, and repeating customer and vehicle on
every row denormalises the wrong way.

**Decision:** `dispatches` (header: date, customer, reference, vehicle, remarks) plus
`dispatch_lines` (pipe_type, pipe_size, bundles). `create_dispatch()` accepts an array
of lines and validates **all** of them before deducting **any**, which is what §22's
atomicity requirement actually demands. The Phase 5 UI defaults to a single line, so
the operator-facing workflow in the spec is unchanged.

## A7. What unit is production wastage in? — RESOLVED (assumption)

§18 puts `wastage_quantity` beside `bundles_produced`; §24 says wastage carries a
unit. "Bundles of scrap" is not a physical quantity for braided pipe.

**Assumption:** production wastage is **kilograms of scrap material**, not bundles.
It is exposed as the `app_settings` key `production_wastage_unit` (default `kg`) and
read in exactly one place, `record_production()`.

**Critical rule:** production wastage does **not** reduce finished-goods bundles.
`bundle_quantity` is already the net good output; subtracting wastage from it would
count the loss twice.

## A8. Does wastage deduct raw-material stock? — RESOLVED (assumption, highest risk)

§14 lists `WASTAGE` as a raw-material transaction type, which implies a deduction.
But material already consumed into a mixture has *already left* raw stock — deducting
it again would double-count.

**Assumption — `wastage_source` separates two physically different events:**

| Source | Deducts raw stock? | Adds to reusable? |
|---|---|---|
| `RAW_MATERIAL_LOSS` — spillage or contamination; the material never entered a mix | **Yes** | only if flagged reusable |
| `PRODUCTION_SCRAP` — offcuts and purge, from material already consumed | **No** | only if flagged reusable |

This is the single most likely rule to need correction once the factory confirms how
scrap is physically measured. It lives in one branch of `record_wastage()`.

## A9. How does reusable wastage replace virgin material? — SUPERSEDED by A20

The question turned out to rest on a false premise. See **A20**: shredded pipe is
a raw material, so there is nothing to substitute. The decision below still
governs the older `reusable_wastage_*` tables, which the shredding loop does not
touch.

<details>
<summary>Original decision, retained for the reusable-wastage tables</summary>

### A9 (original). How does reusable wastage replace virgin material? — DEFERRED (§26 requires it stay configurable)

**Decision:** `app_settings.reusable_wastage_mode`, default `SEPARATE`.

- `SEPARATE` (implemented): consuming reusable wastage draws down the reusable balance
  only and never touches raw-material stock. The two inventories stay independent,
  exactly as §25 demands.
- `SUBSTITUTE` (not implemented): would let reusable stock satisfy part of a mixture at
  a configured ratio. The function reads the setting and raises an explicit
  "not yet configured" error, so the hook exists without inventing the arithmetic.

</details>

## A10. Notifications carry `user_id`, but alerts target a role — RESOLVED

§36 gives `notifications.user_id`; §23 and §41 describe alerts for "the Admin"
generally. Fanning one dispatch out to a row per admin is wasteful and races with
newly created admins.

**Decision:** `user_id` is nullable and `target_role` is added. `user_id IS NULL`
means "everyone holding `target_role`". Read state for broadcasts is tracked per user
in `notification_reads`, so one admin marking a broadcast read does not hide it from
another.

## A11. Can one production entry hold several types/sizes? — RESOLVED (§61 flagged this)

**Decision:** no. One entry = one date + machine + operator + shift + type + size, per
§36 and §60 RULE 8. Operators log multiple entries per shift. Simplest reasonable
option, and it keeps the confirmation screen in §44 readable.

## A12. Is a mixture batch linked to production entries? — DEFERRED (§61 flagged this)

**Decision:** no link. The factory has not defined a recipe, a batch yield, or whether
one mix feeds several entries. `production_entries.mixture_entry_id` is deliberately
**not** added, because that column would encode a guess about the process. Both entry
types already share date + machine + shift, which is enough to correlate them in
reports.

## A13. Recipes, bundle weight, pipe length per bundle — PARTLY RESOLVED by A21

**Bundle weight is now modelled** — see A21. It had to be: without kg-per-bundle
there is no arithmetic that relates what goes into a machine to what comes out.

**Recipes remain deferred.** There is still no expected-yield validation and no
theoretical-vs-actual variance against a recipe, because the factory has not
defined one. What exists instead is *actual* yield, reported per machine per day
by `v_production_material_balance` — the useful half, without the guesswork.
Adding a `recipes` table later touches nothing that exists today.

## A14. Preventing negative stock under concurrency — RESOLVED

§16 forbids negative stock and forbids partial execution.

**Decision:** every stock-moving operation is a single `SECURITY DEFINER` PL/pgSQL
function. Each locks its balance rows with `FOR UPDATE` **in a deterministic order**
(sorted by id) so two concurrent mixtures touching the same materials in a different
order cannot deadlock. It then validates the whole basket before writing anything. Any
failure raises, and the surrounding transaction rolls back. `CHECK (quantity >= 0)` on
the balance tables is the last line of defence.

## A15. Duplicate submission (§47) — RESOLVED

Every write RPC takes `p_client_ref uuid`, and each entry table has a
`client_ref uuid UNIQUE`. A retry carrying the same ref returns the **existing**
record instead of creating a second one, so a double tap, or a timeout followed by a
retry, is safe by construction rather than by UI discipline alone.

## A16. Shifts crossing midnight — RESOLVED

Night runs 22:00–06:00. Times are stored as given; no "which shift is it right now"
logic is implemented, because that needs a rule for how the factory attributes the
small hours to a calendar date. The operator picks the shift and the date defaults to
today.

## A17. RLS recursion on `profiles` — RESOLVED

A policy on `profiles` that reads `profiles` to discover the caller's role recurses.

**Decision:** `app.current_role()` and `app.current_profile_id()` are
`SECURITY DEFINER STABLE` helpers that bypass RLS, with `search_path` pinned to defeat
search-path hijacking.

## A18. Editing history — RESOLVED

§29 and §48 forbid overwriting operational records.

**Decision:** ledger and entry tables have no UPDATE or DELETE policy for anyone,
including Admin. Corrections are new reversing transactions (`CORRECTION` /
`ADJUSTMENT`) that carry `reverses_id`. Master data is editable; ledgers are
append-only.

## A19. Live verification of the SQL — RESOLVED

Was open because the machine had no Docker, Supabase CLI or Postgres. It did not
need any of them: PGlite is a real Postgres compiled to WebAssembly, running
in-process under Node.

`supabase/tests/` stands up a Supabase-shaped database (an `auth.users` stub, an
`auth.uid()` backed by a GUC, the `anon` / `authenticated` / `service_role` roles,
the `supabase_realtime` publication), applies every migration in order, and then
exercises the parts unit tests cannot reach — atomicity, idempotency, RLS and the
material balance. 122 assertions across two suites, all passing.

The original five migrations, previously reviewed-but-unrun, execute cleanly.

**Still not covered:** genuine multi-connection concurrency. PGlite is a single
connection, so the `FOR UPDATE` lock ordering (A14, and the cross-table order in
A22) is verified by inspection rather than by two racing transactions.

---

# Manufacturing module (migrations 0006–0010)

Decisions taken when the factory described the process it actually runs: two raw
materials into a machine, pipe out in bundles, defective pipe shredded and fed
back in. Full write-up in [04-pipe-manufacturing.md](04-pipe-manufacturing.md).

## A20. Where does shredded pipe go? — RESOLVED (supersedes A9)

The factory shreds defective pipe and **reinserts it into the machine alongside
virgin material**. The original schema could not express that: reusable scrap went
into `reusable_wastage_stock`, an inventory A9 deliberately walls off so it can
never enter a mixture.

**Decision:** regrind is an ordinary `raw_materials` row — category `RECYCLED`,
`is_recycled = true`, measured in kg, held in `raw_material_stock`.
`consume_raw_materials()` mixes it with no special case at all.

**Why this and not a substitution ratio:** A9 asked how reusable stock should
*replace* virgin material, and the answer is that it does not replace anything —
it *is* material. Once it lives in the same inventory, the ratio question, the
`SUBSTITUTE` mode and the DP007 error all stop existing rather than being solved.

One pool per grade or colour (`pipe_types.recycled_material_id`), because black
regrind must not end up in a white pipe. `shred_pipe()` refuses a material not
marked recycled, so a mistyped id cannot inflate virgin stock.

The `reusable_wastage_*` tables are left intact — the admin dashboard reads them —
but the shredding loop does not write to them.

## A21. Bundle weight — RESOLVED (resolves half of A13)

§36 counts finished goods in bundles and raw material in kilograms, and never
relates the two. "We consumed 900 kg and produced 30 bundles" is then not a
statement anyone can check.

**Decision:** `pipe_products.bundle_weight_kg`, `NOT NULL` and positive, keyed on
the same (type × size) pair every existing table already uses. A product without a
weight is refused (`DP008`) rather than allowed through to fall silently out of
every balance it appears in.

**Weight is versioned, not overwritten.** Two mechanisms, because one is not
enough: `production_entries` snapshots the weight it was recorded against, and
`output_weight_kg` is `GENERATED ... STORED` over that snapshot; separately, every
change to a spec is written to `pipe_product_weight_history` by trigger. Retuning
a weight next month cannot re-value last month's output.

**Assumption:** weight is a fixed property of the product, not weighed per batch.
`actual_weight_kg` exists on the entry and `v_production_entries_weighted` reports
the variance, but no form asks for it yet.

## A22. Two kinds of shredding — RESOLVED

"Defective pipe is shredded" describes two physically different events, and
conflating them double-counts stock.

| Source | Bundles ever counted | Finished goods | Counts against today's consumption |
|---|---|---|---|
| `PRODUCTION_REJECT` — rejected at the line | No | untouched | Yes |
| `FINISHED_BUNDLE` — pulled back out of stock | Yes | bundles deducted | No — consumed on an earlier day |

**Decision:** one RPC, a `source` enum, and a `CHECK` (`shred_source_shape_ck`)
that makes the two shapes structurally different rows — a bundle shred must carry
a bundle count, a reject shred must not. The rule is enforced by the database
rather than remembered by a developer.

`v_production_material_balance` folds only reject shreds into the day's
consumption and reports bundle shreds alongside, because crediting today's run
with material it never consumed would corrupt the yield figure.

**Mass conservation:** a bundle shred claiming to recover more than the bundles
held is refused, with 20% headroom for rough weight specs
(`shred_recovery_tolerance_pct`). This catches `350.0` typed for `35.0` before it
reaches the ledger.

**Cross-table lock order.** `shred_pipe()` is the first operation to move finished
goods and raw material in the same transaction, which forces a global order:
`finished_goods_stock → raw_material_stock → reusable_wastage_stock`. It takes the
bundle row first, so it can never sit holding a material row while a mixture holds
the bundle row it wants.

## A23. Which machine makes which product? — RESOLVED

§36 has machines and products but never relates them, so any machine could be
credited with any product.

**Decision:** `machine_products`, enforced **opt-in per machine** — a machine with
no rows configured is unconstrained.

**Why opt-in:** a hard requirement would mean that the moment the table exists,
every machine must be configured before anyone can record anything. Opt-in lets
the factory tighten one line at a time. `app_settings.enforce_machine_product`
turns the check off entirely if it proves more trouble than it is worth.
