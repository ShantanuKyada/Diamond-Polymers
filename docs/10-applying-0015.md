# Applying migration 0015 to the live project

A step-by-step for the migration window. Roughly 15 minutes, most of it waiting.

`0015_packaging_shifts_access.sql` adds bags, the packaging mapping, the
two-shift rule, wastage-used on production entries, admin-only material entry
and the self-service profile. It is written to be safe on a database that
already has history — see `docs/08-packaging-shifts-access.md` §6.

**Before you start, know two things:**

- **The app and the database must move together.** The current app expects
  0015. A live APK built from `main` will fail on the new columns until this is
  applied. Apply the migration first, then build and hand out the new APK.
- **0015 can be run twice safely.** Every step is guarded (`if not exists`,
  `create or replace`, exception handlers). If the SQL editor times out or you
  lose the connection halfway, run the whole file again. This is covered by a
  test (`supabase/tests/checks.test.mjs`).

---

## 1. Take a backup

Supabase dashboard → **Database** → **Backups**. On the free plan there is no
automatic backup, so take one now:

```
Dashboard → Database → Backups → "Download backup"
```

If that option is not available on your plan, use the connection string from
**Project Settings → Database** with `pg_dump`, or simply accept the risk
knowing 0015 deletes nothing — it only adds columns and switches the Afternoon
shift off.

## 2. Pre-flight check

Supabase dashboard → **SQL Editor** → **New query**. Paste the contents of:

```
supabase/checks/0015_preflight.sql
```

Run it. You get seven rows. Read the `ok` column:

| Row | What it means if `ok` is false |
|---|---|
| 1. Migrations 0001–0011 applied | Stop. Apply the earlier migrations first. |
| 2. Payroll 0012–0014 applied | Stop. Apply 0012–0014 first. |
| 3. 0015 not applied yet | It is already applied. Skip to step 4's verify script. |
| 7. Ledgers currently reconcile | Stop and investigate — a balance already disagrees with its ledger, and migrating will not fix it. |

Rows 4, 5 and 6 are informational and tell you what the migration will do to
your data:

- **4** names any shift other than Morning and Night — usually `Afternoon`.
- **5** counts production entries recorded against those shifts. They are
  **kept**; the shift is switched off, never deleted, so history still reads
  correctly.
- **6** counts operators currently assigned to a retired shift. Their shift is
  cleared and administrators get a notification listing how many need
  reassigning. Note this number — you will reassign them in step 5.

## 3. Apply the migration

In the SQL editor, open a **new query** and paste the whole of:

```
supabase/migrations/0015_packaging_shifts_access.sql
```

It is about 1,700 lines. Paste all of it and run it once. Expect it to take a
few seconds. You should see `Success. No rows returned`.

If it errors, read the message, fix the cause, and run the whole file again —
re-running is safe.

## 4. Verify

New query. Paste:

```
supabase/checks/0015_verify.sql
```

All twelve rows must report `ok = true`. The interesting ones:

- **8** shows your two shifts and their times. 0015 moves them to 06:00–18:00
  and 18:00–06:00 **only if** they were still at the original seeded defaults.
  If you had already customised them, they are left alone — adjust them in
  the app under Settings → Shifts.
- **10** confirms every historical production entry still resolves its shift.
- **11** confirms bundle and bag balances both agree with their ledgers.
- **12** repeats the "assignments need attention" notification, if any.

## 5. Reassign any stranded operators

If the pre-flight reported operators on a retired shift, open the app as an
administrator → **Operators**, and set each one's shift to Morning or Night.
Until then they can still record production; they just have no default shift.

## 6. Set up packaging for the products sold in bags

Bags are refused for a product until the mapping exists, by design. In the app:
**Settings → Products & Packaging**, and for each product that ships in bags
set **pipes per bundle** and **pipes per bag**.

Products left without a bag count keep working exactly as before — bundles
only, and the Bags field stays disabled with "Not packed in bags".

## 7. Build and distribute the live APK

```bash
cd app
flutter build apk --release --split-per-abi \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY \
  --dart-define=APP_ENV=production
```

Or add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as repository secrets on GitHub
and let the **Build APK** workflow produce them on every push to `main`.

## 8. Smoke test on a phone, signed in as each role

- **Admin** — dashboard loads; Dispatch → New dispatch asks for buyer and
  vehicle and shows bundles and bags per product; Settings → Shifts shows only
  Morning and Night with no way to add one; More → Material Entry opens.
- **Operator** — home shows the attendance card; Production Entry offers bags
  only for a mapped product and asks whether wastage material was used; My
  Entries shows the last seven days; Profile → Edit changes name and phone.

## If something goes wrong

0015 adds columns and switches a shift off. It drops no data. To step back:

```sql
-- Put the Afternoon shift back in use (the trigger refuses this by design,
-- so disable it for the moment):
alter table public.shifts disable trigger shifts_guard;
update public.shifts set active = true where lower(name) = 'afternoon';
alter table public.shifts enable trigger shifts_guard;
```

A full reversal is not provided, because the app on the phones will by then
expect the new columns. Restoring the backup from step 1 is the real rollback.
