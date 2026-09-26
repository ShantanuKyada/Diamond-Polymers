// Local Postgres harness: stands up a Supabase-shaped database in PGlite so the
// migrations can actually be executed and exercised before they touch the real
// project.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
export const SUP = join(HERE, '..');
export const MIG = join(SUP, 'migrations');

// Everything Supabase provides that a bare Postgres does not.
const PRELUDE = `
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- Supabase reads the caller's identity out of the JWT. A GUC stands in for it
-- so tests can switch identity with: select set_config('request.jwt.claim.sub', '<uuid>', true)
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

do $$ begin create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin;  exception when duplicate_object then null; end $$;
do $$ begin create role supabase_admin nologin superuser; exception when duplicate_object then null; end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;
grant select on auth.users   to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;

do $$ begin create publication supabase_realtime; exception when duplicate_object then null; end $$;
`;

// PGlite has no pgcrypto, but gen_random_uuid() is core since PG13, which is all
// the migrations actually use it for.
function patch(sql) {
  return sql.replace(/create extension if not exists pgcrypto;/gi, '-- pgcrypto: core in PG13+');
}

// `upto` stops after the named migration and skips the seeds, so a test can
// build yesterday's schema, put yesterday's data in it, and then apply the
// next migration with applyMigration() - the path a live database takes.
export async function build({ seed = true, quiet = false, upto = null } = {}) {
  const db = await PGlite.create();
  await db.exec(PRELUDE);

  const files = [
    `${MIG}/0001_schema.sql`,
    `${MIG}/0002_helpers.sql`,
    `${MIG}/0003_views.sql`,
    `${MIG}/0004_rpc.sql`,
    `${MIG}/0005_rls.sql`,
    `${MIG}/0006_manufacturing_enums.sql`,
    `${MIG}/0007_manufacturing_schema.sql`,
    `${MIG}/0008_manufacturing_rpc.sql`,
    `${MIG}/0009_manufacturing_views.sql`,
    `${MIG}/0010_manufacturing_rls.sql`,
    `${MIG}/0011_reporting_and_identity.sql`,
    `${MIG}/0012_payroll_schema.sql`,
    `${MIG}/0013_payroll_rpc.sql`,
    `${MIG}/0014_payroll_views_rls.sql`,
    `${MIG}/0015_packaging_shifts_access.sql`,
    `${MIG}/0016_operator_material_entry.sql`,
    `${MIG}/0017_factory_identity.sql`,
    `${MIG}/0018_production_batch_link.sql`,
  ];
  if (upto) {
    const cut = files.findIndex((f) => f.endsWith(upto));
    if (cut < 0) throw new Error(`unknown migration: ${upto}`);
    files.splice(cut + 1);
  } else if (seed) {
    files.push(`${SUP}/seed.sql`, `${SUP}/seed_manufacturing.sql`);
  }

  for (const f of files) {
    const name = f.split('/').pop();
    try {
      await db.exec(patch(readFileSync(f, 'utf8')));
      if (!quiet) console.log(`  ok   ${name}`);
    } catch (e) {
      // Print the parts of a Postgres error that identify the problem, then
      // stop. Rethrowing dumps PGlite's whole bundled source into the terminal
      // and buries the one line that matters.
      console.log(`  FAIL ${name}`);
      console.log(`       ${e.message}`);
      if (e.detail) console.log(`       detail: ${e.detail}`);
      if (e.hint) console.log(`       hint:   ${e.hint}`);
      if (e.where) console.log(`       where:  ${String(e.where).split('\n')[0]}`);
      process.exit(1);
    }
  }

  // Supabase grants table privileges to the API roles; RLS is what restricts
  // them. Applied after the migrations so it covers every table they created.
  await db.exec(`
    grant all on all tables in schema public to anon, authenticated, service_role;
    grant all on all sequences in schema public to anon, authenticated, service_role;
  `);

  return db;
}

export async function applyMigration(db, name) {
  await db.exec(patch(readFileSync(`${MIG}/${name}`, 'utf8')));
  await db.exec(`
    grant all on all tables in schema public to anon, authenticated, service_role;
  `);
}

/// Charges a machine with material and returns the batch id.
///
/// Since A37 a production entry belongs to the batch it came out of, so a test
/// that records production needs a batch first — exactly as the floor does.
/// Call it inside an `asUser` block: the caller must be an administrator, or
/// the operator assigned to that machine.
export async function chargeBatch(db, { machineId, shiftId, materialId, quantity = 25 }) {
  const r = await db.query(
    `select public.consume_raw_materials($1,$2,$3::jsonb,$4) as j`,
    [machineId, shiftId,
      JSON.stringify([{ raw_material_id: materialId, quantity }]),
      crypto.randomUUID()]);
  return r.rows[0].j.id;
}

// Run as the given profile's login, the way PostgREST would.
export async function asUser(db, authUserId, fn) {
  await db.exec(`set role authenticated;`);
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [authUserId]);
  try {
    return await fn();
  } finally {
    await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false);`);
  }
}
