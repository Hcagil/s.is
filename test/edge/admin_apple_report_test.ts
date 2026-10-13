// admin-apple-report against the real local stack (admin_job_claim, _progress
// and _finish run for real). Only GitHub's JWKS is faked, at fetch: it serves
// the public half of a key generated here, and every OIDC token is minted at
// run time with that key.
//
// Contract: POST with a Bearer GitHub OIDC token; body {action: claim |
// progress | finish, job_id, attempt?, ok?, reason?}. 405 not POST; 400 bad
// body; 403 not_permitted for ANY token failure, with no detail; 502 jwks.
// claim -> 200 {kind, email} or 409 not_claimable. progress: attempt 2 or 3
// else 400. finish: ok boolean else 400; reason rejected / dispatch, anything
// else timeout. An RPC error -> 500 failed, logging only error.code. Never
// sends pushes, never logs bodies.
// Before any fetch the token must have three parts and a header with alg
// RS256 and a kid, else 403 with no fetch. The JWKS is cached at module level
// for 10 minutes; an unknown kid refetches at most once a minute; a failed
// refetch keeps the old cache; a failed first fetch is 502 jwks, not cached.
// The tests run in order: the first two need the module cache still empty.
// Date.now is shifted (clock) to cross the 1-minute and 10-minute marks.
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/admin_apple_report_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { OIDC_ISSUER, OIDC_JWKS_URL } from '../../supabase/functions/_shared/github_oidc.ts';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const repoId = '424242';
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);
Deno.env.set('GITHUB_REPOSITORY_ID', repoId);

// --- a movable clock: real time plus an offset the tests can advance ---------
const realNow = Date.now.bind(Date);
let clockOffset = 0;
Date.now = () => realNow() + clockOffset;

// --- keys and tokens, made at run time ---------------------------------------
const rsa = { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
const key = await crypto.subtle.generateKey(rsa, true, ['sign', 'verify']);
const other = await crypto.subtle.generateKey(rsa, true, ['sign', 'verify']);
const jwk = { ...(await crypto.subtle.exportKey('jwk', key.publicKey)), kid: 'qa-kid', alg: 'RS256', use: 'sig' };
const jwk2 = { ...(await crypto.subtle.exportKey('jwk', other.publicKey)), kid: 'qa-kid-2', alg: 'RS256', use: 'sig' };
let served: Record<string, unknown>[] = [jwk];
const b64url = (b: Uint8Array | string) =>
  btoa(String.fromCharCode(...(typeof b === 'string' ? new TextEncoder().encode(b) : b)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
let runSeq = 7_000_000 + Math.floor(Math.random() * 1_000_000);
async function oidc(over: Record<string, unknown> = {}, signer = key.privateKey,
  header: Record<string, unknown> = { alg: 'RS256', typ: 'JWT', kid: 'qa-kid' }) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: OIDC_ISSUER, aud: 'sis-admin-apple', repository_id: repoId,
    workflow_ref: 'Hcagil/s.is/.github/workflows/admin-apple.yml@refs/heads/main',
    ref: 'refs/heads/main', event_name: 'workflow_dispatch', run_id: String(++runSeq),
    iat: now - 5, nbf: now - 5, exp: now + 300, ...over,
  };
  const head = b64url(JSON.stringify(header));
  const body = b64url(JSON.stringify(claims));
  const sig = new Uint8Array(await crypto.subtle.sign(rsa, signer, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

// --- fetch: the JWKS is faked; everything else is recorded and goes through ---
const fetched: string[] = [];
let jwksDown: false | 'status' | 'drop' = false;
const realFetch = globalThis.fetch;
globalThis.fetch = (input: Request | URL | string, init?: RequestInit) => {
  const url = input instanceof Request ? input.url : String(input);
  fetched.push(url);
  if (url === OIDC_JWKS_URL) {
    // A 503 that still carries a valid key set: only the status says it failed.
    if (jwksDown === 'status') return Promise.resolve(new Response(JSON.stringify({ keys: served }), { status: 503 }));
    if (jwksDown === 'drop') return Promise.reject(new TypeError('error sending request: connection reset'));
    return Promise.resolve(new Response(JSON.stringify({ keys: served }), { status: 200 }));
  }
  return realFetch(input, init);
};

// --- logs: captured, to prove no body, email or token is ever written --------
const logged: string[] = [];
for (const m of ['log', 'info', 'warn', 'error', 'debug'] as const) {
  const real = console[m];
  console[m] = (...a: unknown[]) => {
    logged.push(a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x) ?? String(x))).join(' '));
    real(...a);
  };
}

const handlers: ((req: Request) => Response | Promise<Response>)[] = [];
(globalThis as Record<string, unknown>).EdgeRuntime = { waitUntil: () => {} };
Object.defineProperty(Deno, 'serve', {
  configurable: true,
  writable: true,
  value: (h: (req: Request) => Response | Promise<Response>) => {
    handlers.push(h);
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  },
});
await import('../../supabase/functions/admin-apple-report/index.ts');
const fn = handlers.at(-1)!;

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });
const run = Date.now().toString(36);
const made: string[] = [];
const tokens: string[] = [];
async function job(kind = 'add'): Promise<{ id: string; email: string }> {
  const email = `aar-${run}-${made.length}@mail.test`;
  const [{ id }] = await sql`insert into app_private.admin_jobs(kind, email, email_masked)
    values (${kind}, ${email}, 'a***@m***.test') returning id::text`;
  made.push(id);
  return { id, email };
}
const row = async (id: string) =>
  (await sql`select state, run_id::text, fail_reason, email from app_private.admin_jobs where id = ${id}`)[0];

async function call(body: unknown, token?: string | null, method = 'POST') {
  if (token) tokens.push(token);
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fn(new Request(`${apiUrl}/functions/v1/admin-apple-report`, {
    method, headers, body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  }));
  const text = await res.text();
  let json: unknown = null;
  try {
    json = JSON.parse(text);
  } catch { /* not json */ }
  return { status: res.status, text, json };
}
const runOf = (t: string) => JSON.parse(new TextDecoder().decode(
  Uint8Array.from(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0)),
)).run_id as string;

// A job claimed by a fresh run: [token, job].
async function claimed(kind = 'add') {
  const j = await job(kind);
  const t = await oidc();
  const r = await call({ action: 'claim', job_id: j.id }, t);
  assertEquals(r.status, 200, r.text);
  return { t, j };
}

const opts = { sanitizeOps: false, sanitizeResources: false };

const jwksFetches = () => fetched.filter((u) => u === OIDC_JWKS_URL).length;

// First, with the module cache empty: a malformed token never reaches a fetch.
Deno.test({ ...opts, name: 'a malformed token -> 403 not_permitted before any fetch', fn: async () => {
  const j = await job();
  const good = await oidc();
  const [, body, sig] = good.split('.');
  const bad: [string, string][] = [
    ['two parts', `${good.split('.')[0]}.${body}`],
    ['four parts', `${good}.x`],
    ['header not JSON', `${b64url('not json')}.${body}.${sig}`],
    ['alg none', await oidc({}, key.privateKey, { alg: 'none', kid: 'qa-kid' })],
    ['alg HS256', await oidc({}, key.privateKey, { alg: 'HS256', kid: 'qa-kid' })],
    ['alg RS512', await oidc({}, key.privateKey, { alg: 'RS512', kid: 'qa-kid' })],
    ['no kid', await oidc({}, key.privateKey, { alg: 'RS256', typ: 'JWT' })],
    ['kid not a string', await oidc({}, key.privateKey, { alg: 'RS256', kid: 7 })],
  ];
  const fetchedBy: string[] = [];
  for (const [name, t] of bad) {
    const before = jwksFetches();
    const r = await call({ action: 'claim', job_id: j.id }, t);
    assertEquals(r.status, 403, `${name}: ${r.text}`);
    assertEquals(r.json, { error: 'not_permitted' }, name);
    if (jwksFetches() > before) fetchedBy.push(name);
  }
  assertEquals(fetchedBy, [], 'these malformed tokens caused a JWKS fetch');
  assertEquals(fetched.length, 0, 'nor any other fetch');
  assertEquals((await row(j.id)).state, 'pending');
} });

// Still before any successful fetch: a failure is 502 and is not cached.
Deno.test({ ...opts, name: 'the JWKS unreachable -> 502 jwks, nothing claimed', fn: async () => {
  try {
    const j = await job();
    for (const mode of ['status', 'drop', 'status'] as const) {
      jwksDown = mode;
      const before = jwksFetches();
      const r = await call({ action: 'claim', job_id: j.id }, await oidc());
      assertEquals(r.status, 502, `${mode}: ${r.text}`);
      assertEquals(r.json, { error: 'jwks' });
      assertEquals(jwksFetches(), before + 1, `${mode}: a failed fetch is not cached, each call tries again`);
    }
    assertEquals((await row(j.id)).state, 'pending');
  } finally {
    jwksDown = false;
  }
} });

Deno.test({ ...opts, name: 'not POST -> 405', fn: async () => {
  assertEquals((await call(null, await oidc(), 'GET')).status, 405);
} });

Deno.test({ ...opts, name: 'a bad body -> 400', fn: async () => {
  const j = await job();
  for (const b of ['not json', {}, { action: 'claim' }, { action: 'claim', job_id: 'nope' },
    { action: 'explode', job_id: j.id }, { job_id: j.id }]) {
    const r = await call(b, await oidc());
    assertEquals(r.status, 400, `${JSON.stringify(b)}: ${r.text}`);
  }
  assertEquals((await row(j.id)).state, 'pending', 'nothing happened to the job');
} });

Deno.test({ ...opts, name: 'any token failure -> 403 not_permitted, no detail, the job untouched', fn: async () => {
  const j = await job();
  const bad: [string, string | null][] = [
    ['no token', null],
    ['not a JWT', 'garbage'],
    // Three parts with an empty payload passes the pre-fetch shape check
    // (the contract asks only for three parts and the header), so it is
    // refused here, after the JWKS, rather than in the no-fetch test.
    ['an empty payload', (await oidc()).replace(/\.[^.]*\./, '..')],
    ['another key', await oidc({}, other.privateKey)],
    ['expired', await oidc({ exp: Math.floor(Date.now() / 1000) - 10 })],
    ['other repository', await oidc({ repository_id: '424243' })],
    ['other branch', await oidc({ ref: 'refs/heads/dev' })],
    ['other workflow', await oidc({ workflow_ref: 'Hcagil/s.is/.github/workflows/release.yml@refs/heads/main' })],
    ['other event', await oidc({ event_name: 'push' })],
    ['other audience', await oidc({ aud: 'sis-admin-applex' })],
  ];
  for (const [name, t] of bad) {
    const r = await call({ action: 'claim', job_id: j.id }, t);
    assertEquals(r.status, 403, `${name}: ${r.text}`);
    assertEquals(r.json, { error: 'not_permitted' }, `${name}: the answer carries no detail`);
  }
  const t = await oidc();
  const raw = await fn(new Request(`${apiUrl}/functions/v1/admin-apple-report`, {
    method: 'POST', headers: { authorization: `Digest ${t}`, 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'claim', job_id: j.id }),
  }));
  assertEquals(raw.status, 403, 'a token that is not sent as Bearer is refused');
  await raw.body?.cancel();
  assertEquals((await row(j.id)).state, 'pending', 'no refused call claimed the job');
} });

Deno.test({ ...opts, name: 'claim: 200 {kind, email}, the job bound to the token\'s run; a second claim -> 409', fn: async () => {
  const j = await job('remove');
  const t = await oidc();
  const r = await call({ action: 'claim', job_id: j.id }, t);
  assertEquals(r.status, 200, r.text);
  assertEquals(r.json, { kind: 'remove', email: j.email });
  const after = await row(j.id);
  assertEquals([after.state, after.run_id], ['running', runOf(t)]);
  const again = await call({ action: 'claim', job_id: j.id }, await oidc());
  assertEquals(again.status, 409, again.text);
  assert(again.text.includes('not_claimable'), again.text);
  const same = await call({ action: 'claim', job_id: j.id }, t);
  assertEquals(same.status, 409, 'not even the same run claims twice');
  assertEquals((await call({ action: 'claim', job_id: crypto.randomUUID() }, await oidc())).status, 409,
    'an unknown job is not claimable');
} });

Deno.test({ ...opts, name: 'progress: attempt 2 or 3 -> 200 {ok:true}; anything else -> 400', fn: async () => {
  const { t, j } = await claimed();
  for (const attempt of [2, 3]) {
    const r = await call({ action: 'progress', job_id: j.id, attempt }, t);
    assertEquals(r.status, 200, r.text);
    assertEquals(r.json, { ok: true });
  }
  for (const attempt of [1, 4, 0, '2', null, 2.5]) {
    const r = await call({ action: 'progress', job_id: j.id, attempt }, t);
    assertEquals(r.status, 400, `attempt ${JSON.stringify(attempt)}: ${r.text}`);
  }
  assertEquals((await call({ action: 'progress', job_id: j.id }, t)).status, 400, 'attempt missing');
} });

Deno.test({ ...opts, name: 'finish ok:true -> 200, the job ok and its email gone', fn: async () => {
  const { t, j } = await claimed();
  const r = await call({ action: 'finish', job_id: j.id, ok: true }, t);
  assertEquals(r.status, 200, r.text);
  assertEquals(r.json, { ok: true });
  const after = await row(j.id);
  assertEquals([after.state, after.email], ['ok', null]);
} });

Deno.test({ ...opts, name: 'finish: ok must be a boolean -> else 400, the job still running', fn: async () => {
  const { t, j } = await claimed();
  for (const ok of ['true', 1, null, 'false']) {
    const r = await call({ action: 'finish', job_id: j.id, ok }, t);
    assertEquals(r.status, 400, `ok ${JSON.stringify(ok)}: ${r.text}`);
  }
  assertEquals((await call({ action: 'finish', job_id: j.id }, t)).status, 400, 'ok missing');
  assertEquals((await row(j.id)).state, 'running');
} });

for (const [reason, want] of [['rejected', 'rejected'], ['dispatch', 'dispatch'], ['timeout', 'timeout'],
  ['Apple said no to x@mail.test', 'timeout'], [undefined, 'timeout'], [42, 'timeout']] as const) {
  Deno.test({ ...opts, name: `finish ok:false reason ${JSON.stringify(reason)} -> the job fails with ${want}`, fn: async () => {
    const { t, j } = await claimed();
    const r = await call({ action: 'finish', job_id: j.id, ok: false, reason }, t);
    assertEquals(r.status, 200, r.text);
    const after = await row(j.id);
    assertEquals([after.state, after.fail_reason, after.email], ['failed', want, null]);
  } });
}

Deno.test({ ...opts, name: 'another run\'s valid token cannot finish the job', fn: async () => {
  const { j } = await claimed();
  await call({ action: 'finish', job_id: j.id, ok: true }, await oidc());
  assertEquals((await row(j.id)).state, 'running', 'the job is bound to its own run');
} });

Deno.test({ ...opts, name: 'an RPC error -> 500 failed, and the log holds the code only', fn: async () => {
  const { t, j } = await claimed();
  await sql`alter function public.admin_job_progress(uuid, bigint, integer) rename to admin_job_progress_qa`;
  const before = logged.length;
  try {
    const r = await call({ action: 'progress', job_id: j.id, attempt: 2 }, t);
    assertEquals(r.status, 500, r.text);
    assertEquals(r.json, { error: 'failed' });
  } finally {
    await sql`alter function public.admin_job_progress_qa(uuid, bigint, integer) rename to admin_job_progress`;
    await sql`notify pgrst, 'reload schema'`;
  }
  const lines = logged.slice(before).join('\n');
  assert(!lines.includes(j.id), `the log names the job: ${lines}`);
  assert(!/message|hint|details|function/i.test(lines), `the log holds more than the code: ${lines}`);
} });

const unknownJob = () => ({ action: 'claim', job_id: crypto.randomUUID() });

Deno.test({ ...opts, name: 'the JWKS is cached for 10 minutes', fn: async () => {
  const before = jwksFetches();
  assert(before >= 1, 'an earlier test fetched it');
  for (let i = 0; i < 3; i++) {
    clockOffset += 2 * 60_000; // up to 6 minutes later: still cached
    assertEquals((await call(unknownJob(), await oidc())).status, 409);
  }
  assertEquals(jwksFetches(), before, 'no fetch while the cache is fresh');
  clockOffset += 5 * 60_000; // past 10 minutes since the last fetch
  assertEquals((await call(unknownJob(), await oidc())).status, 409);
  assertEquals(jwksFetches(), before + 1, 'an expired cache is fetched again');
  assertEquals((await call(unknownJob(), await oidc())).status, 409);
  assertEquals(jwksFetches(), before + 1, 'and cached again');
} });

Deno.test({ ...opts, name: 'an unknown kid refetches, at most once a minute (a rotated key works)', fn: async () => {
  clockOffset += 61_000;
  served = [jwk, jwk2];
  const before = jwksFetches();
  const r = await call(unknownJob(), await oidc({}, other.privateKey, { alg: 'RS256', typ: 'JWT', kid: 'qa-kid-2' }));
  assertEquals(r.status, 409, `a new kid is fetched and verifies: ${r.text}`);
  assertEquals(jwksFetches(), before + 1);
  for (let i = 0; i < 3; i++) {
    const u = await call(unknownJob(), await oidc({}, key.privateKey, { alg: 'RS256', typ: 'JWT', kid: `qa-kid-x${i}` }));
    assertEquals(u.status, 403, u.text);
    assertEquals(u.json, { error: 'not_permitted' });
  }
  assertEquals(jwksFetches(), before + 1, 'no second refetch within the minute');
  clockOffset += 61_000;
  assertEquals((await call(unknownJob(), await oidc({}, key.privateKey, { alg: 'RS256', typ: 'JWT', kid: 'qa-kid-y' }))).status, 403);
  assertEquals(jwksFetches(), before + 2, 'a minute later an unknown kid may refetch once more');
} });

Deno.test({ ...opts, name: 'a failed refetch keeps the old cache', fn: async () => {
  clockOffset += 61_000;
  const before = jwksFetches();
  try {
    for (const mode of ['drop', 'status'] as const) {
      jwksDown = mode;
      const u = await call(unknownJob(), await oidc({}, key.privateKey, { alg: 'RS256', typ: 'JWT', kid: `qa-kid-z-${mode}` }));
      assert(u.status !== 200, u.text);
      clockOffset += 61_000;
    }
    assert(jwksFetches() > before, 'the unknown kid did try a refetch');
    const ok = await call(unknownJob(), await oidc());
    assertEquals(ok.status, 409, `the cached key still verifies while GitHub is down: ${ok.text}`);
    const ok2 = await call(unknownJob(), await oidc({}, other.privateKey, { alg: 'RS256', typ: 'JWT', kid: 'qa-kid-2' }));
    assertEquals(ok2.status, 409, `so does the other cached key: ${ok2.text}`);
  } finally {
    jwksDown = false;
  }
} });

Deno.test({ ...opts, name: 'nothing logged ever holds an email, a token or a body; only JWKS and the job RPCs were fetched', fn: () => {
  const all = logged.join('\n');
  assert(!all.includes('@mail.test'), 'an email was logged');
  for (const t of tokens) assert(!all.includes(t.split('.')[2]), 'a token was logged');
  assert(!all.includes('"action"'), 'a request body was logged');
  for (const u of fetched) {
    assert(u === OIDC_JWKS_URL || /\/rest\/v1\/rpc\/admin_job_(claim|progress|finish)$/.test(u),
      `unexpected outbound call (pushes are never sent from here): ${u}`);
  }
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  await sql`delete from app_private.admin_jobs where id in ${sql(made)}`.catch((e) => console.error('teardown:', e.message));
  await sql.end();
} });
