// The Vega reader (supabase/functions/podium/vega.ts) against a fake Vega HTTP
// server on 127.0.0.1. Never calls the real Vega address. No database needed.
//
// Contract: fetchVegaTotal(day, prev). Env VEGA_BASE_URL (trailing slashes
// stripped), VEGA_USERNAME, VEGA_PASSWORD; any missing => VegaError('config')
// before any request. 1) POST {base}/Authentication/LoginAction, form
// UygulamaTipi=3, UserName, Password, redirect manual; cookie = every Set-Cookie
// name=value joined "; "; status >= 400 or no Set-Cookie => 'login' (302 with a
// cookie is fine). 2) GET {base}/OzetRaporlar/List?durum=dun (prev) | bugun,
// header Cookie, redirect manual; status >= 300 => 'login'. The text of the
// .dash-stat-value after "Toplam Ciro" is returned unchanged; missing, empty or
// not [0-9.,] => 'shape'; a reply over ~1 MiB => 'shape'. 15 s over both calls
// => 'timeout'. Refused connection => plain Error (not VegaError). Nothing is
// logged; no error holds the password, cookie, page or amount.
//
// Run: docker run --rm -v "$PWD":/w -w /w denoland/deno:2.9.7 \
//   test --no-check --no-lock --allow-all test/edge/podium_vega_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { fetchVegaTotal, VegaError } from '../../supabase/functions/podium/vega.ts';

const password = 'qa-vega-pw-' + crypto.randomUUID();
const cookieVal = 'qa-cookie-' + crypto.randomUUID();

const logged: string[] = [];
for (const k of ['log', 'info', 'warn', 'error', 'debug'] as const) {
  const real = console[k];
  console[k] = (...a: unknown[]) => {
    logged.push(a.map(String).join(' '));
    real(...a);
  };
}

type Hit = { method: string; path: string; search: string; cookie: string | null; ctype: string | null; body: string };
type Reply = (req: Request, hit: Hit) => Response | Promise<Response>;
const hits: Hit[] = [];
let onLogin: Reply = () => new Response(null, { status: 302, headers: loginCookies() });
let onList: Reply = () => new Response(page('37.652,00'));

function loginCookies(): Headers {
  const h = new Headers({ location: '/' });
  h.append('set-cookie', `ASP.NET_SessionId=${cookieVal}; path=/; HttpOnly; SameSite=Lax`);
  h.append('set-cookie', '.AspNetCore.Auth=qa2; path=/; secure');
  return h;
}
function page(total: string, pad = ''): string {
  return `<html><body>${pad}
  <div class="dash-stat"><div class="dash-stat-label">Toplam Adisyon</div>
    <a class="tarihLink dash-stat-value" href="/x">812</a></div>
  <div class="dash-stat"><div class="dash-stat-label">Toplam Ciro</div>
    <a class="tarihLink dash-stat-value" href="/CiroRaporlar/List">${total}</a></div>
  <div class="dash-stat"><div class="dash-stat-label">Adisyon Ort.</div>
    <a class="tarihLink dash-stat-value" href="/x">46,37</a></div>
  <span>&#8378;37.652,00</span> COFFEE GATE---PODIUM</body></html>`;
}

const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen: () => {} }, async (req) => {
  const u = new URL(req.url);
  const hit: Hit = {
    method: req.method, path: u.pathname, search: u.search, cookie: req.headers.get('cookie'),
    ctype: req.headers.get('content-type'), body: await req.text(),
  };
  hits.push(hit);
  if (u.pathname === '/Authentication/LoginAction') return onLogin(req, hit);
  if (u.pathname === '/OzetRaporlar/List') return onList(req, hit);
  return new Response('not found', { status: 404 });
});
const base = `http://127.0.0.1:${server.addr.port}`;

function setup(over: Partial<Record<'VEGA_BASE_URL' | 'VEGA_USERNAME' | 'VEGA_PASSWORD', string | null>> = {}) {
  const env = { VEGA_BASE_URL: base + '/', VEGA_USERNAME: 'qa-user', VEGA_PASSWORD: password, ...over };
  for (const [k, v] of Object.entries(env)) v === null ? Deno.env.delete(k) : Deno.env.set(k, v);
  hits.length = 0;
  logged.length = 0;
  onLogin = () => new Response(null, { status: 302, headers: loginCookies() });
  onList = () => new Response(page('37.652,00'));
}

// Every failure: the right kind, and nothing secret in the error or the log.
async function fails(code: VegaErrorCode | 'plain', prev = false): Promise<unknown> {
  let err: unknown;
  try {
    const v = await fetchVegaTotal('2026-03-04', prev);
    throw new Error(`expected ${code}, got the value ${JSON.stringify(v)}`);
  } catch (e) {
    err = e;
  }
  if (code === 'plain') assert(!(err instanceof VegaError), `expected a plain Error, got VegaError(${(err as VegaError).code})`);
  else {
    assert(err instanceof VegaError, `expected VegaError(${code}), got ${err}`);
    assertEquals(err.code, code);
  }
  const text = `${String(err)} ${(err as Error).message} ${(err as Error).stack} ${JSON.stringify(err)} ${logged.join(' ')}`;
  for (const s of [password, cookieVal, 'Toplam', '37.652', '<html', 'qa-user']) {
    assert(!text.includes(s), `the error or the log holds ${s}: ${text}`);
  }
  return err;
}
type VegaErrorCode = 'login' | 'timeout' | 'shape' | 'config';

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({ ...opts, name: 'today (prev=false): logs in with the form, sends the cookies, reads durum=bugun, returns the total as is', fn: async () => {
  setup();
  assertEquals(await fetchVegaTotal('2026-03-04', false), '37.652,00');
  assertEquals(hits.length, 2);
  const [login, list] = hits;
  assertEquals([login.method, login.path, login.search], ['POST', '/Authentication/LoginAction', '']);
  assert(login.ctype?.startsWith('application/x-www-form-urlencoded'), `login content-type ${login.ctype}`);
  const form = new URLSearchParams(login.body);
  assertEquals([form.get('UygulamaTipi'), form.get('UserName'), form.get('Password')], ['3', 'qa-user', password]);
  assertEquals([list.method, list.path], ['GET', '/OzetRaporlar/List']);
  assertEquals(new URLSearchParams(list.search).get('durum'), 'bugun');
  assertEquals(list.cookie, `ASP.NET_SessionId=${cookieVal}; .AspNetCore.Auth=qa2`, 'every Set-Cookie name=value, joined "; "');
  assertEquals(logged, [], 'nothing is logged');
} });

Deno.test({ ...opts, name: 'yesterday (prev=true): reads durum=dun; the day argument does not change the request', fn: async () => {
  setup();
  onList = (_r, h) => new Response(page(new URLSearchParams(h.search).get('durum') === 'dun' ? '1.234.567,89' : '1,00'));
  assertEquals(await fetchVegaTotal('2026-03-04', true), '1.234.567,89');
  assertEquals(new URLSearchParams(hits[1].search).get('durum'), 'dun');
  const first = hits.map((h) => h.path + h.search);
  hits.length = 0;
  assertEquals(await fetchVegaTotal('1999-01-01', true), '1.234.567,89');
  assertEquals(hits.map((h) => h.path + h.search), first);
} });

Deno.test({ ...opts, name: 'trailing slashes on VEGA_BASE_URL are stripped (no // in the paths)', fn: async () => {
  setup({ VEGA_BASE_URL: base + '///' });
  assertEquals(await fetchVegaTotal('d', false), '37.652,00');
  assertEquals(hits.map((h) => h.path), ['/Authentication/LoginAction', '/OzetRaporlar/List']);
} });

Deno.test({ ...opts, name: 'missing config => config, before any request', fn: async () => {
  for (const k of ['VEGA_BASE_URL', 'VEGA_USERNAME', 'VEGA_PASSWORD'] as const) {
    for (const v of [null, '']) {
      setup({ [k]: v });
      await fails('config');
      assertEquals(hits.length, 0, `${k}=${v}: no request`);
    }
  }
} });

Deno.test({ ...opts, name: 'login refused (200 without cookie, 401, 500 with cookie) => login, no list request', fn: async () => {
  const replies: Reply[] = [
    () => new Response('<html>Hatali sifre</html>', { status: 200 }),
    () => new Response(null, { status: 401 }),
    () => new Response('err', { status: 500, headers: loginCookies() }),
    () => new Response(null, { status: 302, headers: { location: '/Authentication/Login' } }),
  ];
  for (const r of replies) {
    setup();
    onLogin = r;
    await fails('login');
    assertEquals(hits.map((h) => h.path), ['/Authentication/LoginAction']);
  }
} });

Deno.test({ ...opts, name: 'the list redirects to login, or errors => login', fn: async () => {
  for (const status of [302, 301, 303, 307, 401, 403, 500]) {
    setup();
    onList = () => new Response(null, { status, headers: status < 400 ? { location: '/Authentication/Login' } : {} });
    await fails('login');
    assertEquals(hits.length, 2, `${status}: the redirect is not followed`);
  }
} });

Deno.test({ ...opts, name: 'missing or garbled total => shape (another card\'s value is never taken)', fn: async () => {
  const bodies = [
    '<html><body>Bakim calismasi</body></html>',
    page('').replace('Toplam Ciro', 'Toplam Cirox'),
    page('').replace('Toplam Ciro', 'Toplam Adisyon2'),
    page(''),
    page('   '),
    page('abc'),
    page('₺37.652,00'),
    page('37.652,00 TL'),
    page('37.652,00').replace(/dash-stat-value" href="\/CiroRaporlar/, 'dash-stat-x" href="/CiroRaporlar'),
    '',
  ];
  for (const b of bodies) {
    setup();
    onList = () => new Response(b);
    await fails('shape');
  }
} });

Deno.test({ ...opts, name: 'a reply under ~1 MiB is read in full; over 1 MiB => shape even if the total comes first', fn: async () => {
  setup();
  onList = () => new Response(page('5,00', 'x'.repeat(900 * 1024)));
  assertEquals(await fetchVegaTotal('d', false), '5,00', '900 KiB page with the total at the end');
  setup();
  onList = () => new Response(page('5,00') + 'x'.repeat(2 * 1024 * 1024));
  await fails('shape');
} });

Deno.test({ ...opts, name: 'an endless reply is cut at the cap => shape, quickly (not a timeout)', fn: async () => {
  setup();
  const chunk = new TextEncoder().encode(page('5,00') + 'y'.repeat(64 * 1024));
  let sent = 0;
  let cancelled = false;
  // 8 MiB, then the stream stalls (never closes): a reader without the cap ends in a timeout, not 'shape'.
  onList = () => new Response(new ReadableStream({
    async pull(c) {
      if (sent >= 8 * 1024 * 1024) return await new Promise(() => {});
      sent += chunk.length;
      c.enqueue(chunk);
    },
    cancel() { cancelled = true; },
  }));
  const t0 = Date.now();
  let timer = 0;
  await Promise.race([
    fails('shape'),
    new Promise((_, rej) => timer = setTimeout(() => rej(new Error('no answer in 20 s')), 20000)),
  ]).finally(() => clearTimeout(timer));
  assert(Date.now() - t0 < 5000, `took ${Date.now() - t0} ms`);
  assert(sent < 8 * 1024 * 1024, `read ${sent} bytes`);
  await new Promise((r) => setTimeout(r, 200));
  assert(cancelled, 'the body stream is cancelled');
} });

Deno.test({ ...opts, name: 'a slow Vega => timeout; the 15 s budget covers both calls together', fn: async () => {
  setup();
  // Each call alone is under 15 s; together they are over.
  onLogin = async () => {
    await new Promise((r) => setTimeout(r, 8000));
    return new Response(null, { status: 302, headers: loginCookies() });
  };
  onList = async () => {
    await new Promise((r) => setTimeout(r, 9000));
    return new Response(page('37.652,00'));
  };
  const t0 = Date.now();
  await fails('timeout');
  const ms = Date.now() - t0;
  assert(ms >= 14000 && ms < 16500, `timed out after ${ms} ms`);
} });

Deno.test({ ...opts, name: 'connection refused => a plain Error (index reports other); no secret in it', fn: async () => {
  const l = Deno.listen({ hostname: '127.0.0.1', port: 0 });
  const port = (l.addr as Deno.NetAddr).port;
  l.close();
  setup({ VEGA_BASE_URL: `http://127.0.0.1:${port}` });
  await fails('plain');
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  for (const k of ['VEGA_BASE_URL', 'VEGA_USERNAME', 'VEGA_PASSWORD']) Deno.env.delete(k);
  await server.shutdown();
} });
