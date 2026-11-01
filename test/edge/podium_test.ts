// podium against the real local stack (podium_job_claim / podium_job_finish run
// for real). Vega is faked by running the function's own index.ts from a temp
// copy whose ./vega.ts is a scripted fake: it can answer an amount, throw
// VegaError('login' | 'timeout' | 'shape' | 'config'), throw a plain Error, or
// answer junk. A second copy runs with the real vega.ts against a fake Vega
// HTTP server (podium_vega_test.ts covers the reader itself).
//
// Contract: POST {job_id} + header x-podium-secret. 405 not POST; 401 secret
// missing or wrong (checked before the body is read); 400 bad body; 200
// {ok, ran:false} if the job is unknown or already taken; 200 {ok, ran:true,
// result:'ok'|'failed'}. Never logs or returns the amount, the password or
// Vega's reply. Every failure except 'config' counts toward the auto-off (3 in a row).
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/podium_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const secret = 'qa-podium-' + crypto.randomUUID();
const vegaPassword = 'qa-vega-pw-' + crypto.randomUUID();
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);
Deno.env.set('PODIUM_SHARED_SECRET', secret);

// Everything the function prints, to search for secrets and amounts.
const logged: string[] = [];
for (const k of ['log', 'info', 'warn', 'error', 'debug'] as const) {
  const real = console[k];
  console[k] = (...a: unknown[]) => {
    logged.push(a.map((x) => (x instanceof Error ? `${x.message} ${x.stack}` : typeof x === 'string' ? x : JSON.stringify(x))).join(' '));
    real(...a);
  };
}
// Any request to the Vega host is recorded and refused (the reader must not reach it here).
const vegaHits: string[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (input: Request | URL | string, init?: RequestInit) => {
  const req = new Request(input, init);
  if (req.url.startsWith('http://vega.qa.test')) {
    vegaHits.push(req.url);
    return Promise.reject(new TypeError('connection refused'));
  }
  return realFetch(req);
};

// The fake reader, driven by globalThis.__vega.
type Script = { amount: string } | { code: string } | { plain: string };
const vega: { script: Script; calls: { day: string; prev: boolean }[] } = { script: { amount: '1' }, calls: [] };
(globalThis as Record<string, unknown>).__vega = vega;
const dir = await Deno.makeTempDir({ prefix: 'podium-qa-' });
await Deno.copyFile(new URL('../../supabase/functions/podium/index.ts', import.meta.url), `${dir}/index.ts`);
await Deno.writeTextFile(`${dir}/vega.ts`, `
export type VegaErrorCode = 'login' | 'timeout' | 'shape' | 'config';
export class VegaError extends Error { constructor(readonly code: VegaErrorCode) { super(code); } }
export async function fetchVegaTotal(day: string, prev: boolean): Promise<string> {
  const v = (globalThis as any).__vega;
  v.calls.push({ day, prev });
  await new Promise((r) => setTimeout(r, 20));
  if ('amount' in v.script) return v.script.amount;
  if ('code' in v.script) throw new VegaError(v.script.code);
  throw new Error(v.script.plain);
}
`);

const handlers: ((req: Request) => Response | Promise<Response>)[] = [];
(globalThis as Record<string, unknown>).EdgeRuntime = { waitUntil: () => {} };
const realServe = Deno.serve.bind(Deno);
Object.defineProperty(Deno, 'serve', {
  configurable: true,
  writable: true,
  value: (h: (req: Request) => Response | Promise<Response>) => {
    handlers.push(h);
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  },
});
await import(`file://${dir}/index.ts`);
const fake = handlers.at(-1)!;
await import('../../supabase/functions/podium/index.ts');
const real = handlers.at(-1)!;
assert(fake !== real, 'two handlers registered');

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });
const [saved] = await sql`select amount, day, fetched_at, fail_count, off from app_private.podium_state`;
const [{ id: conv }] = await sql`insert into public.conversations(system, admin_chat, bacanaks_chat)
  values (true, true, true) returning id::text`;

async function job(prev = false, day = '2026-03-04'): Promise<string> {
  const [{ id }] = await sql`insert into app_private.podium_jobs(conversation_id, prev, day)
    values (${conv}, ${prev}, ${day}) returning id::text`;
  return id;
}
const jobState = async (id: string) => (await sql`select state from app_private.podium_jobs where id = ${id}`)[0]?.state;
const state = async () => (await sql`select amount, fail_count, off from app_private.podium_state`)[0];
const lastReply = async () =>
  (await sql`select body, admin_msg from public.messages where conversation_id = ${conv}
              order by created_at desc limit 1`)[0];
async function resetState() {
  await sql`update app_private.podium_state set amount = null, day = null, fetched_at = null, fail_count = 0, off = false`;
}

async function call(h: typeof fake, opts: { method?: string; body?: string | null; secret?: string | null } = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  const s = opts.secret === undefined ? secret : opts.secret;
  if (s !== null) headers['x-podium-secret'] = s;
  const method = opts.method ?? 'POST';
  const res = await h(new Request(`${apiUrl}/functions/v1/podium`, {
    method, headers, body: method === 'POST' ? (opts.body ?? null) : undefined,
  }));
  return { status: res.status, text: await res.text() };
}
const post = (h: typeof fake, jobId: unknown, s?: string | null) => call(h, { body: JSON.stringify({ job_id: jobId }), secret: s });
function reset(script: Script) {
  vega.script = script;
  vega.calls = [];
}

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({ ...opts, name: 'not POST -> 405, nothing claimed, Vega untouched', fn: async () => {
  await resetState();
  reset({ amount: '5' });
  const id = await job();
  assertEquals((await call(fake, { method: 'GET' })).status, 405);
  assertEquals(await jobState(id), 'pending');
  assertEquals(vega.calls.length, 0);
} });

Deno.test({ ...opts, name: 'no secret header, or a wrong one -> 401, nothing claimed, Vega untouched', fn: async () => {
  reset({ amount: '5' });
  const id = await job();
  assertEquals((await post(fake, id, null)).status, 401);
  assertEquals((await post(fake, id, 'wrong')).status, 401);
  assertEquals((await post(fake, id, secret + 'x')).status, 401);
  assertEquals((await post(fake, id, secret.slice(0, -1))).status, 401);
  assertEquals((await post(fake, id, secret.slice(0, -1) + (secret.endsWith('0') ? '1' : '0'))).status, 401, 'same length, one byte off');
  assertEquals((await post(fake, id, '')).status, 401);
  assertEquals(await jobState(id), 'pending');
  assertEquals(vega.calls.length, 0);
} });

Deno.test({ ...opts, name: 'the secret is checked first: a bad body without the secret -> 401, not 400', fn: async () => {
  assertEquals((await call(fake, { body: 'not json', secret: null })).status, 401);
  assertEquals((await call(fake, { body: JSON.stringify({ job_id: 'nope' }), secret: 'wrong' })).status, 401);
} });

Deno.test({ ...opts, name: 'no PODIUM_SHARED_SECRET configured -> every call refused, even without a header', fn: async () => {
  reset({ amount: '5' });
  const id = await job();
  Deno.env.delete('PODIUM_SHARED_SECRET');
  try {
    assertEquals((await post(fake, id, null)).status, 401);
    assertEquals((await post(fake, id, '')).status, 401);
    assertEquals((await post(fake, id, 'undefined')).status, 401);
    assertEquals(await jobState(id), 'pending');
    assertEquals(vega.calls.length, 0);
  } finally {
    Deno.env.set('PODIUM_SHARED_SECRET', secret);
  }
} });

Deno.test({ ...opts, name: 'with the secret, a bad body or job_id -> 400, Vega untouched', fn: async () => {
  reset({ amount: '5' });
  for (const body of ['not json', '{}', JSON.stringify({ job_id: 'not-a-uuid' }), JSON.stringify({ job_id: 7 }), 'null', '[]']) {
    const r = await call(fake, { body });
    assertEquals(r.status, 400, `${body} -> ${r.status} ${r.text}`);
  }
  assertEquals(vega.calls.length, 0);
} });

Deno.test({ ...opts, name: 'success: Vega asked for the job\'s day and prev; job done; answer stored; amount never returned or logged', fn: async () => {
  await resetState();
  reset({ amount: '9081726354' });
  logged.length = 0;
  const id = await job(true, '2026-03-04');
  const r = await post(fake, id);
  assertEquals(r.status, 200, r.text);
  assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'ok' });
  assertEquals(vega.calls, [{ day: '2026-03-04', prev: true }]);
  assertEquals(await jobState(id), 'done');
  const m = await lastReply();
  assertEquals(m.admin_msg.k, 'podPrev');
  assertEquals(m.admin_msg.amt, '9081726354');
  assert(!m.body.includes('9081726354'), 'the body never holds the amount');
  assertEquals((await state()).amount, '9081726354');
  assert(!r.text.includes('9081726354'), 'the response never holds the amount');
  assert(!logged.join('\n').includes('9081726354'), `the amount was logged: ${logged.join(' | ')}`);
} });

Deno.test({ ...opts, name: 'a job is run once: a second call -> 200 ran:false, Vega not asked again', fn: async () => {
  reset({ amount: '42' });
  const id = await job();
  assertEquals(JSON.parse((await post(fake, id)).text).ran, true);
  vega.calls = [];
  const r = await post(fake, id);
  assertEquals(r.status, 200);
  assertEquals(JSON.parse(r.text), { ok: true, ran: false });
  assertEquals(vega.calls.length, 0);
} });

Deno.test({ ...opts, name: 'an unknown job -> 200 ran:false, Vega not asked', fn: async () => {
  reset({ amount: '42' });
  const r = await post(fake, crypto.randomUUID());
  assertEquals(r.status, 200);
  assertEquals(JSON.parse(r.text), { ok: true, ran: false });
  assertEquals(vega.calls.length, 0);
} });

Deno.test({ ...opts, name: 'three login failures in a row turn the command off', fn: async () => {
  await resetState();
  for (let i = 1; i <= 3; i++) {
    reset({ code: 'login' });
    const id = await job();
    const r = await post(fake, id);
    assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'failed' });
    assertEquals(await jobState(id), 'failed');
    assertEquals((await lastReply()).admin_msg, { k: 'podFail' });
    assertEquals((await state()).off, i === 3, `off after ${i} login failure(s)`);
  }
} });

Deno.test({ ...opts, name: 'every failure but config counts toward the auto-off; config does not; junk is never stored or logged', fn: async () => {
  logged.length = 0;
  const cases: [Script, number][] = [
    [{ code: 'config' }, 0],
    [{ code: 'shape' }, 1], [{ code: 'timeout' }, 1], [{ code: 'login' }, 1],
    [{ amount: '<html>login</html>' }, 1], [{ amount: '' }, 1], [{ amount: '12 TL' }, 1],
    [{ plain: 'boom 5550123' }, 1],
  ];
  for (const [s, counted] of cases) {
    await resetState();
    reset(s);
    const id = await job();
    const r = await post(fake, id);
    assertEquals(r.status, 200, r.text);
    assertEquals(JSON.parse(r.text).result, 'failed', JSON.stringify(s));
    assertEquals((await lastReply()).admin_msg, { k: 'podFail' });
    const st = await state();
    assertEquals([st.fail_count, st.off], [counted, false], `${JSON.stringify(s)}: fail_count`);
    assertEquals(st.amount, null, 'junk is never stored');
  }
  const all = logged.join('\n');
  assert(!all.includes('<html>') && !all.includes('12 TL') && !all.includes('5550123'), `Vega's reply or an error text was logged: ${all}`);
} });

Deno.test({ ...opts, name: 'amount rule (<= 25 chars, strict number shape): accepted ones are stored as is, refused ones are a counted failure', fn: async () => {
  const good = ['12.345,67', '1234', '0', '1,5', '1.23', "1'234", '1 234,5', '1,234', '999.999.999,99', '1'.repeat(25),
    '12.345.678.901.234.567,89', '1234567,89'];
  const bad = ['1.2.3,4,5', '1,', '1.', '.5', '1234.567', '12,34,567', '1..2', '1,234,5678', '1'.repeat(26),
    '123.456.789.012.345.678,90', '1 234 ', '+5'];
  for (const [amount, ok] of [...good.map((a) => [a, true] as const), ...bad.map((a) => [a, false] as const)]) {
    await resetState();
    reset({ amount });
    const id = await job();
    const r = await post(fake, id);
    assertEquals(r.status, 200, r.text);
    assertEquals(JSON.parse(r.text).result, ok ? 'ok' : 'failed', `amount ${JSON.stringify(amount)}`);
    const st = await state();
    assertEquals([st.amount, st.fail_count], ok ? [amount, 0] : [null, 1], `amount ${JSON.stringify(amount)}: stored, fail_count`);
    if (ok) assertEquals((await lastReply()).admin_msg.amt, amount);
    else assertEquals((await lastReply()).admin_msg, { k: 'podFail' });
  }
} });

// A fake Vega on 127.0.0.1 for the real reader (index.ts + vega.ts together).
let vegaDurum: string[] = [];
const fakeVega = realServe({ hostname: '127.0.0.1', port: 0, onListen: () => {} }, (req) => {
  const u = new URL(req.url);
  if (u.pathname === '/Authentication/LoginAction') {
    return new Response(null, { status: 302, headers: { location: '/', 'set-cookie': 'ASP.NET_SessionId=qa; path=/' } });
  }
  vegaDurum.push(u.searchParams.get('durum') ?? '');
  return new Response(`<div class="dash-stat-label">Toplam Ciro</div>
    <a class="tarihLink dash-stat-value" href="/CiroRaporlar/List">8.642.097,31</a>`);
});
function vegaEnv(base: string) {
  Deno.env.set('VEGA_BASE_URL', base);
  Deno.env.set('VEGA_USERNAME', 'qa-user');
  Deno.env.set('VEGA_PASSWORD', vegaPassword);
}
function clearVegaEnv() {
  for (const k of ['VEGA_BASE_URL', 'VEGA_USERNAME', 'VEGA_PASSWORD']) Deno.env.delete(k);
}

Deno.test({ ...opts, name: 'the real reader against a fake Vega: prev job reads durum=dun, the total is stored and answered', fn: async () => {
  await resetState();
  vegaEnv(`http://127.0.0.1:${fakeVega.addr.port}`);
  logged.length = 0;
  try {
    for (const [prev, durum] of [[true, 'dun'], [false, 'bugun']] as const) {
      vegaDurum = [];
      const id = await job(prev);
      const r = await post(real, id);
      assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'ok' }, r.text);
      assertEquals(vegaDurum, [durum]);
      assertEquals(await jobState(id), 'done');
      const m = (await lastReply()).admin_msg;
      assertEquals([m.k, m.amt], [prev ? 'podPrev' : 'pod', '8.642.097,31']);
      assertEquals((await state()).amount, '8.642.097,31');
    }
    assert(!logged.join('\n').includes('8.642.097') && !logged.join('\n').includes(vegaPassword), `logged: ${logged.join(' | ')}`);
  } finally {
    clearVegaEnv();
  }
} });

// Was "the placeholder reader ... is not counted": the placeholder failed every
// configured call without counting. The real reader now calls Vega; a refused
// connection is a plain Error => reason 'other', which counts (3 in a row => off).
Deno.test({ ...opts, name: 'the real reader with Vega unreachable fails the job, counts toward the auto-off, the password never leaves', fn: async () => {
  await resetState();
  vegaEnv('http://vega.qa.test:9698');
  logged.length = 0;
  vegaHits.length = 0;
  try {
    for (let i = 1; i <= 3; i++) {
      const id = await job();
      const r = await post(real, id);
      assertEquals(r.status, 200, r.text);
      assertEquals(JSON.parse(r.text).result, 'failed');
      assertEquals(await jobState(id), 'failed');
      assert(!r.text.includes(vegaPassword));
      const st = await state();
      assertEquals([st.fail_count, st.off], [i, i === 3], `after ${i} refused connection(s)`);
    }
    assert(vegaHits.length >= 3, 'the reader did try Vega');
    assert(!logged.join('\n').includes(vegaPassword), 'the Vega password was logged');
    assert(vegaHits.every((u) => !u.includes(vegaPassword) && !u.includes('qa-user')), `credentials in a URL: ${vegaHits}`);
  } finally {
    clearVegaEnv();
  }
} });

Deno.test({ ...opts, name: 'the real reader with no Vega config fails the job without counting it', fn: async () => {
  await resetState();
  const id = await job();
  const r = await post(real, id);
  assertEquals(JSON.parse(r.text).result, 'failed');
  const st = await state();
  assertEquals([st.fail_count, st.off], [0, false]);
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  try {
    await sql`delete from public.conversations where id = ${conv}`;
    await sql`update app_private.podium_state set amount = ${saved.amount}, day = ${saved.day}, fetched_at = ${saved.fetched_at},
                fail_count = ${saved.fail_count}, off = ${saved.off}`;
  } catch (e) {
    console.error('teardown:', (e as Error).message);
  }
  await sql.end();
  await fakeVega.shutdown();
  await Deno.remove(dir, { recursive: true });
} });
