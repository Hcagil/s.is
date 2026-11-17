// test/edge/apple_revoke_test.ts
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

const log: any[] = [];
let userIdentities: any[] = [
  {
    identity_id: '00000000-0000-0000-0000-0000000000c1',
    id: 'x1',
    user_id: '00000000-0000-0000-0000-0000000000b1',
    provider: 'apple',
    identity_data: {},
    created_at: '2026-01-01T00:00:00Z',
    last_sign_in_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  },
];
let markStatus = 204;
let appleBehaviour = async (rec: any, signal: AbortSignal) => {
  if (rec.url.endsWith('/auth/token')) {
    return Response.json({ refresh_token: 'rt-1' });
  }
  return new Response('{}', { status: 200 });
};

export const setIdentities = (v: any[]) => {
  userIdentities = v;
};
export const setMarkStatus = (n: number) => {
  markStatus = n;
};
export const setApple = (fn: (rec: any, signal: AbortSignal) => Promise<Response>) => {
  appleBehaviour = fn;
};

const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
const lines = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!;
const pem = ['-----BEGIN ' + 'PRIVATE' + ' KEY-----', ...lines, '-----END ' + 'PRIVATE' + ' KEY-----'].join('\n');
const realFetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = async (input, init) => {
  const req = new Request(input, init);
  if (req.url.startsWith('https://appleid.apple.com/')) {
    const rec = {
      kind: 'apple',
      url: req.url,
      method: req.method,
      contentType: req.headers.get('content-type'),
      form: Object.fromEntries(new URLSearchParams(await req.text())),
    };
    log.push(rec);
    return appleBehaviour(rec, req.signal);
  }
  return realFetch(req);
};

const fakeSupabaseHandler = async (req: Request): Promise<Response> => {
  const u = new URL(req.url);
  const method = req.method;
  const path = u.pathname;
  log.push({ kind: 'supabase', method, path });
  if (path === '/auth/v1/user' && method === 'GET') {
    const auth = req.headers.get('Authorization');
    if (auth === 'Bearer good-jwt') {
      return Response.json({
        id: '00000000-0000-0000-0000-0000000000b1',
        aud: 'authenticated',
        role: 'authenticated',
        email: 'ann@mail.test',
        app_metadata: { provider: 'apple', providers: ['apple'] },
        user_metadata: {},
        identities: userIdentities,
        created_at: '2026-01-01T00:00:00Z',
      });
    }
    return Response.json(
      { code: 401, error_code: 'bad_jwt', msg: 'invalid' },
      { status: 401 }
    );
  }
  if (path === '/rest/v1/rpc/mark_apple_revoked' && method === 'POST') {
    const body = await req.json();
    log.push({ kind: 'mark', body });
    if (markStatus === 204) {
      return new Response(null, { status: 204 });
    }
    return Response.json({ message: 'boom' }, { status: markStatus });
  }
  return new Response(null, { status: 404 });
};

const server = realServe(
  { port: 0, hostname: '127.0.0.1', onListen: () => {} },
  fakeSupabaseHandler
);
const baseUrl = `http://127.0.0.1:${server.addr.port}`;

Deno.env.set('SUPABASE_URL', baseUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'fake-service-key');

await import('../../supabase/functions/apple-revoke/index.ts');
const handler = handlers.at(-1)!;

export function reset() {
  log.length = 0;
  userIdentities = [
    {
      identity_id: '00000000-0000-0000-0000-0000000000c1',
      id: 'x1',
      user_id: '00000000-0000-0000-0000-0000000000b1',
      provider: 'apple',
      identity_data: {},
      created_at: '2026-01-01T00:00:00Z',
      last_sign_in_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    },
  ];
  markStatus = 204;
  appleBehaviour = async (rec: any, signal: AbortSignal) => {
    if (rec.url.endsWith('/auth/token')) {
      return Response.json({ refresh_token: 'rt-1' });
    }
    return new Response('{}', { status: 200 });
  };
}

export function env(over: Record<string, string | null> = {}) {
  const defaults = {
    APPLE_TEAM_ID: 'TEAM123456',
    APPLE_KEY_ID: 'KEY1234567',
    APPLE_PRIVATE_KEY: pem,
    APPLE_CLIENT_ID: 'com.example.app',
  };
  for (const [k, v] of Object.entries(defaults)) {
    if (over[k] !== undefined) {
      if (over[k] === null) {
        Deno.env.delete(k);
      } else {
        Deno.env.set(k, over[k]!);
      }
    } else {
      Deno.env.set(k, v);
    }
  }
}

export async function call(opts: { method?: string; body?: string; auth?: string | null } = {}) {
  const headers: Record<string, string> = {};
  const auth = opts.auth === undefined ? 'Bearer good-jwt' : opts.auth;
  if (auth !== null) headers['Authorization'] = auth;
  const body = opts.body ?? JSON.stringify({ authorization_code: 'code-1' });
  const res = await handler(
    new Request(`${baseUrl}/functions/v1/apple-revoke`, {
      method: opts.method ?? 'POST',
      headers,
      body: opts.method === 'GET' ? undefined : body,
    })
  );
  const text = await res.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: res.status, json, text };
}

Deno.test('GET -> 405', async () => {
  reset();
  env();
  const r = await call({ method: 'GET' });
  assertEquals(r.status, 405);
  assertEquals(r.json, { error: 'method' });
  assertEquals(log.length, 0);
});

const kinds = () => log.map((l) => l.kind);

Deno.test('body of 4001 chars -> 400', async () => {
  reset();
  env();
  const r = await call({ body: JSON.stringify({ authorization_code: 'x'.repeat(4001) }) });
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
});

Deno.test('not JSON -> 400', async () => {
  reset();
  env();
  const r = await call({ body: 'not json{' });
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
});

Deno.test('missing code -> 400', async () => {
  reset();
  env();
  const r = await call({ body: '{}' });
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
});

Deno.test('numeric code -> 400', async () => {
  reset();
  env();
  const r = await call({ body: JSON.stringify({ authorization_code: 5 }) });
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
});

Deno.test('empty code -> 400', async () => {
  reset();
  env();
  const r = await call({ body: JSON.stringify({ authorization_code: '' }) });
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
});

for (const name of ['APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_PRIVATE_KEY', 'APPLE_CLIENT_ID']) {
  for (const how of ['unset', 'empty']) {
    Deno.test(`${name} ${how} -> 500 not_configured`, async () => {
      reset();
      env({ [name]: how === 'unset' ? null : '' });
      const r = await call();
      assertEquals(r.status, 500);
      assertEquals(r.json, { error: 'not_configured' });
      assertEquals(log.length, 0);
    });
  }
}

Deno.test('invalid body wins over missing env', async () => {
  reset();
  env({ APPLE_TEAM_ID: null });
  const r = await call({ body: 'not json{' });
  assertEquals(r.status, 400);
});

Deno.test('missing env wins over missing bearer', async () => {
  reset();
  env({ APPLE_TEAM_ID: null });
  const r = await call({ auth: null });
  assertEquals(r.status, 500);
});

Deno.test('no Authorization header -> 401', async () => {
  reset();
  env();
  const r = await call({ auth: null });
  assertEquals(r.status, 401);
  assertEquals(r.json, { error: 'unauthorized' });
  assert(!kinds().includes('apple'));
});

Deno.test('empty bearer -> 401', async () => {
  reset();
  env();
  const r = await call({ auth: 'Bearer ' });
  assertEquals(r.status, 401);
  assertEquals(r.json, { error: 'unauthorized' });
  assert(!kinds().includes('apple'));
});

Deno.test('rejected jwt -> 401', async () => {
  reset();
  env();
  const r = await call({ auth: 'Bearer bad-jwt' });
  assertEquals(r.status, 401);
  assert(!kinds().includes('apple'));
});

Deno.test('user without an apple identity -> 400', async () => {
  reset();
  env();
  setIdentities([
    {
      identity_id: '00000000-0000-0000-0000-0000000000c2',
      id: 'g1',
      user_id: '00000000-0000-0000-0000-0000000000b1',
      provider: 'google',
      identity_data: {},
      created_at: '2026-01-01T00:00:00Z',
      last_sign_in_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    },
  ]);
  const r = await call();
  assertEquals(r.status, 400);
  assertEquals(r.json, { error: 'bad_request' });
  assert(!kinds().includes('apple'));
  assert(!kinds().includes('mark'));
});

Deno.test('bad PEM -> 500 not_configured', async () => {
  reset();
  env({ APPLE_PRIVATE_KEY: 'not a pem' });
  const r = await call();
  assertEquals(r.status, 500);
  assertEquals(r.json, { error: 'not_configured' });
  assert(!kinds().includes('apple'));
});

const apple = () => log.filter((l) => l.kind === 'apple');
const marks = () => log.filter((l) => l.kind === 'mark');

Deno.test('success -> 200 ok, order token, revoke, mark', async () => {
  reset();
  env();
  const r = await call();
  assertEquals(r.status, 200);
  assertEquals(r.json, { ok: true });
  assertEquals(r.text, JSON.stringify({ ok: true }));
  const urls = log.filter(l => l.kind==='apple' || l.kind==='mark').map(l => l.kind==='apple' ? l.url : 'mark');
  assertEquals(urls, ['https://appleid.apple.com/auth/token','https://appleid.apple.com/auth/revoke','mark']);
  const tokenEntry = apple().find(l => l.url.endsWith('/auth/token'))!;
  const revokeEntry = apple().find(l => l.url.endsWith('/auth/revoke'))!;
  assertEquals(tokenEntry.method, 'POST');
  assert(tokenEntry.contentType?.startsWith('application/x-www-form-urlencoded'));
  assertEquals(tokenEntry.form, {
    client_id: 'com.example.app',
    client_secret: tokenEntry.form.client_secret,
    code: 'code-1',
    grant_type: 'authorization_code',
  });
  assertEquals(revokeEntry.method, 'POST');
  assert(revokeEntry.contentType?.startsWith('application/x-www-form-urlencoded'));
  assertEquals(revokeEntry.form, {
    client_id: 'com.example.app',
    client_secret: tokenEntry.form.client_secret,
    token: 'rt-1',
    token_type_hint: 'refresh_token',
  });
  const markEntry = marks()[0];
  assertEquals(markEntry.body, { uid: '00000000-0000-0000-0000-0000000000b1' });
  assert(!r.text.includes('rt-1') && !r.text.includes('code-1'));
});

Deno.test('client_secret is an ES256 jwt signed by the key with the right claims', async () => {
  reset();
  env();
  await call();
  const tokenEntry = apple().find(l => l.url.endsWith('/auth/token'))!;
  const parts = tokenEntry.form.client_secret.split('.');
  assertEquals(parts.length, 3);
  const dec = (s: string) => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), (c) => c.charCodeAt(0))));
  const header = dec(parts[0]);
  const payload = dec(parts[1]);
  assertEquals(header, { alg: 'ES256', kid: 'KEY1234567', typ: 'JWT' });
  assertEquals(payload.iss, 'TEAM123456');
  assertEquals(payload.sub, 'com.example.app');
  assertEquals(payload.aud, 'https://appleid.apple.com');
  assertEquals(payload.exp - payload.iat, 300);
  assert(Math.abs(payload.iat - Date.now()/1000) < 60);
  const sigBytes = Uint8Array.from(atob(parts[2].replace(/-/g,'+').replace(/_/g,'/')), (c) => c.charCodeAt(0));
  assertEquals(sigBytes.length, 64);
  const verified = await crypto.subtle.verify({name:'ECDSA', hash:'SHA-256'}, kp.publicKey, sigBytes, new TextEncoder().encode(parts[0]+'.'+parts[1]));
  assert(verified);
});

const tokenFailures: [string, () => Promise<Response>][] = [
  ['500', () => Promise.resolve(new Response('{}', {status:500}))],
  ['400', () => Promise.resolve(new Response('{"error":"invalid_grant"}', {status:400}))],
  ['no refresh_token', () => Promise.resolve(Response.json({access_token:'a'}))],
  ['500 with a refresh_token in the body', () => Promise.resolve(Response.json({refresh_token: 'rt-1'}, {status: 500}))],
  ['refresh_token not a string', () => Promise.resolve(Response.json({refresh_token: 5}))],
  ['not json', () => Promise.resolve(new Response('plain', {status:200}))],
  ['network error', () => Promise.reject(new TypeError('network'))],
];
for (const [name, fn] of tokenFailures) {
  Deno.test(`token call ${name} -> 502 apple_failed, no revoke, no mark`, async () => {
    reset();
    env();
    setApple((rec, signal) => {
      if (rec.url.endsWith('/auth/token')) return fn();
      return Promise.resolve(new Response('{}', {status:200}));
    });
    const r = await call();
    assertEquals(r.status, 502);
    assertEquals(r.json, { error: 'apple_failed' });
    assertEquals(apple().length, 1);
    assertEquals(marks().length, 0);
  });
}

const revokeFailures: [string, () => Promise<Response>][] = [
  ['500', () => Promise.resolve(new Response('{}', {status:500}))],
  ['403', () => Promise.resolve(new Response('{}', {status:403}))],
  ['network error', () => Promise.reject(new TypeError('network'))],
];
for (const [name, fn] of revokeFailures) {
  Deno.test(`revoke call ${name} -> 502 apple_failed, no mark`, async () => {
    reset();
    env();
    setApple((rec, signal) => {
      if (rec.url.endsWith('/auth/token')) return Promise.resolve(Response.json({refresh_token:'rt-1'}));
      return fn();
    });
    const r = await call();
    assertEquals(r.status, 502);
    assertEquals(r.json, { error: 'apple_failed' });
    assertEquals(apple().length, 2);
    assertEquals(marks().length, 0);
  });
}

Deno.test('mark failure -> 502 apple_failed', async () => {
  reset();
  env();
  setMarkStatus(500);
  const r = await call();
  assertEquals(r.status, 502);
  assertEquals(r.json, { error: 'apple_failed' });
  assertEquals(apple().length, 2);
  assertEquals(marks().length, 1);
});

Deno.test('revoke 204 counts as accepted', async () => {
  reset();
  env();
  setApple((rec, signal) => {
    if (rec.url.endsWith('/auth/token')) return Promise.resolve(Response.json({refresh_token:'rt-1'}));
    return Promise.resolve(new Response(null, {status:204}));
  });
  const r = await call();
  assertEquals(r.status, 200);
  assertEquals(r.json, { ok: true });
  assertEquals(marks().length, 1);
});

Deno.test({name:'token call that hangs is cut at 8 s -> 502, no revoke, no mark', sanitizeOps:false, sanitizeResources:false, fn: async () => {
  reset();
  env();
  setApple((rec, signal) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(new DOMException('aborted','AbortError')));
  }));
  const t0 = Date.now();
  const r = await call();
  const elapsed = Date.now() - t0;
  assert(elapsed >= 7500 && elapsed <= 12000);
  assertEquals(r.status, 502);
  assertEquals(r.json, { error: 'apple_failed' });
  assertEquals(apple().length, 1);
  assertEquals(marks().length, 0);
}});

Deno.test({name:'revoke call that hangs is cut at 8 s -> 502, no mark', sanitizeOps:false, sanitizeResources:false, fn: async () => {
  reset();
  env();
  setApple((rec, signal) => {
    if (rec.url.endsWith('/auth/token')) return Promise.resolve(Response.json({refresh_token:'rt-1'}));
    return new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('aborted','AbortError')));
    });
  });
  const t0 = Date.now();
  const r = await call();
  const elapsed = Date.now() - t0;
  assert(elapsed >= 7500 && elapsed <= 12000);
  assertEquals(r.status, 502);
  assertEquals(r.json, { error: 'apple_failed' });
  assertEquals(apple().length, 2);
  assertEquals(marks().length, 0);
}});
