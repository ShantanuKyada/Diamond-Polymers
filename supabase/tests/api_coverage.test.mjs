// Every Supabase call in the Flutter app, checked against the real schema.
//
// app_contract.test.mjs lists the calls by hand. This one reads them straight
// out of `app/lib/**/data/*.dart`, so a new repository method is covered the
// moment it is written — nobody has to remember to add it here.
//
// For each call it proves, against the migrated database:
//   * RPC      — the function exists, every parameter name the app sends is a
//                real argument, and `authenticated` may execute it;
//   * table/view — the relation exists, and every column the app selects,
//                filters, orders by, writes, or parses in the model exists.
import { build } from './harness.mjs';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const APP_LIB = join(HERE, '..', '..', 'app', 'lib');

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; failures.push(`${name} ${extra}`); console.log(`  FAIL  ${name}  ${extra}`); }
}
function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`); }

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

const dartFiles = walk(APP_LIB).filter((p) => p.endsWith('.dart'));
const repoFiles = dartFiles.filter((p) => /[\\/]features[\\/][^\\/]+[\\/]data[\\/]/.test(p));

// --- model keys: which columns each Model.from(row) reads ---------------------
const modelKeys = new Map();
for (const file of dartFiles.filter((p) => /[\\/](domain|data)[\\/]/.test(p))) {
  const src = readFileSync(file, 'utf8');
  const parts = src.split(/^class\s+(\w+)/m);
  for (let i = 1; i < parts.length; i += 2) {
    const keys = [...parts[i + 1].matchAll(/row\['([a-z_0-9]+)'\]/g)].map((m) => m[1]);
    if (keys.length) modelKeys.set(parts[i], new Set(keys));
  }
}

// --- extract calls ----------------------------------------------------------
// The text of a call: from its start up to the end of the statement (`;`),
// with nested parentheses balanced.
function statementFrom(src, start) {
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    const c = src[i];
    if (c === '(' || c === '{' || c === '[') depth++;
    else if (c === ')' || c === '}' || c === ']') depth--;
    else if (c === ';' && depth <= 0) return src.slice(start, i);
  }
  return src.slice(start);
}

const rpcCalls = [];
const relationCalls = [];

for (const file of repoFiles) {
  const src = readFileSync(file, 'utf8');
  const where = relative(join(APP_LIB, '..'), file).replaceAll('\\', '/');

  for (const m of src.matchAll(/\.rpc(?:<[^()]*?>)?\(\s*'([a-z_0-9]+)'/g)) {
    const text = statementFrom(src, m.index);
    const paramsBlock = text.match(/params:\s*\{([\s\S]*)\}/);
    const params = paramsBlock
      ? [...paramsBlock[1].matchAll(/'(p_[a-z_0-9]+)'\s*:/g)].map((x) => x[1])
      : [];
    rpcCalls.push({ name: m[1], params: [...new Set(params)], where });
  }

  for (const m of src.matchAll(/\.from\('([a-z_0-9]+)'\)/g)) {
    // Walk back to the start of the statement so a `var query =` chain that
    // continues on later lines is still seen whole.
    const text = statementFrom(src, m.index);
    const cols = new Set();

    for (const s of text.matchAll(/\.select\(\s*'([^']*)'/g)) {
      s[1].split(',').map((c) => c.trim()).filter(Boolean).forEach((c) => cols.add(c));
    }
    for (const f of text.matchAll(/\.(?:eq|neq|gte|lte|gt|lt|order|inFilter|isFilter)\(\s*'([a-z_0-9]+)'/g)) {
      cols.add(f[1]);
    }
    for (const w of text.matchAll(/\.(?:insert|update|upsert)\(\s*\{([\s\S]*?)\}\s*[,)]/g)) {
      [...w[1].matchAll(/'([a-z_0-9]+)'\s*:/g)].forEach((k) => cols.add(k[1]));
    }

    const model = text.match(/map\((\w+)\.from\)/) ?? text.match(/(\w+)\.from(?:Rows)?\(rows\)/);
    const modelName = model?.[1];
    if (modelName && modelKeys.has(modelName)) {
      modelKeys.get(modelName).forEach((k) => cols.add(k));
    }

    relationCalls.push({ relation: m[1], cols: [...cols], model: modelName, where });
  }

  // Filters applied later on a `query` variable built from `.from(...)`.
  for (const m of src.matchAll(/var query = _client\s*\.from\('([a-z_0-9]+)'\)[\s\S]*?(?=\n\s*(?:final rows|return|\}))/g)) {
    const block = src.slice(m.index, m.index + 2500);
    const end = block.indexOf('final rows');
    const scope = end > 0 ? block.slice(0, end + 400) : block;
    const cols = new Set();
    for (const f of scope.matchAll(/\.(?:eq|neq|gte|lte|gt|lt|order)\(\s*'([a-z_0-9]+)'/g)) cols.add(f[1]);
    const model = scope.match(/map\((\w+)\.from\)/)?.[1];
    if (model && modelKeys.has(model)) modelKeys.get(model).forEach((k) => cols.add(k));
    relationCalls.push({ relation: m[1], cols: [...cols], model, where: `${relative(join(APP_LIB, '..'), repoFiles.find((f) => readFileSync(f, 'utf8') === src)).replaceAll('\\', '/')} (query chain)` });
  }
}

console.log(`\nFound ${rpcCalls.length} RPC calls and ${relationCalls.length} table/view reads/writes in ${repoFiles.length} repositories.`);

// --- check against the schema -------------------------------------------------
const db = await build({ quiet: true });

section('RPCs');
const seen = new Set();
for (const call of rpcCalls) {
  const key = `${call.name}(${call.params.sort().join(',')})`;
  if (seen.has(key)) continue;
  seen.add(key);

  const fns = (await db.query(
    `select coalesce(array_to_string(p.proargnames, ','), '') as args,
            has_function_privilege('authenticated', p.oid, 'execute') as can_run
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = $1`, [call.name])).rows;

  if (fns.length === 0) {
    check(`${call.name} exists`, false, `(called from ${call.where})`);
    continue;
  }
  check(`${call.name} is a single function, not ambiguous overloads`, fns.length === 1,
    `${fns.length} overloads`);

  const args = fns[0].args.split(',');
  const missing = call.params.filter((p) => !args.includes(p));
  check(`${call.name} accepts ${call.params.length ? call.params.join(', ') : 'no parameters'}`,
    missing.length === 0, `unknown: ${missing.join(', ')} (from ${call.where})`);
  check(`${call.name} is callable by signed-in users`, fns[0].can_run === true);
}

section('Tables and views');
const byRelation = new Map();
for (const call of relationCalls) {
  const entry = byRelation.get(call.relation) ?? { cols: new Set(), where: new Set() };
  call.cols.forEach((c) => entry.cols.add(c));
  entry.where.add(call.where);
  byRelation.set(call.relation, entry);
}

for (const [relation, { cols, where }] of [...byRelation].sort()) {
  const present = (await db.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = $1`, [relation])).rows.map((r) => r.column_name);

  if (present.length === 0) {
    check(`${relation} exists`, false, `(used in ${[...where].join(', ')})`);
    continue;
  }
  const missing = [...cols].filter((c) => !present.includes(c));
  check(`${relation} has all ${cols.size} columns the app uses`, missing.length === 0,
    `missing: ${missing.join(', ')}`);
}

console.log(`\n${'═'.repeat(64)}\n  ${pass} passed, ${fail} failed\n${'═'.repeat(64)}`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
