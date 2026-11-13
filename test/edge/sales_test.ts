// sales-total against the real local stack (sales_job_claim / sales_job_finish run
// for real). the sales source is faked by running the function's own index.ts from a temp
// copy whose ./source.ts is a scripted fake: it can answer an amount, throw
// SalesError('login' | 'timeout' | 'shape' | 'config'), throw a plain Error, or
// answer junk. A second copy runs with the real source.ts against a fake sales source
// HTTP server (sales_source_test.ts covers the reader itself).
//
// Contract (slug sales-total): POST {job_id} + header x-job-secret. 405 not POST; 401 secret
// missing or wrong (checked before the body is read); 400 bad body; 200
// {ok, ran:false} if the job is unknown or already taken; 200 {ok, ran:true,
// result:'ok'|'failed'}. Never logs or returns the amount, the password or
// the source's reply. Every failure except 'config' counts toward the auto-off (3 in a row).
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/sales_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const secret = 'qa-sales-' + crypto.randomUUID();
const sourcePassword = 'qa-source-pw-' + crypto.randomUUID();
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);
Deno.env.set('JOB_SHARED_SECRET', secret);

// Everything the function prints, to search for secrets and amounts.
const logged: string[] = [];
for (const k of ['log', 'info', 'warn', 'error', 'debug'] as const) {
  const real = console[k];
  console[k] = (...a: unknown[]) => {
    logged.push(a.map((x) => (x instanceof Error ? `${x.message} ${x.stack}` : typeof x === 'string' ? x : JSON.stringify(x))).join(' '));
    real(...a);
  };
}
// Any request to the sales source host is recorded and refused (the reader must not reach it here).
const sourceHits: string[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (input: Request | URL | string, init?: RequestInit) => {
  const req = new Request(input, init);
  if (req.url.startsWith('http://source.qa.test')) {
    sourceHits.push(req.url);
    return Promise.reject(new TypeError('connection refused'));
  }
  return realFetch(req);
};

// The fake reader, driven by globalThis.__source.
type Script = { amount: string } | { code: string } | { plain: string };
const source: { script: Script; calls: { day: string; prev: boolean }[] } = { script: { amount: '1' }, calls: [] };
(globalThis as Record<string, unknown>).__source = source;
const dir = await Deno.makeTempDir({ prefix: 'sales-qa-' });
await Deno.copyFile(new URL('../../supabase/functions/sales-total/index.ts', import.meta.url), `${dir}/index.ts`);
await Deno.writeTextFile(`${dir}/source.ts`, `
export type SalesErrorCode = 'login' | 'timeout' | 'shape' | 'config';
export class SalesError extends Error { constructor(readonly code: SalesErrorCode) { super(code); } }
export async function fetchSalesTotal(day: string, prev: boolean): Promise<string> {
  const v = (globalThis as any).__source;
  v.calls.push({ day, prev });
  await new Promise((r) => setTimeout(r, 20));
  if ('amount' in v.script) return v.script.amount;
  if ('code' in v.script) throw new SalesError(v.script.code);
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
await import('../../supabase/functions/sales-total/index.ts');
const real = handlers.at(-1)!;
assert(fake !== real, 'two handlers registered');

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });
const [saved] = await sql`select amount, day, fetched_at, fail_count, off from app_private.sales_state`;
const [{ id: conv }] = await sql`insert into public.conversations(system, admin_chat, staff_key)
  values (true, true, 'staff_b') returning id::text`;

async function job(prev = false, day = '2026-03-04'): Promise<string> {
  const [{ id }] = await sql`insert into app_private.sales_jobs(conversation_id, prev, day)
    values (${conv}, ${prev}, ${day}) returning id::text`;
  return id;
}
const jobState = async (id: string) => (await sql`select state from app_private.sales_jobs where id = ${id}`)[0]?.state;
const state = async () => (await sql`select amount, fail_count, off from app_private.sales_state`)[0];
const lastReply = async () =>
  (await sql`select body, admin_msg from public.messages where conversation_id = ${conv}
              order by created_at desc limit 1`)[0];
async function resetState() {
  await sql`update app_private.sales_state set amount = null, day = null, fetched_at = null, fail_count = 0, off = false`;
}

async function call(h: typeof fake, opts: { method?: string; body?: string | null; secret?: string | null } = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  const s = opts.secret === undefined ? secret : opts.secret;
  if (s !== null) headers['x-job-secret'] = s;
  const method = opts.method ?? 'POST';
  const res = await h(new Request(`${apiUrl}/functions/v1/sales-total`, {
    method, headers, body: method === 'POST' ? (opts.body ?? null) : undefined,
  }));
  return { status: res.status, text: await res.text() };
}
const post = (h: typeof fake, jobId: unknown, s?: string | null) => call(h, { body: JSON.stringify({ job_id: jobId }), secret: s });
function reset(script: Script) {
  source.script = script;
  source.calls = [];
}

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({ ...opts, name: 'not POST -> 405, nothing claimed, the sales source untouched', fn: async () => {
  await resetState();
  reset({ amount: '5' });
  const id = await job();
  assertEquals((await call(fake, { method: 'GET' })).status, 405);
  assertEquals(await jobState(id), 'pending');
  assertEquals(source.calls.length, 0);
} });

Deno.test({ ...opts, name: 'no secret header, or a wrong one -> 401, nothing claimed, the sales source untouched', fn: async () => {
  reset({ amount: '5' });
  const id = await job();
  assertEquals((await post(fake, id, null)).status, 401);
  assertEquals((await post(fake, id, 'wrong')).status, 401);
  assertEquals((await post(fake, id, secret + 'x')).status, 401);
  assertEquals((await post(fake, id, secret.slice(0, -1))).status, 401);
  assertEquals((await post(fake, id, secret.slice(0, -1) + (secret.endsWith('0') ? '1' : '0'))).status, 401, 'same length, one byte off');
  assertEquals((await post(fake, id, '')).status, 401);
  assertEquals(await jobState(id), 'pending');
  assertEquals(source.calls.length, 0);
} });

Deno.test({ ...opts, name: 'only the x-job-secret header counts: the right secret under another header name -> 401', fn: async () => {
  reset({ amount: '5' });
  const id = await job();
  for (const name of ['x-secret', 'x-shared-secret', 'x-job-token', 'authorization']) {
    const res = await fake(new Request(`${apiUrl}/functions/v1/sales-total`, {
      method: 'POST', headers: { 'content-type': 'application/json', [name]: name === 'authorization' ? `Bearer ${secret}` : secret },
      body: JSON.stringify({ job_id: id }),
    }));
    assertEquals(res.status, 401, name);
    await res.body?.cancel();
  }
  assertEquals(await jobState(id), 'pending');
  assertEquals(source.calls.length, 0);
} });

Deno.test({ ...opts, name: 'slug: release deploys the sales-total function and points the job URL at the same slug', fn: async () => {
  const wf = await Deno.readTextFile(new URL('../../.github/workflows/release.yml', import.meta.url));
  assert(/supabase functions deploy sales-total /.test(wf), 'release deploys sales-total');
  assert(wf.includes('/functions/v1/sales-total'), 'the job URL in the vault ends in the sales-total slug');
  assert(wf.includes("'job_url'") && wf.includes("'job_secret'"), 'the vault pair is job_url / job_secret');
  assert(wf.includes('JOB_SHARED_SECRET='), 'the function secret is JOB_SHARED_SECRET');
} });

Deno.test({ ...opts, name: 'the secret is checked first: a bad body without the secret -> 401, not 400', fn: async () => {
  assertEquals((await call(fake, { body: 'not json', secret: null })).status, 401);
  assertEquals((await call(fake, { body: JSON.stringify({ job_id: 'nope' }), secret: 'wrong' })).status, 401);
} });

Deno.test({ ...opts, name: 'no JOB_SHARED_SECRET configured -> every call refused, even without a header', fn: async () => {
  reset({ amount: '5' });
  const id = await job();
  Deno.env.delete('JOB_SHARED_SECRET');
  try {
    assertEquals((await post(fake, id, null)).status, 401);
    assertEquals((await post(fake, id, '')).status, 401);
    assertEquals((await post(fake, id, 'undefined')).status, 401);
    assertEquals(await jobState(id), 'pending');
    assertEquals(source.calls.length, 0);
  } finally {
    Deno.env.set('JOB_SHARED_SECRET', secret);
  }
} });

Deno.test({ ...opts, name: 'with the secret, a bad body or job_id -> 400, the sales source untouched', fn: async () => {
  reset({ amount: '5' });
  for (const body of ['not json', '{}', JSON.stringify({ job_id: 'not-a-uuid' }), JSON.stringify({ job_id: 7 }), 'null', '[]']) {
    const r = await call(fake, { body });
    assertEquals(r.status, 400, `${body} -> ${r.status} ${r.text}`);
  }
  assertEquals(source.calls.length, 0);
} });

Deno.test({ ...opts, name: 'success: the sales source asked for the job\'s day and prev; job done; answer stored; amount never returned or logged', fn: async () => {
  await resetState();
  reset({ amount: '9081726354' });
  logged.length = 0;
  const id = await job(true, '2026-03-04');
  const r = await post(fake, id);
  assertEquals(r.status, 200, r.text);
  assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'ok' });
  assertEquals(source.calls, [{ day: '2026-03-04', prev: true }]);
  assertEquals(await jobState(id), 'done');
  const m = await lastReply();
  assertEquals(m.admin_msg.k, 'podPrev');
  assertEquals(m.admin_msg.amt, '9081726354');
  assert(!m.body.includes('9081726354'), 'the body never holds the amount');
  assertEquals((await state()).amount, '9081726354');
  assert(!r.text.includes('9081726354'), 'the response never holds the amount');
  assert(!logged.join('\n').includes('9081726354'), `the amount was logged: ${logged.join(' | ')}`);
} });

Deno.test({ ...opts, name: 'a job is run once: a second call -> 200 ran:false, the sales source not asked again', fn: async () => {
  reset({ amount: '42' });
  const id = await job();
  assertEquals(JSON.parse((await post(fake, id)).text).ran, true);
  source.calls = [];
  const r = await post(fake, id);
  assertEquals(r.status, 200);
  assertEquals(JSON.parse(r.text), { ok: true, ran: false });
  assertEquals(source.calls.length, 0);
} });

Deno.test({ ...opts, name: 'an unknown job -> 200 ran:false, the sales source not asked', fn: async () => {
  reset({ amount: '42' });
  const r = await post(fake, crypto.randomUUID());
  assertEquals(r.status, 200);
  assertEquals(JSON.parse(r.text), { ok: true, ran: false });
  assertEquals(source.calls.length, 0);
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
  assert(!all.includes('<html>') && !all.includes('12 TL') && !all.includes('5550123'), `the source's reply or an error text was logged: ${all}`);
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

// A fake the sales source on 127.0.0.1 for the real reader (index.ts + source.ts together).
let sourceDurum: string[] = [];
let sourceTotal = '8.642.097,31';
const fakeSource = realServe({ hostname: '127.0.0.1', port: 0, onListen: () => {} }, (req) => {
  const u = new URL(req.url);
  if (u.pathname === '/Authentication/LoginAction') {
    return new Response(null, { status: 302, headers: { location: '/', 'set-cookie': 'ASP.NET_SessionId=qa; path=/' } });
  }
  sourceDurum.push(u.searchParams.get('durum') ?? '');
  return new Response(`<div class="dash-stat-label">Toplam Ciro</div>
    <a class="tarihLink dash-stat-value" href="/CiroRaporlar/List">${sourceTotal}</a>`);
});
function sourceEnv(base: string) {
  Deno.env.set('SALES_SOURCE_URL', base);
  Deno.env.set('SALES_SOURCE_USER', 'qa-user');
  Deno.env.set('SALES_SOURCE_PASSWORD', sourcePassword);
}
function clearsourceEnv() {
  for (const k of ['SALES_SOURCE_URL', 'SALES_SOURCE_USER', 'SALES_SOURCE_PASSWORD']) Deno.env.delete(k);
}

Deno.test({ ...opts, name: 'the real reader against a fake sales source: prev job reads durum=dun, the total is stored and answered', fn: async () => {
  await resetState();
  sourceEnv(`http://127.0.0.1:${fakeSource.addr.port}`);
  logged.length = 0;
  try {
    for (const [prev, durum] of [[true, 'dun'], [false, 'bugun']] as const) {
      sourceDurum = [];
      const id = await job(prev);
      const r = await post(real, id);
      assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'ok' }, r.text);
      assertEquals(sourceDurum, [durum]);
      assertEquals(await jobState(id), 'done');
      const m = (await lastReply()).admin_msg;
      assertEquals([m.k, m.amt], [prev ? 'podPrev' : 'pod', '8.642.097,31']);
      assertEquals((await state()).amount, '8.642.097,31');
    }
    assert(!logged.join('\n').includes('8.642.097') && !logged.join('\n').includes(sourcePassword), `logged: ${logged.join(' | ')}`);
  } finally {
    clearsourceEnv();
  }
} });

// Was "the placeholder reader ... is not counted": the placeholder failed every
// configured call without counting. The real reader now calls the sales source; a refused
// connection is a plain Error => reason 'other', which counts (3 in a row => off).
Deno.test({ ...opts, name: 'the real reader with the sales source unreachable fails the job, counts toward the auto-off, the password never leaves', fn: async () => {
  await resetState();
  sourceEnv('http://source.qa.test:9698');
  logged.length = 0;
  sourceHits.length = 0;
  try {
    for (let i = 1; i <= 3; i++) {
      const id = await job();
      const r = await post(real, id);
      assertEquals(r.status, 200, r.text);
      assertEquals(JSON.parse(r.text).result, 'failed');
      assertEquals(await jobState(id), 'failed');
      assert(!r.text.includes(sourcePassword));
      const st = await state();
      assertEquals([st.fail_count, st.off], [i, i === 3], `after ${i} refused connection(s)`);
    }
    assert(sourceHits.length >= 3, 'the reader did try the sales source');
    assert(!logged.join('\n').includes(sourcePassword), 'the sales source password was logged');
    assert(sourceHits.every((u) => !u.includes(sourcePassword) && !u.includes('qa-user')), `credentials in a URL: ${sourceHits}`);
  } finally {
    clearsourceEnv();
  }
} });

Deno.test({ ...opts, name: 'the real reader with no sales source config fails the job without counting it', fn: async () => {
  await resetState();
  const id = await job();
  const r = await post(real, id);
  assertEquals(JSON.parse(r.text).result, 'failed');
  const st = await state();
  assertEquals([st.fail_count, st.off], [0, false]);
} });

// Real page shapes (t_7c0a1a1920): today can be a whole number with no
// separators ("7"); yesterday looked like "99.999,99". Page -> parse -> reply.
Deno.test({ ...opts, name: 'the real reader: a whole-number total ("7", "12345") and a dotted one ("99.999,99") are answered exactly as on the page', fn: async () => {
  sourceEnv(`http://127.0.0.1:${fakeSource.addr.port}`);
  try {
    for (const total of ['7', '12345', '99.999,99']) {
      for (const prev of [false, true]) {
        await resetState();
        sourceTotal = total;
        const id = await job(prev);
        const r = await post(real, id);
        assertEquals(JSON.parse(r.text), { ok: true, ran: true, result: 'ok' }, `${total} prev=${prev}: ${r.text}`);
        const m = (await lastReply()).admin_msg;
        assertEquals([m.k, m.amt], [prev ? 'podPrev' : 'pod', total], `${total} prev=${prev}`);
        assertEquals(await state(), { amount: total, fail_count: 0, off: false }, `${total} prev=${prev}`);
      }
    }
  } finally {
    sourceTotal = '8.642.097,31';
    clearsourceEnv();
  }
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  try {
    await sql`delete from public.conversations where id = ${conv}`;
    await sql`update app_private.sales_state set amount = ${saved.amount}, day = ${saved.day}, fetched_at = ${saved.fetched_at},
                fail_count = ${saved.fail_count}, off = ${saved.off}`;
  } catch (e) {
    console.error('teardown:', (e as Error).message);
  }
  await sql.end();
  await fakeSource.shutdown();
  await Deno.remove(dir, { recursive: true });
} });
