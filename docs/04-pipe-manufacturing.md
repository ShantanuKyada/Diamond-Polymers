# Pipe Manufacturing

The module that turns kilograms of raw material into bundles of pipe, and turns
defective pipe back into kilograms.

Migrations `0006`–`0010`. Everything here has been executed and exercised — see
[Testing](#testing) at the end.

---

## The process, as the factory runs it

```
  raw materials (kg)  ──┐
                        ├──▶  machine  ──▶  pipe, in bundles (each bundle has a weight)
  regrind (kg)  ────────┘                        │
        ▲                                        │  some of it is defective
        │                                        ▼
        └──────────────  shredder  ◀────  reject at the line, or a bundle
                                                  pulled back out of stock
```

Two units, one loop. Material enters in kilograms and leaves as bundles; the
defective part goes through a shredder and re-enters as kilograms. **A bundle's
weight is the only thing that connects the two halves** — without it, "we
consumed 900 kg and made 30 bundles" is not a sentence anyone can check.

---

## The three things this module adds

### 1. A bundle has a weight

`pipe_products` is the (pipe type × pipe size) pair as a product, carrying
`bundle_weight_kg`. It is `NOT NULL` and must be positive: a product without a
weight would silently fall out of every material balance it appeared in, which is
worse than being refused.

Two rules protect it from being quietly rewritten later:

- **Production entries snapshot the weight they used.**
  `production_entries.bundle_weight_kg` is copied at the moment of recording, and
  `output_weight_kg` is a `GENERATED ... STORED` column over it. Retuning a spec
  next month cannot re-value last month's output.
- **Every change to a spec is recorded** in `pipe_product_weight_history`, by
  trigger, with who changed it.

### 2. Shredded pipe is a raw material — not a separate inventory

This is the one place the original schema contradicted the process. It routed
reusable scrap into `reusable_wastage_stock`, an inventory that decision A9
deliberately walls off so it can *never* enter a mixture. But the factory does
exactly that: regrind goes back into the machine alongside virgin material.

So regrind is now an ordinary `raw_materials` row — category `RECYCLED`,
`is_recycled = true`, measured in kg, held in `raw_material_stock`.
`consume_raw_materials()` mixes it with **no special case at all**. The whole
substitution question in A9 disappears, because there is nothing to substitute:
it was always just another material.

One pool per grade or colour, named by `pipe_types.recycled_material_id`, because
black regrind must not end up in a white pipe. `shred_pipe()` refuses to post
into a material that is not marked recycled, so regrind cannot inflate virgin
stock by a mistyped id.

The old `reusable_wastage_*` tables are left in place and untouched — the admin
dashboard reads them — but nothing in this loop writes to them.

### 3. A machine makes a known set of products

`machine_products` records which products each line can run. Enforcement is
**opt-in per machine**: a machine with no rows configured is unconstrained. That
way, configuring one line does not stop every other line recording work the same
afternoon. `app_settings.enforce_machine_product` turns the check off entirely.

---

## The two kinds of shredding

`shred_pipe()` handles both, and the difference is not cosmetic — one touches
finished-goods stock and the other must not.

| | `PRODUCTION_REJECT` | `FINISHED_BUNDLE` |
|---|---|---|
| What happened | Rejected at the line during the run | Counted into stock, later found defective |
| Bundles ever counted? | No | Yes |
| Finished goods | **Untouched** | **Bundles come out** |
| Recycled stock | kg go in | kg go in |
| `bundle_quantity` | must be `NULL` | must be given |
| Counts against today's consumption | Yes | No — it consumed material on some earlier day |

A `CHECK` constraint (`shred_source_shape_ck`) makes those two shapes
structurally different rows, so the rule is enforced by the database rather than
remembered by a developer.

**Mass cannot be created.** A bundle shred that claims to recover more than the
bundles held is refused (`shred_recovery_tolerance_pct`, default 20% headroom for
rough weight specs). This catches a typed `350.0` where `35.0` was meant, before
it reaches the ledger.

---

## Material balance — the point of all of this

`v_production_material_balance`, per machine per day:

```
consumed_kg  −  produced_kg  −  wastage_kg  −  reject_shred_kg  =  unaccounted_kg
```

Near zero means the day reconciles. A persistent positive figure means material
is leaving the factory without being recorded, which is the single most useful
number this system can produce and was not calculable at all before bundles had a
weight.

`virgin_consumed_kg` and `recycled_consumed_kg` split the input, so the regrind
ratio is visible. `yield_pct` is produced ÷ consumed.
`v_daily_material_balance` rolls it up factory-wide.

---

## API

| Function | Who | What it does atomically |
|---|---|---|
| `record_production(...)` | operator | entry + weight snapshot + finished-goods increase |
| `shred_pipe(...)` | operator | shred entry + (bundles out) + regrind in |
| `consume_raw_materials(...)` | operator | mixture + all material deductions, or none |
| `set_machine_products(machine, ids[])` | admin | replaces a machine's product list in one swap |
| `upsert_pipe_product(...)` | admin | product + weight + its finished-goods row |

Every one takes a `client_ref` where it creates an entry: a retry with the same
ref returns the existing record instead of a twin.

### Views

`v_pipe_products` · `v_machine_products` · `v_shred_entries` ·
`v_recycled_material_stock` · `v_production_material_balance` ·
`v_daily_material_balance` · `v_production_entries_weighted`

### New error codes

Added to the convention in `0002_helpers.sql`:

| SQLSTATE | Meaning | Flutter maps to |
|---|---|---|
| `DP008` | No bundle weight configured for that product | `notConfigured` — an admin must act |
| `DP009` | That machine is not set up to run that product | `validation` — pick another product |

---

## Concurrency and ACID

**Atomicity.** Every stock movement is one `SECURITY DEFINER` function, so the
entry row, the ledger rows and the balance updates commit together. A shred that
cannot find its recycled pool leaves the bundles in stock.

**Consistency.** `CHECK (resulting = previous + quantity)` on every ledger row
means a mis-written movement is impossible, not merely unlikely.
`CHECK (quantity >= 0)` on balances is the last line of defence against negative
stock. `v_stock_reconciliation` re-derives every balance from its ledger, so the
cache can be *proven* correct rather than assumed.

**Isolation.** Balance rows are locked `FOR UPDATE` before being read, in one
global order:

```
finished_goods_stock  →  raw_material_stock  →  reusable_wastage_stock
```

and within raw materials, ascending id. `shred_pipe()` is the first operation to
move finished goods and raw material in the same transaction, which is what makes
that order load-bearing: it takes the bundle row first, so it can never sit
holding a material row while a mixture holds the bundle row it wants.

**Durability.** Postgres, via Supabase.

**Append-only.** `shred_entries` and `pipe_product_weight_history` have no
`UPDATE` or `DELETE` policy for anyone, administrators included. Corrections are
reversing entries.

**No client writes.** There is no `INSERT` policy on any operational table.
An operator with a stolen anon key and a hand-crafted REST call cannot
manufacture a gram of regrind — there is simply no policy that permits the write.

---

## Testing

`supabase/tests/` runs the entire migration chain against a real Postgres
compiled to WebAssembly (PGlite) — no Docker, no Supabase CLI, no network:

```bash
cd supabase/tests
npm install
npm test
```

**70 assertions, all passing**, covering what unit tests cannot reach:

- a failed shred leaves no entry row and creates no regrind
- a mixture short on one material deducts none of the others
- a retry returns the original record rather than a second one
- shredding cannot create mass, and cannot post into a virgin material
- a weight change does not rewrite historical entries
- an operator cannot write a balance, retune a weight or insert a shred
- not even an admin can delete or rewrite a shred
- after every movement, the ledgers still explain every balance

Applying to a real project:

```bash
cd supabase/tests
DATABASE_URL="postgresql://..." npm run apply -- --seed
```

**Not covered:** genuine multi-connection concurrency. PGlite is a single
connection, so the `FOR UPDATE` ordering is verified by inspection and by the
deterministic lock order, not by two racing transactions.

---

## Deliberately not built

- **Recipes.** No expected-yield validation and no theoretical-vs-actual
  variance, because the factory has not defined a recipe. `v_production_material_balance`
  reports actual yield, which is the useful half without the guesswork.
- **Per-bundle weighing.** `production_entries.actual_weight_kg` exists and
  `v_production_entries_weighted` reports the variance, but the operator form
  does not ask for it. The spec weight is what the factory works to.
- **Automatic regrind reordering.** Regrind has `minimum_stock = 0`, so it raises
  no low-stock alert. Running out of regrind is normal, not a problem.
