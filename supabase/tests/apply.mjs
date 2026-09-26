// Applies the migrations to a real Postgres — normally the Supabase project.
//
//   DATABASE_URL="postgresql://..." node apply.mjs [--seed] [--dry-run]
//
// or, when the password contains characters that a URL would mangle (`*`, `!`,
// `#`, `@` and friends all have meaning inside a connection string):
//
//   PGHOST=db.<ref>.supabase.co PGUSER=postgres PGPASSWORD='...' node apply.mjs --seed
//
// Credentials are read from the environment and never written to disk or echoed,
// so they do not end up in a shell history file or a log.
//
// On Windows, `VAR=value command` is bash syntax and will not work in cmd.exe.
// Use Git Bash, or PowerShell's `$env:PGPASSWORD='...'` on a preceding line.
//
// Ordering rules this script respects:
//   * files run in numeric order, and a failure stops the run;
//   * each file is wrapped in its own transaction, so a file either lands
//     completely or not at all — except 0006, which adds enum values and must
//     run in autocommit for the new labels to be usable by 0007.
import pg from 'pg';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUP = join(HERE, '..');
const MIG = join(SUP, 'migrations');

const args = process.argv.slice(2);
const withSeed = args.includes('--seed');
const dryRun = args.includes('--dry-run');
// Drops and recreates the public and app schemas before applying. Destructive,
// and refuses to run if anyone has signed up, on the assumption that a project
// with real logins has real data behind them.
const reset = args.includes('--reset');

// Files that must NOT be wrapped in a transaction.
const AUTOCOMMIT = new Set(['0006_manufacturing_enums.sql']);

const files = [
  '0001_schema.sql', '0002_helpers.sql', '0003_views.sql',
  '0004_rpc.sql', '0005_rls.sql',
  '0006_manufacturing_enums.sql', '0007_manufacturing_schema.sql',
  '0008_manufacturing_rpc.sql', '0009_manufacturing_views.sql',
  '0010_manufacturing_rls.sql', '0011_reporting_and_identity.sql',
  '0012_payroll_schema.sql', '0013_payroll_rpc.sql', '0014_payroll_views_rls.sql',
  // 0015 adds no enum values, so it stays inside a transaction and lands whole
  // or not at all.
  '0015_packaging_shifts_access.sql',
  '0016_operator_material_entry.sql',
  '0017_factory_identity.sql',
  '0018_production_batch_link.sql',
].map((n) => ({ name: n, path: join(MIG, n) }));

if (withSeed) {
  files.push({ name: 'seed.sql', path: join(SUP, 'seed.sql') });
  files.push({ name: 'seed_manufacturing.sql', path: join(SUP, 'seed_manufacturing.sql') });
}

// The full list only replays cleanly against an empty database: 0001 creates
// types and tables unconditionally, so re-running it on a live project fails.
// Once the schema is applied, new migrations go on with --from or --only.
//   --from=0011   this file and everything after it
//   --only=0011   just the files whose name contains this
const from = args.find((a) => a.startsWith('--from='))?.slice(7);
const only = args.find((a) => a.startsWith('--only='))?.slice(7);

let selected = files;
if (only) {
  selected = files.filter((f) => f.name.includes(only));
} else if (from) {
  const at = files.findIndex((f) => f.name.includes(from));
  if (at === -1) {
    console.error(`No migration matches --from=${from}`);
    process.exit(2);
  }
  selected = files.slice(at);
}
if (!selected.length) {
  console.error(`Nothing matched. Known files:\n  ${files.map((f) => f.name).join('\n  ')}`);
  process.exit(2);
}

if (dryRun) {
  console.log('Would apply, in order:');
  for (const f of selected) console.log(`  ${f.name}${AUTOCOMMIT.has(f.name) ? "  (autocommit)" : ""}`);
  process.exit(0);
}

// Either a full URL, or the standard PG* variables. The second form exists
// because a password with a `*` or `!` in it is a URL-escaping accident waiting
// to happen, and the failure looks like a wrong password rather than a typo.
const url = process.env.DATABASE_URL;
if (!url && !process.env.PGHOST) {
  console.error('Set DATABASE_URL, or PGHOST/PGUSER/PGPASSWORD, before running.');
  process.exit(2);
}

const client = new pg.Client({
  // Omitting connectionString lets node-postgres fall back to PGHOST/PGUSER/
  // PGPASSWORD/PGDATABASE/PGPORT on its own.
  ...(url ? { connectionString: url } : {}),
  ssl: { rejectUnauthorized: false },
  application_name: 'diamond-polymers-migrate',
});

await client.connect();
const who = await client.query('select current_database() db, current_user usr, version()');
console.log(`Connected to ${who.rows[0].db} as ${who.rows[0].usr}`);
console.log(`${who.rows[0].version.split(',')[0]}\n`);

if (reset) {
  const users = await client.query('select count(*)::int n from auth.users');
  if (users.rows[0].n > 0) {
    console.error(`Refusing to reset: ${users.rows[0].n} auth user(s) exist.`);
    console.error('A project with logins has data behind them. Drop the schemas by hand');
    console.error('if you are certain, or apply without --reset.');
    await client.end();
    process.exit(1);
  }

  const ext = await client.query(
    `select e.extname from pg_extension e join pg_namespace n on n.oid = e.extnamespace
     where n.nspname = 'public'`);
  if (ext.rows.length) {
    console.error(`Refusing to reset: extensions live in public (${ext.rows.map(r => r.extname).join(', ')}).`);
    await client.end();
    process.exit(1);
  }

  await client.query(`
    drop schema if exists app cascade;
    drop schema if exists public cascade;
    create schema public;
    grant usage on schema public to anon, authenticated, service_role;
    grant all on schema public to postgres, service_role;
    alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
    alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
    alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  `);
  console.log('  reset  public and app schemas dropped and recreated\n');
}

let applied = 0;
for (const f of selected) {
  const sql = readFileSync(f.path, 'utf8');
  const wrap = !AUTOCOMMIT.has(f.name);
  try {
    if (wrap) await client.query('begin');
    await client.query(sql);
    if (wrap) await client.query('commit');
    applied++;
    console.log(`  ok    ${f.name}`);
  } catch (e) {
    if (wrap) await client.query('rollback').catch(() => {});
    console.error(`  FAIL  ${f.name}`);
    console.error(`        ${e.message}`);
    if (e.detail) console.error(`        detail: ${e.detail}`);
    if (e.hint) console.error(`        hint:   ${e.hint}`);
    if (e.position) console.error(`        at character ${e.position}`);
    await client.end();
    process.exit(1);
  }
}

console.log(`\n${applied} files applied.\n`);

// ---------------------------------------------------------------------------
// Verify. The reconciliation view re-derives every balance from its ledger, so
// an empty result is a proof rather than an assumption.
// ---------------------------------------------------------------------------
const checks = [
  ['tables', `select count(*)::int n from information_schema.tables
              where table_schema='public' and table_type='BASE TABLE'`],
  ['views', `select count(*)::int n from information_schema.views where table_schema='public'`],
  ['rpcs', `select count(*)::int n from pg_proc p join pg_namespace s on s.oid=p.pronamespace
            where s.nspname='public'`],
  ['rls-enabled tables', `select count(*)::int n from pg_tables t
            join pg_class c on c.relname=t.tablename
            join pg_namespace ns on ns.oid=c.relnamespace and ns.nspname=t.schemaname
            where t.schemaname='public' and c.relrowsecurity`],
  ['tables WITHOUT rls', `select count(*)::int n from pg_tables t
            join pg_class c on c.relname=t.tablename
            join pg_namespace ns on ns.oid=c.relnamespace and ns.nspname=t.schemaname
            where t.schemaname='public' and not c.relrowsecurity`],
  ['products with a bundle weight', `select count(*)::int n from public.pipe_products where bundle_weight_kg > 0`],
  ['stock drift (must be 0)', `select count(*)::int n from public.v_stock_reconciliation where not ok`],
];

for (const [label, q] of checks) {
  try {
    const r = await client.query(q);
    console.log(`  ${String(r.rows[0].n).padStart(4)}  ${label}`);
  } catch (e) {
    console.log(`   err  ${label}: ${e.message}`);
  }
}

const drift = await client.query('select * from public.v_stock_reconciliation where not ok');
if (drift.rows.length) {
  console.error('\nSTOCK DRIFT DETECTED — a balance does not match its ledger:');
  console.error(drift.rows);
  process.exit(1);
}
console.log('\nEvery cached balance is explained by its ledger.');

await client.end();
