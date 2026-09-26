# Packaging, Two Shifts, and Admin-Only Material Entry

Covers the ERP change request of September 2026: bags alongside bundles, the
type → size → packaging mapping, a fixed two-shift master, wastage usage on
production entries, self-service profiles, the weekly My Entries view,
admin-only material entry, and attendance on the operator home.

Database: `supabase/migrations/0015_packaging_shifts_access.sql`.
Tests: `supabase/tests/packaging_access.test.mjs`.

Each decision below continues the register in `01-ambiguities-and-decisions.md`.

---

## A24. Where the packaging mapping lives — RESOLVED

The request asks for a "Type Master" with sizes configured under each type,
each carrying pipes-per-bag and pipes-per-bundle.

That structure already exists. `pipe_types` is the type master, and
`pipe_products` is one row per (type, size) — which is exactly "a size
configured under a type". It already carries `pipes_per_bundle`.

**Decision:** add `pipes_per_bag` to `pipe_products`. No new table. A second
mapping table keyed by the same pair would give every product two sources of
truth for its packaging, and they would drift.

The Products screen is regrouped by type so it reads as the requested
Type → Size → Packaging hierarchy. New sizes are still created once in the
Pipe Sizes master and then mapped under whichever types use them, so a size
shared by two types is not defined twice.

## A25. Bags are their own stock, not a conversion of bundles — RESOLVED

Two ways to model "20 bundles and 10 bags":

1. Count everything in pipes and treat bundles and bags as views of one pool.
2. Keep a bundle balance and a bag balance per product.

**Decision: (2).** Packed goods are physically in one packaging. A bundle on
the floor cannot be dispatched as bags without somebody unpacking and repacking
it, so a single pipe pool would let the system approve a bag dispatch the
storeroom cannot fill.

- `finished_goods_stock.quantity_bags` sits beside `quantity_bundles`.
- `finished_goods_transactions.packaging` (`BUNDLE` / `BAG`) says which balance
  a ledger row moved. Existing rows default to `BUNDLE`, so history is unchanged.
- Every reader that sums the ledger now filters by packaging —
  `v_stock_reconciliation` and `finished_goods_report()` included — otherwise a
  bag movement would have been silently counted as bundles.

Repacking bundles into bags is not modelled. If it happens, it is two
adjustments, one per packaging.

## A26. The mapping is used, not just stored — RESOLVED

"Use these mappings to calculate or validate the corresponding bags/bundles":

- **Validate.** A product can be produced or dispatched in bags only once both
  `pipes_per_bag` and `pipes_per_bundle` are configured. Bundles keep working
  without them, because every existing product and record predates the mapping.
- **Calculate weight.** A bag's weight is derived as
  `bundle_weight_kg × pipes_per_bag ÷ pipes_per_bundle` and snapshotted on the
  entry, exactly as bundle weight already is.
- **Calculate pipes.** Screens show the pipe count a quantity represents.

## A27. Production records bags too — RESOLVED (necessary consequence)

The request adds bags to dispatch but not explicitly to production. Bag stock
only ever comes from production, so without this every bag dispatch would fail
with zero stock.

**Decision:** production entries carry `bag_quantity` beside `bundle_quantity`.
Either may be zero; at least one must not be.

`output_weight_kg` is redefined to include bag output. It is a stored generated
column, so it was dropped and re-added with the new expression, and the three
views that read it were recreated verbatim. Every weight report — the material
balance, yield, the variance view and `production_report()` — is therefore
correct for bag production without any change to its own logic.

## A28. "Wastage material used" does not move stock — RESOLVED (assumption)

This is a different figure from the existing `wastage_quantity`:

| Column | Meaning |
|---|---|
| `wastage_quantity` | scrap **generated** by the run |
| `wastage_used_kg` | recycled material **consumed** by the run |

Recycled material is an ordinary raw material (A20) and its consumption is
recorded through Material Entry, which is now admin-only (A30). If the
production entry also deducted it, the same kilograms would leave stock twice.

**Decision:** the production entry records the declaration — `wastage_used`
and `wastage_used_kg` — for reporting and analysis, and moves no stock. The
database enforces the shape: `No` means the quantity is null, `Yes` means it is
greater than zero. A `No` with a quantity is refused rather than quietly
discarded.

## A29. Exactly two shifts — RESOLVED

Enforced by a trigger on `shifts`, not only by hiding a button:

- Only rows named Morning or Night can be created.
- They cannot be renamed, switched off or deleted.
- Any other shift cannot be switched back on.
- Times stay editable.

The legacy **Afternoon** shift is deactivated, not deleted — historical entries
reference it and must keep resolving. Open machine assignments that pointed at
it have their shift cleared, and administrators get a notification saying how
many need reassigning.

A second trigger refuses **new** entries (production, material, wastage,
shredding, attendance) against anything but an active Morning or Night shift.
It fires on insert only, so existing records are untouched.

Seeded times are Morning 06:00–18:00 and Night 18:00–06:00, since two shifts
must now cover the day. They are editable.

## A30. Material Entry is admin-only — RESOLVED

- `consume_raw_materials()` now calls `app.require_admin()`. An operator
  calling it directly over REST gets DP004. There was already no INSERT policy
  on the mixture tables, so the function was the only write path.
- The route moves from `/op/mixture` to `/admin/material`. The router's prefix
  guard sends an operator away from `/admin/*`, so the screen is unreachable
  even by typing the path.
- The operator bottom bar loses its Material tab and the home page loses the
  Raw Material Entry card.
- The admin chooses the machine. The batch is attributed to the operator
  currently assigned to that machine, or to the admin if nobody is.

Operators can still **read** consumption attributed to them — the home page's
"Material used today" is information, not entry.

## A31. Self-service profile — RESOLVED

`update_my_profile(p_name, p_phone)` changes the caller's name and phone and
nothing else. No UPDATE policy was opened on `profiles`: a policy would have
let an operator write their own `role` column too.

Phone numbers may be cleared. Otherwise, after stripping spaces and hyphens,
they must be 10–15 digits with an optional leading `+`.

## A32. My Entries shows seven days, oldest first — RESOLVED

"Last 1 week / 7 days" is today plus the six days before it. "Chronological
order" is taken literally: oldest day at the top, entries within a day in the
order they were recorded. Row level security already limits the rows to the
signed-in operator; the screen filters by the operator's own id as well.

## A33. Attendance on the operator home is read-only — RESOLVED

The request lists information to show — today's status, check-in and
check-out, recent attendance — so the section shows exactly that, from
`v_attendance_days`, which row level security already limits to the person
signed in. No punch button was added; that would be a new capability rather
than the information asked for.

---

## Verification

Database — `cd supabase/tests && npm test`, real Postgres in-process (PGlite):

| Suite | Checks |
|---|---|
| manufacturing | 70 |
| payroll | 52 |
| app contract (every column and RPC parameter the app uses) | 59 |
| **packaging and access (this change)** | **78** |

The new suite covers each scenario the request lists — bundles only, bags only,
both, different types and sizes, wastage used and not used, Morning and Night,
several operators, admin against operator — plus atomicity (a dispatch short on
bags moves no stock at all), per-packaging ledger reconciliation, and the
upgrade of a live database that still has an Afternoon shift and history
recorded against it.

App — `cd app && flutter analyze && flutter test`: no issues, 103 tests.
`test/change_request_test.dart` drives the demo app end to end: the operator
bottom bar, attendance on the home page, bags offered only for bagged
products, the wastage question gating its quantity, the seven-day
chronological My Entries, profile editing and its validation, and the fixed
shift master.

## Applying to an existing project

Run `0015_packaging_shifts_access.sql` in the SQL editor after 0014. It is
safe on a database with history: existing entries and dispatches keep their
meaning, the Afternoon shift is switched off rather than deleted, and any
operator assigned to it is left without a shift and reported to
administrators in the notification centre.

---

# September 2026, second change request

## A34. Material Entry returns to the operator — RESOLVED (reverses A30)

**A30 was wrong about who does this job.** It moved Material Entry to
administrators on the reasoning that drawing down raw stock is an
administrative act. The factory's answer: every operator has their own machine
and is the person physically loading it, so routing the record through an
administrator produced late entries, not safer ones — the material moves whether
or not anybody is free to write it down.

**Decision:** an operator records material for **their own assigned machine**.
An administrator keeps every power they had, including recording for any machine
and naming the operator.

The boundary did not disappear; it moved from *"administrators only"* to *"your
own machine only"*, which is narrower than A30 for everybody except the person
standing at the machine. `consume_raw_materials()` now routes non-admins through
`app.assert_can_record()` — the same guard `record_production()` has always used,
so the two halves of production are finally governed by one rule instead of two:

| Attempt | Result |
|---|---|
| Operator records their own machine | allowed |
| Operator records another machine | `DP006` |
| Operator records for another person | `DP004` |
| Administrator records any machine | allowed |

Unchanged: there is still no INSERT policy on the mixture tables, so the
function remains the only write path; the basket is still validated whole before
anything is deducted; and the client reference still makes a retry safe.

**In the app:** the operator bottom bar regains a **Material** tab, placed
*before* Production because that is the order the work happens in. The machine is
stated rather than chosen — a disabled dropdown would invite tapping, and the
database would refuse any other machine anyway. One screen serves both callers
(`MaterialEntryMode`), since only the source of the machine differs.

Migration `0016_operator_material_entry.sql`. It replaces one authorisation
block and nothing else.

## A35. "Settings" renamed to "Configuration" — RESOLVED

The **More → System → Settings** entry held the factory's catalogues (products,
pipe types, sizes, raw materials, shifts) and the rules the database calculates
by. None of that is a preference, and the name sent people looking for something
else. Renamed to **Configuration**; the route stays `/admin/settings`, which is
internal.

## A36. Dispatch paperwork is a challan, not an invoice — RESOLVED

The factory asked for "an invoice with all the details" attached to a dispatch.
There are no prices anywhere in this system — accounting and GST were excluded
by design — so an invoice in the strict sense could not be produced without a
price list, GST rates, HSN codes and a statutory numbering series.

**Decision:** produce a **delivery challan** now, and build it so prices can be
added later without redrawing it. That matches how most factories already work:
the challan travels with the goods, accounts raise the tax invoice separately.

The document states plainly on its face: *"Not a tax invoice. Issued for
delivery of goods only."* — so nobody files it as one.

**Designed for the later addition.** The line table is assembled from a list of
column descriptors, so a rate and an amount become two more entries plus a
totals block. The header, the layout and the sharing path do not change.

**The number is derived, not counted.** `DC-20260926-A1B2` — prefix, dispatch
date, and four characters from the dispatch id. A statutory sequential series
needs decisions this project has not taken (when it resets, what happens to a
cancelled number, who owns the gap), and those belong with the invoice work.
Deriving it means the number on the paper always leads back to exactly one
record, which is what makes a challan useful in a dispute.

**The factory's own details are configuration** (`0017_factory_identity.sql`):
address, phone, GSTIN, challan prefix and an optional footer, all editable under
Configuration. They default to blank, so an unfinished challan looks unfinished
rather than carrying a convincing placeholder out to a buyer. A blank GSTIN line
is omitted entirely rather than printed empty.

A missing address warns but does not block — the lorry is waiting, and a challan
with a visible gap beats no challan.

Shared or printed through `printing`, which covers WhatsApp, email and a printer
from one sheet and works with no signal.

## A37. A production run belongs to the batch that fed it — RESOLVED (answers A12)

A12 left this open on purpose:

> "The factory has not defined a recipe, a batch yield, or whether one mix feeds
> several entries. `production_entries.mixture_entry_id` is deliberately **not**
> added, because that column would encode a guess about the process."

The factory has now described the process, and it is the obvious one: an
operator comes on shift, charges the machine with raizin, colour and the rest,
records that, runs the machine, and records the output when it is done. Two
halves of one run.

**Decision:** `production_entries.mixture_entry_id`, and production is refused
without it.

### What it buys

Yield for **this batch**, not an average over a machine-day.
`v_production_material_balance` answers *"did this machine balance today"*;
`v_batch_yield` answers *"did this run go well"*, which is the question an
operator can still do something about.

### The three shape decisions, as the factory answered them

| Question | Answer | How it is enforced |
|---|---|---|
| Can one batch feed several runs? | Usually one, but do not forbid it | No constraint. The screen offers the newest batch and marks one that has already produced. A batch yielding two sizes is two entries by A11. |
| Is the link required? | Yes, refuse without it | `DP012`, configurable through `production_requires_batch` |
| Which batches may be chosen? | Any recent one on the same machine | Only the machine is checked |

The time window is deliberately loose. Constraining it to the same shift or date
would refuse the ordinary case of a machine charged near the end of a shift and
run out in the next — which the Night shift, crossing midnight, does every time.

### History

The column is **nullable**. The 26 production entries recorded before this
migration have no batch, and inventing one would be worse than admitting the
gap: `v_batch_yield` simply does not see them, while the daily material balance
still does. Nothing goes missing; it is only not attributable to a batch.

### In the app

The production screen picks the newest batch on the machine by default, because
that is almost always the one just charged. With no batch at all it does not
show a dead dropdown — it offers the Material tab, which is where the operator
has to go anyway.

The demo twin enforces the same rule. It previously kept no batches at all,
because nothing read them back; it does now, or the demo APK would contradict
the live one.

Migration `0018_production_batch_link.sql`.
