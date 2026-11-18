// test/edge/account_deletion_test_v4.ts
import { assertEquals, assert } from 'jsr:@std/assert@1';

const handlers: ((req: Request) => Response | Promise<Response>)[] = [];
const realServe = Deno.serve.bind(Deno);
(globalThis as Record<string, unknown>).EdgeRuntime = { waitUntil: () => {} };
Object.defineProperty(Deno, 'serve', {
  configurable: true,
  writable: true,
  value: (h: (req: Request) => Response | Promise<Response>) => {
    handlers.push(h);
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  },
});

const log: { method: string; path: string; body: any; t: number; tEnd?: number }[] = [];
const queueConfig: { user_id: string; request_id: string }[] = [];
const prepareFalseFor: Set<string> = new Set();
const deleteResponses: Map<string, { status: number; body: any }> = new Map();
const getStatus: Map<string, number> = new Map();
let deleteDelayMs = 40;

const fakeHandler = async (req: Request): Promise<Response> => {
  const u = new URL(req.url);
  const raw = await req.text();
  const body = raw ? JSON.parse(raw) : undefined;
  const t = Date.now();
  const record: any = { method: req.method, path: u.pathname, body, t };
  log.push(record);
  if (u.pathname === '/rest/v1/rpc/account_deletion_claim' && req.method === 'POST') {
    const resp = [...queueConfig];
    queueConfig.length = 0;
    return Response.json(resp);
  }
  if (u.pathname === '/rest/v1/rpc/account_deletion_prepare' && req.method === 'POST') {
    const uid = body?.uid; // changed from body?.user_id
    const ok = !prepareFalseFor.has(uid);
    return Response.json(ok);
  }
  // NEW: GET user info before delete
  if (u.pathname.startsWith('/auth/v1/admin/users/') && req.method === 'GET') {
    const uid = u.pathname.split('/').pop()!;
    const gs = getStatus.get(uid);
    if (gs !== undefined) return new Response(JSON.stringify({ msg: 'x' }), { status: gs });
    const resp = {
      id: uid,
      aud: 'authenticated',
      role: 'authenticated',
      email: 'ann@mail.test',
      app_metadata: { provider: 'google', providers: ['google'] },
      user_metadata: {},
      identities: [],
      created_at: '2026-01-01T00:00:00Z',
    };
    return Response.json(resp, { status: 200 });
  }
  if (u.pathname.startsWith('/auth/v1/admin/users/') && req.method === 'DELETE') {
    const uid = u.pathname.split('/').pop()!;
    await new Promise(r => setTimeout(r, deleteDelayMs));
    const resp = deleteResponses.get(uid) ?? { status: 200, body: {} };
    record.tEnd = Date.now();
    return new Response(JSON.stringify(resp.body), { status: resp.status });
  }
  if (u.pathname === '/rest/v1/rpc/account_deletion_done' && req.method === 'POST') {
    return new Response(null, { status: 204 });
  }
  return new Response(null, { status: 404 });
};

const server = realServe({ port: 0, hostname: '127.0.0.1', onListen: () => {} }, fakeHandler);
const baseUrl = `http://127.0.0.1:${server.addr.port}`;

Deno.env.set('SUPABASE_URL', baseUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'fake-service-key');
Deno.env.set('ACCOUNT_DELETION_SECRET', 'qa-del-secret');

await import('../../supabase/functions/account-deletion/index.ts');
const handler = handlers.at(-1)!;

async function call(opts: { method?: string; secret?: string | null } = {}) {
  const headers: Record<string, string> = {};
  const s = opts.secret === undefined ? 'qa-del-secret' : opts.secret;
  if (s !== null) headers['x-deletion-secret'] = s;
  const res = await handler(
    new Request(`${baseUrl}/functions/v1/account-deletion`, {
      method: opts.method ?? 'POST',
      headers,
    })
  );
  return { status: res.status, text: await res.text() };
}

function deleted() {
  return log.filter(l => l.method === 'DELETE').map(l => l.path.split('/').pop());
}
function doneBodies() {
  return log
    .filter(l => l.method === 'POST' && l.path.endsWith('/account_deletion_done'))
    .map(l => l.body);
}

Deno.test('GET -> 405', async () => {
  log.length = 0;
  const r = await call({ method: 'GET' });
  assertEquals(r.status, 405);
  assertEquals(log.length, 0);
});

Deno.test('missing secret header -> 401', async () => {
  log.length = 0;
  const r = await call({ secret: null });
  assertEquals(r.status, 401);
  assertEquals(log.length, 0);
});

Deno.test('wrong secret -> 401', async () => {
  log.length = 0;
  const r = await call({ secret: 'wrong' });
  assertEquals(r.status, 401);
  assertEquals(log.length, 0);
});

Deno.test('wrong secret of the SAME length -> 401, nothing called', async () => {
  log.length = 0;
  const r = await call({ secret: 'qa-del-secreX' });
  assertEquals(r.status, 401);
  assertEquals(log.length, 0);
});

Deno.test('empty-string secret -> 401', async () => {
  log.length = 0;
  const r = await call({ secret: '' });
  assertEquals(r.status, 401);
  assertEquals(log.length, 0);
});

Deno.test('happy path', async () => {
  log.length = 0;
  queueConfig.splice(0, queueConfig.length, { user_id: '00000000-0000-0000-0000-0000000000a1', request_id: 'r1' });
  prepareFalseFor.clear();
  deleteResponses.clear();
  deleteResponses.set('00000000-0000-0000-0000-0000000000a1', { status: 200, body: {} });
  const r = await call();
  assertEquals(r.status, 200);
  assertEquals(deleted(), ['00000000-0000-0000-0000-0000000000a1']);
  const done = doneBodies();
  assertEquals(done.length, 1);
  assert(done[0].rid === 'r1');
  assertEquals(done[0].addr, 'ann@mail.test');
  const claim = log.find(l => l.path.endsWith('/account_deletion_claim'));
  const prepare = log.find(l => l.path.endsWith('/account_deletion_prepare'));
  const get = log.find(l => l.path.endsWith('/auth/v1/admin/users/00000000-0000-0000-0000-0000000000a1') && l.method === 'GET');
  const del = log.find(l => l.path.endsWith('/auth/v1/admin/users/00000000-0000-0000-0000-0000000000a1') && l.method === 'DELETE');
  const doneLog = log.find(l => l.path.endsWith('/account_deletion_done'));
  assert(prepare && get && del && doneLog);
  assert(del.tEnd! >= del.t);
  assert(doneLog.t >= del.tEnd!);
  const idx = (m: string, p: string) => log.findIndex(l => l.method === m && l.path.endsWith(p));
  const u = '/auth/v1/admin/users/00000000-0000-0000-0000-0000000000a1';
  const order = [idx('POST', '/account_deletion_claim'), idx('GET', u), idx('POST', '/account_deletion_prepare'), idx('DELETE', u), idx('POST', '/account_deletion_done')];
  assert(order.every((v, i) => v >= 0 && (i === 0 || order[i - 1] < v)), 'order claim, GET, prepare, DELETE, done');
});

Deno.test('deleteUser fails 500 -> no done', async () => {
  log.length = 0;
  prepareFalseFor.clear();
  deleteResponses.clear();
  queueConfig.splice(0, queueConfig.length, { user_id: '00000000-0000-0000-0000-0000000000a1', request_id: 'r1' });
  deleteResponses.set('00000000-0000-0000-0000-0000000000a1', { status: 500, body: { msg: 'boom' } });
  const r = await call();
  assert(r.status < 600);
  assertEquals(doneBodies().length, 0);
  assertEquals(deleted(), ['00000000-0000-0000-0000-0000000000a1']);
});

Deno.test('two users, one fails, one succeeds', async () => {
  log.length = 0;
  prepareFalseFor.clear();
  deleteResponses.clear();
  queueConfig.splice(0, queueConfig.length, { user_id: '00000000-0000-0000-0000-0000000000a1', request_id: 'r1' }, { user_id: '00000000-0000-0000-0000-0000000000a2', request_id: 'r2' });
  deleteResponses.set('00000000-0000-0000-0000-0000000000a1', { status: 500, body: { msg: 'boom' } });
  deleteResponses.set('00000000-0000-0000-0000-0000000000a2', { status: 200, body: {} });
  const r = await call();
  assert(r.status < 600);
  assertEquals(deleted().sort(), ['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2']);
  const done = doneBodies();
  assertEquals(done.length, 1);
  assert(done[0].rid === 'r2');
});

Deno.test('deleteUser 404 -> done called', async () => {
  log.length = 0;
  prepareFalseFor.clear();
  deleteResponses.clear();
  queueConfig.splice(0, queueConfig.length, { user_id: '00000000-0000-0000-0000-0000000000a1', request_id: 'r1' });
  deleteResponses.set('00000000-0000-0000-0000-0000000000a1', { status: 404, body: { msg: 'User not found', code: 'user_not_found' } });
  const r = await call();
  assert(r.status < 600);
  assertEquals(deleted(), ['00000000-0000-0000-0000-0000000000a1']);
  const done = doneBodies();
  assertEquals(done.length, 1);
  assert(done[0].rid === 'r1');
});

Deno.test('prepare returns false -> no delete or done', async () => {
  log.length = 0;
  deleteResponses.clear();
  queueConfig.splice(0, queueConfig.length, { user_id: '00000000-0000-0000-0000-0000000000a1', request_id: 'r1' });
  prepareFalseFor.add('00000000-0000-0000-0000-0000000000a1');
  const r = await call();
  assert(r.status < 600);
  assertEquals(deleted().length, 0);
  assertEquals(doneBodies().length, 0);
  // assert only one request to prepare
  const prepareLogs = log.filter(l => l.path.endsWith('/account_deletion_prepare'));
  assertEquals(prepareLogs.length, 1);
  // the e-mail is read first (GET) but nothing is deleted
  const userLogs = log.filter(l => l.path.startsWith('/auth/v1/admin/users/'));
  assertEquals(userLogs.map(l => l.method), ['GET']);
});

Deno.test('empty queue -> 200', async () => {
  log.length = 0;
  prepareFalseFor.clear();
  deleteResponses.clear();
  queueConfig.splice(0, queueConfig.length);
  const r = await call();
  assertEquals(r.status, 200);
  assertEquals(deleted().length, 0);
  assertEquals(doneBodies().length, 0);
});

Deno.test('user GET fails 404 or 500 -> not prepared, not deleted, failed 1', async () => {
  const A = '00000000-0000-0000-0000-0000000000a1';
  for (const status of [404, 500]) {
    log.length = 0;
    prepareFalseFor.clear();
    deleteResponses.clear();
    getStatus.clear();
    queueConfig.splice(0, queueConfig.length, { user_id: A, request_id: 'r1' });
    getStatus.set(A, status);
    const orig = console.log;
    const lines: string[] = [];
    console.log = (...a) => { lines.push(a.map(String).join(' ')); };
    let r;
    try { r = await call(); } finally { console.log = orig; getStatus.clear(); }
    assertEquals(r.status, 200, `status for ${status}`);
    assertEquals(JSON.parse(r.text).failed, 1, `failed count for ${status}`);
    assertEquals(log.filter(l => l.path.endsWith('/account_deletion_prepare')).length, 0, `prepare for ${status}`);
    assertEquals(deleted().length, 0, `deleted for ${status}`);
    assertEquals(doneBodies().length, 0, `done for ${status}`);
    assert(!lines.some(l => l.includes(A) || l.includes('ann@mail.test')), `log leaks id or e-mail for ${status}`);
  }
});

Deno.test('failed user read does not stop the next person', async () => {
  const A = '00000000-0000-0000-0000-0000000000a1';
  const B = '00000000-0000-0000-0000-0000000000a2';
  log.length = 0;
  prepareFalseFor.clear();
  deleteResponses.clear();
  getStatus.clear();
  queueConfig.splice(0, queueConfig.length, { user_id: A, request_id: 'r1' }, { user_id: B, request_id: 'r2' });
  getStatus.set(A, 500);
  let r;
  try { r = await call(); } finally { getStatus.clear(); }
  assertEquals(r.status, 200, 'overall status');
  assertEquals(JSON.parse(r.text).failed, 1, 'failed count');
  assertEquals(deleted(), [B], 'deleted only B');
  const done = doneBodies();
  assertEquals(done.length, 1, 'done count');
  assertEquals(done[0].rid, 'r2', 'done rid');
  const prepareUids = log.filter(l => l.path.endsWith('/account_deletion_prepare')).map(l => l.body.uid);
  assertEquals(prepareUids, [B], 'prepare called only for B');
});

Deno.test('shutdown server', async () => {
  await server.shutdown();
});
