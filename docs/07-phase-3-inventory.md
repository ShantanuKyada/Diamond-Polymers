# Phase 3 — Inventory and Raw Material Entry

The phase where the insufficient-stock rule stops being a database guarantee and
becomes something an operator sees.

Two screens: **Inventory** for administrators, **Raw Material Entry** for the
floor.

---

## Raw Material Entry (`/op/mixture`)

An operator records what went into the machine. One call to
`consume_raw_materials()`, one transaction.

Three things the screen has to get right, and why:

**The machine is not typed, it is read.** It comes from the operator's current
assignment. The database refuses an entry for a machine the operator is not
assigned to (`DP006`) regardless of what the client sends, so a free-text field
would only invite a rejection. An operator with no assignment does not get the
form at all — they get told to ask an administrator, which is the only thing
that would actually help.

**Stock is shown beside every input.** Entering more than there is marks the
line immediately. That is a *hint*, not a verdict: the balance may have moved
since the screen loaded, and the database remains the authority. It still
catches the common case before a batch is thrown away.

**The batch is all-or-nothing, and the screen says so.** If any one material is
short, `consume_raw_materials()` deducts none of the others. When that happens
the error is rewritten using the numbers the database sends back:

> Insufficient Chemical stock. Available: 343.355 kg. You entered 5,000 —
> 4,656.645 more than there is. Nothing was deducted.

The last sentence matters most. An operator who thinks a partial deduction
happened will re-enter the rest and double-count.

### Idempotency

The submission carries one reference for the whole attempt. It is minted when
the operator confirms, **reused if the attempt fails and is retried**, and
cleared only once the batch is recorded. That is what makes a double tap, or a
timeout on a bad connection, record one batch instead of two (§47).

Regenerating the reference on retry would defeat the entire mechanism, so it is
written as `_attemptRef ??= ...` with a comment saying why — this is the kind of
line somebody later "tidies up" into a bug.

A repeat submission is not silently swallowed either; the screen says *"That
batch was already recorded — nothing was deducted twice."*

---

## Inventory (`/admin/inventory`)

Three tabs, because there are three genuinely different inventories rather than
one with a filter.

| Tab | Unit | Actions |
|---|---|---|
| Raw material | kg | Stock in, Adjust |
| Finished goods | bundles (and kg) | read-only here |
| Regrind | kg | read-only |

**Stock in and Adjust are kept apart** even though both end in a raw-material
movement. One is goods received and is always positive; the other is a signed
correction. Collapsing them into a single "change stock" box would make the
ledger unreadable six months later, when the question is "did we buy this or
did somebody fix a mistake?".

A negative adjustment that would take stock below zero is **refused, not
clamped** — the helper text says so, because an operator who expects clamping
will assume it worked.

**Finished goods shows bundles and kilograms side by side**, which is the entire
point of a bundle weight existing. A type × size pair with no product configured
shows *"No bundle weight set"* in amber rather than a blank: that pair cannot
have production recorded against it (`DP008`), so the gap is actionable.

**Regrind reports both halves of the loop** — what the shredder has produced and
what mixtures have since consumed — because the difference is the balance, and
seeing them separately is how you notice regrind piling up unused.

---

## Verification

```
flutter analyze   No issues found
flutter test      69 passed
npm test          171 assertions across three suites
```

The contract test now also pins **the shape of the mixture payload**. `p_lines`
is `jsonb`, and the app builds `[{raw_material_id, quantity}, ...]`. A renamed
key inside that array would pass every signature check and then fail on the
floor, because the function would read `null` and raise a validation error. So
the test sends the exact array the app sends, and asserts:

- the total comes back as expected;
- the same reference twice returns the first batch, not a second one;
- a batch short on one material is refused **and the others are untouched**;
- a stock-in retry does not post twice;
- an adjustment cannot drive stock below zero.

The widget tests cover the unassigned operator, the over-entry warning, the
running total, the confirmation summary, and a 360px render.

---

## One thing removed rather than added

`FinishedGoodsStock` already existed in the dashboard feature, parsing the same
`v_finished_goods_stock` rows. The first version of this phase defined a second
copy in `inventory/domain`. That is exactly the drift the shared widgets exist
to prevent, so the duplicate was deleted and the existing model reused, with an
extension supplying the one thing it lacked — a key for joining a bundle weight
onto a stock row.

One view, one model.

---

## Not built

- **Transaction history per item.** The ledgers carry `previous_stock` and
  `resulting_stock` on every row and the data is all there, but a history screen
  belongs with Phase 7's reporting, where a date range and filters make it
  useful rather than an undifferentiated list.
- **Finished-goods adjustment from the UI.** `adjust_finished_goods_stock()` is
  wired in the repository and covered by the contract test, but no screen calls
  it yet — correcting bundles is rarer than correcting kilograms, and it belongs
  next to the production records in Phase 4.
