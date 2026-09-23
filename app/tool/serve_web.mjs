// Serves `build/web` on the local network, so the app can be opened on a phone
// without an APK.
//
//   flutter build web --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
//   node tool/serve_web.mjs
//
// It binds 0.0.0.0 and prints every address it can be reached on. Windows may
// ask to allow node through the firewall the first time; the phone has to be on
// the same network.
//
// This exists because Gradle cannot build an APK on a machine where
// `Selector.open()` is blocked (see docs/06-phase-2-admin-masters.md). It is a
// stopgap for testing on a handset, not a deployment mechanism.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', 'build', 'web');
const PORT = Number(process.env.PORT ?? 8099);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
};

const server = http.createServer(async (req, res) => {
  let path = decodeURIComponent((req.url ?? '/').split('?')[0]);
  if (path === '/') path = '/index.html';

  // Normalise away any `..` so a request cannot climb out of build/web.
  const target = join(ROOT, normalize(path).replace(/^(\.\.[/\\])+/, ''));
  if (!target.startsWith(ROOT)) {
    res.writeHead(403).end('forbidden');
    return;
  }

  try {
    const body = await readFile(target);
    res.writeHead(200, {
      'Content-Type': TYPES[extname(target)] ?? 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(body);
  } catch {
    // Flutter web routes are client-side, so anything unresolved falls back to
    // index.html rather than 404ing a deep link.
    try {
      res.writeHead(200, { 'Content-Type': TYPES['.html'] });
      res.end(await readFile(join(ROOT, 'index.html')));
    } catch {
      res.writeHead(404).end('build/web not found — run flutter build web first');
    }
  }
});

server.listen(PORT, '0.0.0.0', () => {
  const addresses = ['localhost'];
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) addresses.push(entry.address);
    }
  }
  console.log('Serving build/web on:');
  for (const address of addresses) console.log(`  http://${address}:${PORT}`);
  console.log('\nOpen one of the non-localhost addresses on a phone that is on');
  console.log('the same WiFi. Ctrl+C to stop.');
});
