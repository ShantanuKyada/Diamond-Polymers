# Going live: the real backend, and an APK that talks to it

The demo APK carries its own data and needs nothing. A live APK needs a
Supabase project that matches the code, and credentials baked in at build
time. This is the whole path, in order.

**Three things stand between you and a working live APK.** None of them is
code; all three are yours to do, because they need credentials that must not
pass through anybody else's hands.

| | What | Where | Roughly |
|---|---|---|---|
| 1 | Bring the database from 0014 to 0024 | Supabase SQL editor | 15 min |
| 2 | Put the URL and key in repository secrets | GitHub settings | 3 min |
| 3 | Build the APK | GitHub Actions | 10 min, unattended |

---

## 0. Where the project actually is

Run this first. Everything below assumes the answer.

```sql
select
  to_regclass('public.pipe_products') is not null                as has_products,
  exists (select 1 from information_schema.columns
          where table_name = 'pipe_products' and column_name = 'pipes_per_bag')
                                                                 as has_0015,
  exists (select 1 from information_schema.columns
          where table_name = 'production_entries'
            and column_name = 'mixture_entry_id')                as has_0018,
  exists (select 1 from public.app_settings
          where key = 'entry_backdating_days')                   as has_0024;
```

- All false but `has_products` → you are at **0014**. Follow step 1.
- `has_0024` true → the database is already current. Skip to step 2.
- `has_products` false → this is an empty project. Apply `migrations/0001`
  through `0024` in order, following `docs/02-setup.md`, and note that
  **0006 must be run on its own** — it adds enum values, and Postgres will not
  let a new label be used in the transaction that created it.

---

## 1. Bring the database to 0024

### Back up first

Supabase Dashboard → Database → Backups → take one, and wait for it to finish.
Everything below is designed to be safe. A backup is what makes that claim
cheap to test.

### Pre-flight

Paste `supabase/checks/0015_preflight.sql` into the SQL editor and run it.
Seven rows come back. **Read all of them.** It will tell you which shift is
about to be retired, how much history is riding on it, and whether the ledgers
agree with the balance caches before anything moves. If the last row is false,
stop — the balances are already wrong, and a migration is the wrong moment to
discover it.

### Apply

Paste **`supabase/scripts/apply_0015_to_0024.sql`** — the whole file — and run
it. That is ten migrations in order:

| | |
|---|---|
| 0015 | bags beside bundles, two shifts, editable profile |
| 0016 | operators record their own material (reverses 0015's admin-only rule) |
| 0017 | the factory's own name, address and GSTIN |
| 0018 | a production entry knows the batch that fed it |
| 0019 | the simplified payroll |
| 0020 | worker profiles and salary payments |
| 0021 | employee types, and running any machine |
| 0022 | the roles the factory names for itself |
| 0023 | retires two settings nothing read |
| 0024 | entry dates enforced in the database; recycled stock admin-only |

They travel together because none of them adds an enum value. The file is
generated from `migrations/` by `supabase/scripts/build_apply_script.py`, and
`supabase/tests/go_live.test.mjs` applies it to a database shaped like yours —
three shifts, an operator on the one that disappears, material receipts and
production posted through the real RPCs — then checks every production entry,
the bundle total, both stock balances, the ledgers and the administrator's
login. It also applies the ten files separately and proves both paths land in
the same place, and that running the whole thing twice changes nothing.

**If it stops partway**, read the error, fix the cause, and run the same file
again. Every migration in it is written to be re-runnable, and the second run
is tested.

### Verify

Run each of these and expect every row to read true:

```
supabase/checks/0015_verify.sql
supabase/checks/0019_verify.sql
supabase/checks/0020_verify.sql
supabase/checks/0021_verify.sql
supabase/checks/0022_verify.sql
```

Then the one that matters most:

```sql
select * from public.v_stock_reconciliation where not ok;
```

Zero rows. Any row means a stock movement wrote a balance its ledger does not
explain, and you should restore the backup rather than carry on.

`0015_verify.sql`'s last row may report operators stranded on the retired
shift. That is information, not a failure: reassign them under **Employees**
once the app is up.

### If the project was seeded for a demonstration

Two scripts, and they answer different questions:

- `supabase/checks/clean_demo_data.sql` clears the records of work — production,
  batches, wastage, dispatch, attendance, payroll, every stock movement and the
  sample operators — and **keeps** the catalogue, so the factory can record an
  entry the moment it finishes. It keeps anybody who already has a login.
- `supabase/scripts/go_live_clear_demo_data.sql` clears the catalogue too,
  because a seeded catalogue is invented.

Both take a backup first, both are one transaction, both print verification
rows that must all read true.

---

## 2. Put the credentials in repository secrets

The build needs two values. **Do not paste them into a chat, an issue, or a
commit.** GitHub's secret form is the only place they should go.

Supabase Dashboard → Project Settings → API:

| Secret name | What to paste |
|---|---|
| `SUPABASE_URL` | Project URL, `https://xxxx.supabase.co` |
| `SUPABASE_ANON_KEY` | The **anon / publishable** key |

**Never the `service_role` key.** It ignores row level security, and a key
inside an APK is a key in every operator's pocket. The anon key is designed to
ship in a client; the service key would hand the whole database to anyone who
unzips the file.

GitHub → the repository → Settings → Secrets and variables → Actions → *New
repository secret*, twice.

### While you are there: the signing key

Without it, Android refuses to install a new build over an old one — every CI
run signs with a throwaway debug key, so each APK is a stranger to the one on
the phone. `docs/14-signing-the-apk.md` has the `keytool` command. It produces
four more secrets:

```
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

The build works without them and names the artifact
`…-UNSIGNED-fresh-install-only` so nobody finds out on the factory floor.
**Back the keystore up somewhere you will still have it in five years.** Lose
it and no future build can ever update an installed app.

---

## 3. Build the APK

With the secrets in place, **every push to `main` builds one automatically**.
To build on demand:

```bash
gh workflow run build-apk.yml --ref main
```

Or GitHub → Actions → **Build APK** → *Run workflow*. The two input boxes let
you paste a URL and key for a one-off build without storing them — which is
how the one successful build so far was made.

The run analyzes, runs the Flutter suite and the database suite, then builds.
Download from the **Artifacts** section:

| File | Install on |
|---|---|
| `app-release.apk` | anything — largest, safest to hand to a stranger |
| `app-arm64-v8a-release.apk` | any phone from roughly 2015 on |
| `app-armeabi-v7a-release.apk` | older 32-bit phones |

---

## 4. The first sign-in

The database has profiles but no logins, because a person can be on the
factory's roll without an app account (A3).

1. Dashboard → Authentication → Users → **Add user**, *Auto Confirm User*
   ticked, for the administrator.
2. Link it, once, by hand — there is no signed-in admin yet to do it for you:

```sql
update public.profiles p
set    auth_user_id = u.id
from   auth.users u
where  u.email = 'admin@diamondpolymers.local'
  and  p.employee_code = 'EMP-001';
```

3. Sign in. Everybody else is added in the app under **Employees**, then given
   a login the same way — from then on the app calls
   `link_profile_to_auth_user()` and you never touch SQL again.

If somebody cannot sign in, `supabase/checks/diagnose_login.sql` says why.

---

## 5. Before handing it to the floor

- Open **More → Configuration → Products** and set **Pipes per bag** on the
  products that are bagged. Until it is set, the Bags box stays disabled —
  the database cannot weigh a bag without it (A26).
- Check **How far back an entry may be dated** suits the factory. Default 30
  days; 0 means today only (A46).
- Record one production entry and one dispatch, then run the reconciliation
  query again. It is the cheapest proof that the whole chain works.
