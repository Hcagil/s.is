// admin-apple against the real local stack (its RPCs admin_job_dispatch and
// admin_job_dispatch_failed run for real); only GitHub is faked, at fetch.
// The fake answers like the workflow dispatch API can: 204 or 200, a 4xx
// refusal, 429, a 5xx, or a dropped connection.
//
// Contract: POST {job_id} -> 200; 400 bad uuid; 405 not POST; 500
// not_configured (no GITHUB_DISPATCH_TOKEN); 502 dispatch_failed. Only the
// first caller for a job dispatches. 3 tries with waits 0, 5, 20 s, retrying
// network errors, 429 and >= 500; any other 4xx stops; after a total failure
// the job ends with admin_job_dispatch_failed(..., 'dispatch').
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/admin_apple_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const dispatchToken = 'qa-dispatch-' + crypto.randomUUID();
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);
Deno.env.set('GITHUB_DISPATCH_TOKEN', dispatchToken);

// GitHub, faked at fetch: each call takes the next scripted answer.
type Answer = number | 'drop';
const gh: { script: Answer[]; calls: { url: string; method: string; auth: string | null; body: unknown }[] } = {
  script: [],
  calls: [],
};
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
  const req = new Request(input, init);
  if (!req.url.startsWith('https://api.github.com/')) return realFetch(req);
  const text = await req.text();
  gh.calls.push({ url: req.url, method: req.method, auth: req.headers.get('authorization'), body: text ? JSON.parse(text) : null });
  const a = gh.script.shift() ?? 204;
  if (a === 'drop') throw new TypeError('error sending request: connection reset');
  if (a === 200) return new Response(JSON.stringify({ workflow_run_id: 1 }), { status: 200 });
  if (a === 204) return new Response(null, { status: 204 });
  return new Response(JSON.stringify({ message: 'fake' }), { status: a });
};

// The retry waits, recorded and then run at once (a 25 s test proves nothing
// more). Only while the function handles a request: the postgres client's own
// timers must stay real.
const waits: number[] = [];
const realSetTimeout = globalThis.setTimeout;
// deno-lint-ignore no-explicit-any
const fastTimeout = (fn: () => void, ms?: number, ...rest: unknown[]): any => {
  if ((ms ?? 0) >= 1000) waits.push(ms!);
  return realSetTimeout(fn, (ms ?? 0) >= 1000 ? 0 : ms, ...rest);
};

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
await import('../../supabase/functions/admin-apple/index.ts');
const fn = handlers.at(-1)!;

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });
const run = Date.now().toString(36);
const made: string[] = [];
async function job(kind = 'add'): Promise<string> {
  const email = `aa-${run}-${made.length}@mail.test`;
  const [{ id }] = await sql`insert into app_private.admin_jobs(kind, email, email_masked)
    values (${kind}, ${email}, 'a***@m***.test') returning id::text`;
  made.push(id);
  return id;
}
const row = async (id: string) =>
  (await sql`select state, fail_reason, email, dispatched_at is not null as dispatched
               from app_private.admin_jobs where id = ${id}`)[0];

async function call(body: string | null, method = 'POST') {
  // deno-lint-ignore no-explicit-any
  (globalThis as any).setTimeout = fastTimeout;
  try {
    const res = await fn(new Request(`${apiUrl}/functions/v1/admin-apple`, {
      method, headers: { 'content-type': 'application/json' }, body: method === 'POST' ? body : undefined,
    }));
    return { status: res.status, text: await res.text() };
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
}
const post = (jobId: unknown) => call(JSON.stringify({ job_id: jobId }));
function reset(script: Answer[] = []) {
  gh.script = script;
  gh.calls = [];
  waits.length = 0;
}

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({ ...opts, name: 'not POST -> 405, GitHub untouched', fn: async () => {
  reset();
  assertEquals((await call(null, 'GET')).status, 405);
  assertEquals(gh.calls.length, 0);
} });

Deno.test({ ...opts, name: 'a bad body or job_id -> 400, GitHub untouched', fn: async () => {
  reset();
  for (const b of ['not json', JSON.stringify({}), JSON.stringify({ job_id: 'nope' }),
    JSON.stringify({ job_id: '00000000-0000-0000-0000-00000000000g' }), JSON.stringify({ job_id: 42 })]) {
    const r = await call(b);
    assertEquals(r.status, 400, `${b}: ${r.text}`);
  }
  assertEquals(gh.calls.length, 0);
} });

Deno.test({ ...opts, name: 'success: one dispatch of admin-apple.yml on main with only the job id; 204 -> 200', fn: async () => {
  reset([204]);
  const id = await job();
  const r = await post(id);
  assertEquals(r.status, 200, r.text);
  assertEquals(gh.calls.length, 1);
  const c = gh.calls[0];
  assertEquals(c.method, 'POST');
  assertEquals(c.url, 'https://api.github.com/repos/Hcagil/s.is/actions/workflows/admin-apple.yml/dispatches');
  assert(c.auth === `Bearer ${dispatchToken}` || c.auth === `token ${dispatchToken}`, `auth header: ${c.auth}`);
  assertEquals(c.body, { ref: 'main', inputs: { job_id: id } });
  assertEquals((await row(id)).dispatched, true, 'the job is marked dispatched');
  assertEquals((await row(id)).state, 'pending', 'and stays pending for the workflow to claim');
} });

Deno.test({ ...opts, name: 'GitHub answering 200 (with workflow_run_id) is success too', fn: async () => {
  reset([200]);
  const id = await job();
  assertEquals((await post(id)).status, 200);
  assertEquals(gh.calls.length, 1);
  assertEquals((await row(id)).state, 'pending');
} });

Deno.test({ ...opts, name: 'only the first caller dispatches: a second call for the job -> 200, no GitHub call', fn: async () => {
  reset([204]);
  const id = await job();
  assertEquals((await post(id)).status, 200);
  reset([204]);
  const again = await post(id);
  assertEquals(again.status, 200, again.text);
  assertEquals(gh.calls.length, 0, 'no second dispatch');
} });

Deno.test({ ...opts, name: 'an unknown job -> 200, no GitHub call', fn: async () => {
  reset([204]);
  assertEquals((await post(crypto.randomUUID())).status, 200);
  assertEquals(gh.calls.length, 0);
} });

for (const [name, first] of [['500', 500], ['503', 503], ['429', 429], ['a dropped connection', 'drop']] as const) {
  Deno.test({ ...opts, name: `${name} then 204: retried after 5 s -> 200`, fn: async () => {
    reset([first, 204]);
    const id = await job();
    const r = await post(id);
    assertEquals(r.status, 200, r.text);
    assertEquals(gh.calls.length, 2);
    assertEquals(waits, [5000]);
    assertEquals((await row(id)).state, 'pending');
  } });
}

Deno.test({ ...opts, name: 'three failures: tries at 0, 5, 20 s, then 502 dispatch_failed and the job fails with dispatch', fn: async () => {
  reset([500, 'drop', 502]);
  const id = await job();
  const r = await post(id);
  assertEquals(r.status, 502, r.text);
  assert(r.text.includes('dispatch_failed'), r.text);
  assertEquals(gh.calls.length, 3, 'exactly three tries');
  assertEquals(waits, [5000, 20000]);
  const j = await row(id);
  assertEquals([j.state, j.fail_reason, j.email], ['failed', 'dispatch', null]);
} });

for (const status of [401, 403, 404, 422]) {
  Deno.test({ ...opts, name: `${status} is final: one try, 502, the job fails with dispatch`, fn: async () => {
    reset([status, 204, 204]);
    const id = await job();
    const r = await post(id);
    assertEquals(r.status, 502, r.text);
    assertEquals(gh.calls.length, 1, 'no retry on a 4xx other than 429');
    assertEquals(waits, []);
    const j = await row(id);
    assertEquals([j.state, j.fail_reason], ['failed', 'dispatch']);
  } });
}

Deno.test({ ...opts, name: 'no GITHUB_DISPATCH_TOKEN -> 500 not_configured, GitHub untouched', fn: async () => {
  reset([204]);
  Deno.env.delete('GITHUB_DISPATCH_TOKEN');
  try {
    const id = await job();
    const r = await post(id);
    assertEquals(r.status, 500, r.text);
    assert(r.text.includes('not_configured'), r.text);
    assertEquals(gh.calls.length, 0);
  } finally {
    Deno.env.set('GITHUB_DISPATCH_TOKEN', dispatchToken);
  }
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  await sql`delete from app_private.admin_jobs where id in ${sql(made)}`.catch((e) => console.error('teardown:', e.message));
  await sql.end();
} });
