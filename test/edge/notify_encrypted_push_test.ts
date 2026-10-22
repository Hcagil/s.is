// notify-on-message: the ciphertext of an encrypted message in its push
// (Private Chats 4b), against the real local database with FCM stood in for.
//
// Contract (written from the contract, not the function body):
// - An encrypted push's data keeps user_id, message_id, conversation_id,
//   title, body (the placeholder), encrypted:'true', action_token, action_url
//   and badge. It adds `ct` (the row's ciphertext) and `ot` ('0' / '1') only
//   when the recipient's preview is full AND the whole serialized FCM message
//   stays within 3500 UTF-8 bytes; otherwise neither key is there.
// - FCM 400 saying too big / too large / exceed, after a send that carried
//   ct: exactly one resend without ct and ot. 401: one retry with a fresh
//   token. Any other FCM error: no resend.
// - The action token of an encrypted chat signs only ['mark_read']; a plain
//   chat keeps ['mark_read', 'reply'].
// - Neither ct nor the FCM response body is ever logged.
//
// The fake FCM here is this file's own: it answers each send from a queue
// (200 by default) and records the exact body bytes the function sent.
//
// Run (the local stack must be up, `supabase status -o env` gives the key):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all \
//     test/edge/notify_encrypted_push_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { verifyActionToken } from '../../supabase/functions/_shared/action_token.ts';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');

const pair = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
// A throwaway key made per run, passed as its bare base64 PKCS#8 body (the
// function strips PEM armour before decoding, so the armour adds nothing).
const pkcs8 = btoa(String.fromCharCode(...der));
Deno.env.set('FCM_SERVICE_ACCOUNT', JSON.stringify({
  client_email: 'sender@sis-test.iam.gserviceaccount.com',
  private_key: pkcs8,
  project_id: 'sis-test',
}));
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);

// ---- the fake Google ------------------------------------------------------
type Attempt = { auth: string; raw: string; message: Record<string, unknown> };
const attempts: Attempt[] = []; // every FCM send, accepted or refused
type Answer = { status: number; body: unknown };
const answers: Answer[] = []; // next FCM answers, in order; empty = 200
let mints = 0;
let failChatLookup = false;
let chatLookups = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  // The function's read of the chat row (conversations.encrypted_at) made to fail, as a database error would.
  if (failChatLookup && url.includes('/rest/v1/conversations')) {
    chatLookups++;
    return Response.json({ code: 'XX000', message: 'stand-in lookup failure' }, { status: 500 });
  }
  if (url.startsWith('https://oauth2.googleapis.com/')) {
    mints++;
    return Response.json({ access_token: `ya29.enc-fake-${mints}`, token_type: 'Bearer', expires_in: 3600 });
  }
  if (url.startsWith('https://fcm.googleapis.com/')) {
    const auth = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined)).get('authorization') ?? '';
    const raw = String(init?.body ?? await (input as Request).text());
    attempts.push({ auth, raw, message: JSON.parse(raw).message });
    const a = answers.shift();
    if (a) return Response.json(a.body, { status: a.status });
    return Response.json({ name: `projects/sis-test/messages/${attempts.length}` });
  }
  return realFetch(input, init);
};

// ---- the runtime the function is deployed into -----------------------------
let handler: ((req: Request) => Response | Promise<Response>) | undefined;
const pending: Promise<unknown>[] = [];
(globalThis as Record<string, unknown>).EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
Object.defineProperty(Deno, 'serve', {
  configurable: true,
  writable: true,
  value: (h: typeof handler) => {
    handler = h;
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  },
});
await import('../../supabase/functions/notify-on-message/index.ts');

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });

/** Delivers [messageId]; every console line written meanwhile is captured. */
async function deliver(messageId: string) {
  attempts.length = 0;
  pending.length = 0;
  const lines: string[] = [];
  const kinds = ['log', 'info', 'warn', 'error', 'debug', 'trace'] as const;
  const saved = kinds.map((k) => console[k]);
  for (const k of kinds) {
    console[k] = (...args: unknown[]) => {
      lines.push(args.map((a) => {
        if (typeof a === 'string') return a;
        if (a instanceof Error) return `${a.message} ${a.stack}`;
        try { return JSON.stringify(a); } catch { return String(a); }
      }).join(' '));
    };
  }
  try {
    const res = await handler!(new Request('http://localhost/notify-on-message', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'INSERT', table: 'messages', record: { id: messageId } }),
    }));
    const text = await res.text();
    const settled = await Promise.allSettled([...pending]);
    const errors = settled.flatMap((r) => r.status === 'rejected' ? [String(r.reason?.message ?? r.reason)] : []);
    return { status: res.status, text, errors, lines };
  } finally {
    kinds.forEach((k, i) => (console[k] = saved[i]));
  }
}

const b64 = async (alg: string, s: string) =>
  btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest(alg, new TextEncoder().encode(s)))))
    .replace(/=+$/, '');
const bytes = (s: string) => new TextEncoder().encode(s).length;
const PLACEHOLDER = '🔒 Encrypted message';

type Person = { id: string; session: string; email: string; name: string; token: string };
const everyone: Person[] = [];

function as<T>(p: Person, body: (tx: postgres.TransactionSql) => Promise<T>) {
  return sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({
      sub: p.id, role: 'authenticated', email: p.email, session_id: p.session,
    })}, true)`;
    await tx`set local role authenticated`;
    return await body(tx);
  });
}

/** A signed-in, allowlisted person with published keys and one device. */
async function person(tag: string, opts: { platform?: 'android' | 'ios'; preview?: 'full' | 'sender' | 'none' } = {}) {
  const run = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
  const p: Person = {
    id: crypto.randomUUID(),
    session: crypto.randomUUID(),
    email: `enc-${tag}-${run}@mail.test`,
    name: `Enc ${tag}`,
    token: `enc-tok-${crypto.randomUUID()}`, // one length for everyone: the budget tests compare sizes
  };
  everyone.push(p);
  await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
            values (${p.id}, ${p.email}, now(), ${sql.json({ full_name: p.name })})`;
  await sql`insert into app_private.allowlist(email) values (${p.email})`;
  await sql`insert into auth.sessions (id, user_id, created_at, updated_at) values (${p.session}, ${p.id}, now(), now())`;
  await as(p, (tx) => tx`select public.activate_session()`);
  const keys = await Promise.all(['I', 'S', '1', 'F'].map((k) => b64('SHA-256', `${p.email}${k}`)));
  const sig = await b64('SHA-512', p.email);
  await as(p, (tx) => tx`select public.publish_olm_keys(${keys[0]}, ${keys[1]}, ${sig}, ${[keys[2]]}::text[], ${keys[3]})`);
  await as(p, (tx) => tx`select public.register_device_token(${p.token}, ${opts.platform ?? 'android'}, true)`);
  if (opts.preview) await as(p, (tx) => tx`insert into public.notification_settings(preview) values (${opts.preview!})`);
  return p;
}

let sender: Person;
async function chatWith(r: Person) {
  await sql`insert into app_private.tag_finds(finder, found_id) values (${sender.id}, ${r.id})`;
  const [{ id }] = await as(sender, (tx) => tx`select public.start_direct_conversation(${r.id}) as id`);
  return id as string;
}
async function send(conv: string, ciphertext: string | null, olmType = 1, body?: string) {
  const [{ id }] = await as(sender, (tx) => tx`insert into public.messages(conversation_id, sender_id, body, ciphertext, olm_type)
    values (${conv}, ${sender.id}, ${body ?? (ciphertext === null ? 'plain words' : PLACEHOLDER)},
            ${ciphertext}, ${ciphertext === null ? null : olmType}) returning id`);
  return id as string;
}
/** A unique ciphertext of exactly [n] characters (base64 alphabet). */
const cipher = (n: number) => `Q1R${crypto.randomUUID().replaceAll('-', '')}`.padEnd(n, 'A').slice(0, n);
const data = (a: Attempt) => a.message.data as Record<string, string>;
const test = (name: string, fn: () => Promise<void>) =>
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });

test('setup: the sender', async () => {
  sender = await person('sender');
});

test('preview full (unset): data keeps every key and adds ct = the row ciphertext and ot', async () => {
  const bob = await person('bob');
  const conv = await chatWith(bob);
  for (const ot of [1, 0]) {
    const ct = cipher(120);
    const id = await send(conv, ct, ot);
    const r = await deliver(id);
    assertEquals(r.status, 204, JSON.stringify(r));
    assertEquals(attempts.length, 1, `one send: ${attempts.length}`);
    const d = data(attempts[0]);
    assertEquals(attempts[0].message.token, bob.token);
    assertEquals(Object.keys(d).sort(),
      ['action_token', 'action_url', 'badge', 'body', 'conversation_id', 'ct', 'encrypted', 'message_id', 'ot', 'title', 'user_id'],
      `the key set: ${attempts[0].raw}`);
    assertEquals([d.user_id, d.message_id, d.conversation_id, d.encrypted, d.body, d.title],
      [bob.id, id, conv, 'true', PLACEHOLDER, sender.name]);
    assertEquals(d.action_url, `${apiUrl}/functions/v1/notification-action`);
    assert(/^\d+$/.test(d.badge), `badge is a count: ${d.badge}`);
    assertEquals(d.ct, ct, 'ct is the row ciphertext, unchanged');
    assertEquals(d.ot, String(ot), `ot is '${ot}', a string`);
    assert(bytes(attempts[0].raw) <= 3500 + 20, 'fixture: a small push');
  }
});

test('preview full set explicitly: ct and ot are there', async () => {
  const cat = await person('cat', { preview: 'full' });
  const ct = cipher(64);
  const r = await deliver(await send(await chatWith(cat), ct, 1));
  assertEquals(r.status, 204);
  assertEquals(attempts.length, 1);
  assertEquals([data(attempts[0]).ct, data(attempts[0]).ot], [ct, '1']);
});

for (const preview of ['sender', 'none'] as const) {
  test(`preview ${preview}: an encrypted push carries neither ct nor ot, and never the ciphertext`, async () => {
    const p = await person(`p${preview}`, { preview });
    const ct = cipher(80);
    const r = await deliver(await send(await chatWith(p), ct, 1));
    assertEquals(r.status, 204);
    assertEquals(attempts.length, 1, `one send: ${attempts.length}`);
    const d = data(attempts[0]);
    assertEquals(d.encrypted, 'true', 'fixture: an encrypted push');
    assert(!('ct' in d) && !('ot' in d), `no ct/ot: ${attempts[0].raw}`);
    assert(!attempts[0].raw.includes(ct), `the ciphertext is nowhere in the push: ${attempts[0].raw}`);
  });
}

// Group J: the scope is decided per CHAT (conversations.encrypted_at), not per
// message: every push of a chat that ever held a locked message signs
// mark_read only, also for a row with no ciphertext in it. A plain chat keeps
// Reply. A failed read of the chat row counts as encrypted.
const scopeOf = async (a: Attempt) => {
  const claims = await verifyActionToken(data(a).action_token, serviceKey);
  assert(claims, `the token verifies: ${a.raw}`);
  return claims;
};

test('action token: a plain chat signs mark_read and reply; an encrypted chat mark_read only', async () => {
  const eve = await person('eve');
  await deliver(await send(await chatWith(eve), null));
  assertEquals(attempts.length, 1);
  assertEquals((await scopeOf(attempts[0])).a, ['mark_read', 'reply'], 'plain chat');
  assert(!('ct' in data(attempts[0])) && !('encrypted' in data(attempts[0])), 'plain: no ct, no encrypted');

  const fay = await person('fay');
  await deliver(await send(await chatWith(fay), cipher(40), 0));
  assertEquals(attempts.length, 1);
  const enc = await scopeOf(attempts[0]);
  assertEquals(enc.a, ['mark_read'], 'encrypted chat: mark_read only');
  assertEquals([enc.u, enc.c], [fay.id, data(attempts[0]).conversation_id]);
});

test('action token: a row without ciphertext in an encrypted chat still signs mark_read only', async () => {
  const gus = await person('gus');
  const conv = await chatWith(gus);
  await deliver(await send(conv, cipher(40), 0));
  const [{ at }] = await sql`select encrypted_at as at from public.conversations where id = ${conv}`;
  assert(at !== null, 'fixture: the chat is marked encrypted');

  // Plain rows written by the server (service role, no member session, so the
  // member guard does not apply): a text and a place, neither with ciphertext.
  const server = (body: (tx: postgres.TransactionSql) => Promise<{ id: string }[]>) =>
    sql.begin(async (tx) => {
      await tx`set local role service_role`;
      return await body(tx);
    });
  const [{ id: text }] = await server((tx) => tx`insert into public.messages(conversation_id, sender_id, body)
    values (${conv}, ${sender.id}, 'plain words') returning id`);
  const [{ id: place }] = await server((tx) => tx`insert into public.messages(conversation_id, sender_id, body, location_lat, location_lng)
    values (${conv}, ${sender.id}, 'Cafe', 41.0, 29.0) returning id`);
  for (const [what, id] of [['a place', place], ['a plain text', text]] as const) {
    await deliver(id);
    assertEquals(attempts.length, 1, what);
    assert(!('ct' in data(attempts[0])) && data(attempts[0]).encrypted !== 'true', `${what}: fixture is a plain row`);
    assertEquals((await scopeOf(attempts[0])).a, ['mark_read'], `${what} in an encrypted chat`);
  }
});

test('action token: the chat row cannot be read -> mark_read only (fails closed)', async () => {
  const hal = await person('hal');
  const conv = await chatWith(hal);
  failChatLookup = true;
  chatLookups = 0;
  try {
    await deliver(await send(conv, null));
  } finally {
    failChatLookup = false;
  }
  assert(chatLookups > 0, 'fixture: the chat row was asked for and failed');
  assertEquals(attempts.length, 1, 'the push still goes out');
  assertEquals((await scopeOf(attempts[0])).a, ['mark_read'], 'lookup error');
  // Control: the same plain chat with the lookup working keeps Reply.
  await deliver(await send(conv, null));
  assertEquals((await scopeOf(attempts[0])).a, ['mark_read', 'reply'], 'lookup working');
});

test('iPhone, preview full: ct and ot travel and the apns block is the locked one', async () => {
  const ivy = await person('ivy', { platform: 'ios' });
  const conv = await chatWith(ivy);
  const ct = cipher(50);
  await deliver(await send(conv, ct, 1));
  assertEquals(attempts.length, 1);
  const m = attempts[0].message;
  assertEquals([data(attempts[0]).ct, data(attempts[0]).ot], [ct, '1']);
  const aps = (m.apns as { payload: { aps: Record<string, unknown> } }).payload.aps;
  assertEquals(aps.category, 'SIS_MESSAGE_LOCKED');
  assertEquals(aps['thread-id'], conv);
  assertEquals(aps['mutable-content'], 1, 'ct sent: the iPhone extension may decrypt before showing');
  assertEquals(aps.sound, 'default');
  assertEquals(String(aps.badge), data(attempts[0]).badge);
  const alert = JSON.stringify(m.notification ?? aps.alert ?? '');
  assert(!alert.includes(ct), 'the ciphertext is not in the visible alert');
});

const apsOf = (a: Attempt) => (a.message.apns as { payload: { aps: Record<string, unknown> } }).payload.aps;

test('iPhone, preview sender: no ct, still mutable-content (the extension draws the locked text)', async () => {
  const p = await person('ivys', { platform: 'ios', preview: 'sender' });
  await deliver(await send(await chatWith(p), cipher(50), 1));
  assertEquals(attempts.length, 1);
  assertEquals(data(attempts[0]).encrypted, 'true', 'fixture: an encrypted push');
  assert(!('ct' in data(attempts[0])), 'fixture: no ct');
  assertEquals(apsOf(attempts[0])['mutable-content'], 1, `mutable-content: ${attempts[0].raw}`);
  assertEquals(apsOf(attempts[0]).category, 'SIS_MESSAGE_LOCKED');
});

test('iPhone, preview none: no ct, still mutable-content and the locked category', async () => {
  const p = await person('ivyn', { platform: 'ios', preview: 'none' });
  await deliver(await send(await chatWith(p), cipher(50), 1));
  assertEquals(attempts.length, 1);
  assert(!('ct' in data(attempts[0])), 'fixture: no ct');
  assertEquals(apsOf(attempts[0])['mutable-content'], 1, `mutable-content: ${attempts[0].raw}`);
  assertEquals(apsOf(attempts[0]).category, 'SIS_MESSAGE_LOCKED');
});

// The budget. ct and ot add exactly `,"ct":"<n>"` + `,"ot":"1"` = n + 17
// bytes; on an iPhone `"mutable-content":1,` stays on every encrypted push
// (Group I), with or without ct, so it is part of the rest. One calibration send gives the size of the rest; each probe is a
// fresh recipient, so the badge (1) and every id keep their lengths. "The
// message" is read as the whole request body FCM receives,
// {"message":{...}} in compact JSON, UTF-8 (the `message` object alone is 12
// bytes less). The probes measured this reading exactly: body 3500 keeps ct.
async function calibrate(platform: 'android' | 'ios' = 'android') {
  const cal = await person('cal', { platform });
  await deliver(await send(await chatWith(cal), cipher(100), 1));
  assertEquals(attempts.length, 1);
  assertEquals(bytes(attempts[0].raw), bytes(`{"message":${JSON.stringify(attempts[0].message)}}`), 'fixture: compact JSON body');
  return bytes(attempts[0].raw) - 100; // request body bytes with a 0-char ct
}
/** Sends a ct of [n] chars to a fresh recipient; the sent attempt. */
async function probe(n: number, platform: 'android' | 'ios' = 'android') {
  const p = await person('probe', { platform });
  const ct = cipher(n);
  await deliver(await send(await chatWith(p), ct, 1));
  assertEquals(attempts.length, 1);
  return { a: attempts[0], ct };
}
/** The longest ct the function still sends, by bisection over fresh recipients. */
async function longestKept(platform: 'android' | 'ios' = 'android') {
  const base = await calibrate(platform);
  let lo = 3500 - base - 300, hi = 3500 - base + 300;
  assert('ct' in data((await probe(lo, platform)).a), 'fixture: 300 bytes under budget keeps ct');
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if ('ct' in data((await probe(mid, platform)).a)) lo = mid; else hi = mid - 1;
  }
  return { base, kept: lo };
}

for (const platform of ['android', 'ios'] as const) {
  const withCt = 17; // bytes ct (beyond its chars) and ot add; mutable-content stays either way
  test(`budget (${platform}): a request of exactly 3500 bytes keeps ct and ot`, async () => {
    const base = await calibrate(platform);
    const { a, ct } = await probe(3500 - base, platform);
    const size = 'ct' in data(a) ? bytes(a.raw) : bytes(a.raw) + ct.length + withCt;
    assertEquals(size, 3500, 'fixture: the request with ct is exactly 3500 bytes');
    assertEquals([data(a).ct, data(a).ot], [ct, '1'], `at 3500 bytes ct and ot stay; sent ${bytes(a.raw)} bytes`);
  });

  test(`budget (${platform}): a request of 3501 bytes drops both ct and ot, and is still sent`, async () => {
    const base = await calibrate(platform);
    const { a, ct } = await probe(3501 - base, platform);
    const d = data(a);
    assert(!('ct' in d) && !('ot' in d), `at 3501 bytes neither ct nor ot: ${Object.keys(d)}`);
    assert(!a.raw.includes(ct), 'the ciphertext is nowhere in the push');
    assertEquals(d.encrypted, 'true');
    if (platform === 'ios') assertEquals(apsOf(a)['mutable-content'], 1, `ct dropped, mutable-content stays: ${a.raw}`);
    assertEquals(bytes(a.raw) + ct.length + withCt, 3501, 'fixture: with ct it would be 3501');
  });
}

test('budget: no push that carries ct is over 3500 bytes, even with a ct far over budget', async () => {
  const { a, ct } = await probe(5000);
  assert(!('ct' in data(a)) && !a.raw.includes(ct), 'a 5000-char ct is dropped');
  const { kept, base } = await longestKept();
  console.log(`[measure] android 1:1 request without ct and ot: ${base - 17} bytes; longest ct kept: ${kept} chars ` +
    `(request ${base + kept} bytes)`);
  assert(base + kept <= 3500, `the longest kept ct makes a ${base + kept}-byte request`);
});

test('budget counts UTF-8 bytes: a sender name with Turkish letters lowers the limit by its extra bytes', async () => {
  const nameOf = (n: string) => sql`update public.profiles set display_name = ${n} where user_id = ${sender.id}`;
  const ascii = 'Sule Ozgur Isik Cag';
  const turkish = 'Şule Özgür Işık Çağ'; // same length, 7 more UTF-8 bytes
  const extra = bytes(turkish) - bytes(ascii);
  assertEquals([ascii.length, extra], [turkish.length, 7]);
  const [{ old }] = await sql`select display_name as old from public.profiles where user_id = ${sender.id}`;
  try {
    await nameOf(ascii);
    assertEquals(data((await probe(10)).a).title, ascii, 'fixture: the 1:1 title is the sender name');
    const a = await longestKept();
    await nameOf(turkish);
    assertEquals(data((await probe(10)).a).title, turkish);
    const t = await longestKept();
    assertEquals(t.base - a.base, extra, 'fixture: the title moved the message by its UTF-8 bytes');
    assertEquals(a.kept - t.kept, extra, `the limit moved by bytes, not characters: ${a.kept} vs ${t.kept}`);
  } finally {
    await nameOf(old);
  }
});

// FCM's oversize refusal. The wording is Google's; the contract matches it by
// too big / too large / exceed.
const tooBig = (msg: string) => ({
  status: 400,
  body: { error: { code: 400, message: `${msg} FCMBODYMARK`, status: 'INVALID_ARGUMENT' } },
});
for (const wording of ['Message is too big', 'Request payload too large', 'Android message exceeds the 4096-byte limit']) {
  test(`400 "${wording}" after a send with ct: exactly one resend, without ct and ot, otherwise the same`, async () => {
    const p = await person('big');
    const ct = cipher(200);
    answers.push(tooBig(wording));
    const r = await deliver(await send(await chatWith(p), ct, 1));
    answers.length = 0;
    assertEquals(r.status, 204);
    assertEquals(attempts.length, 2, `the refused send and one resend: ${attempts.length}`);
    assertEquals(data(attempts[0]).ct, ct, 'fixture: the first send carried ct');
    const second = structuredClone(attempts[1].message);
    const first = structuredClone(attempts[0].message);
    const d1 = first.data as Record<string, string>;
    delete d1.ct;
    delete d1.ot;
    assert(!('ct' in data(attempts[1])) && !('ot' in data(attempts[1])), 'the resend has neither ct nor ot');
    assertEquals(second, first, 'the resend is the same push, less ct and ot');
    const logs = r.lines.join('\n');
    assert(!logs.includes(ct), `ct was logged: ${logs}`);
    assert(!logs.includes('FCMBODYMARK'), `the FCM response body was logged: ${logs}`);
  });
}

test('400 too big twice: no third send, the push is not counted as sent, and nothing secret is logged', async () => {
  const p = await person('big2');
  const ct = cipher(200);
  answers.push(tooBig('Message is too big'), tooBig('Message is too big'));
  const r = await deliver(await send(await chatWith(p), ct, 1));
  answers.length = 0;
  assertEquals(attempts.length, 2, `two sends, no more: ${attempts.length}`);
  const everything = [r.text, ...r.errors, ...r.lines].join('\n');
  assert(/sent 0 of 1/.test(everything) || r.errors.length > 0, `the failure was not reported: ${everything}`);
  assert(!everything.includes(ct) && !everything.includes('FCMBODYMARK'), `secret in logs: ${everything}`);
});

test('iPhone 400 too big: the resend without ct keeps mutable-content and the locked category', async () => {
  const p = await person('bigios', { platform: 'ios' });
  answers.push(tooBig('Message is too big'));
  await deliver(await send(await chatWith(p), cipher(200), 1));
  answers.length = 0;
  assertEquals(attempts.length, 2, `the refused send and one resend: ${attempts.length}`);
  assert('ct' in data(attempts[0]) && !('ct' in data(attempts[1])), 'fixture: the resend dropped ct');
  assertEquals(apsOf(attempts[1])['mutable-content'], 1, `resend: mutable-content: ${attempts[1].raw}`);
  assertEquals(apsOf(attempts[1]).category, 'SIS_MESSAGE_LOCKED');
});

test('400 too big on a push without ct (preview sender): no resend', async () => {
  const p = await person('bigsender', { preview: 'sender' });
  answers.push(tooBig('Message is too big'));
  const r = await deliver(await send(await chatWith(p), cipher(60), 1));
  answers.length = 0;
  assertEquals(attempts.length, 1, `one send only: ${attempts.length}`);
  assert(!r.lines.join('\n').includes('FCMBODYMARK'), 'the FCM response body was logged');
});

for (const other of [
  { status: 400, body: { error: { code: 400, message: 'The registration token is not a valid FCM registration token FCMBODYMARK', status: 'INVALID_ARGUMENT' } } },
  { status: 500, body: { error: { code: 500, message: 'Internal error FCMBODYMARK', status: 'INTERNAL' } } },
  { status: 404, body: { error: { code: 404, message: 'Requested entity was not found. FCMBODYMARK', status: 'NOT_FOUND' } } },
]) {
  test(`FCM ${other.status} (not oversize) with ct: no resend, reported as failed, ct and body not logged`, async () => {
    const p = await person(`err${other.status}`);
    const ct = cipher(90);
    answers.push(other);
    const r = await deliver(await send(await chatWith(p), ct, 1));
    answers.length = 0;
    assertEquals(attempts.length, 1, `no resend: ${attempts.length}`);
    const everything = [r.text, ...r.errors, ...r.lines].join('\n');
    assert(/sent 0 of 1/.test(everything) || r.errors.length > 0, `the failure was not reported: ${everything}`);
    assert(!everything.includes(ct), `ct was logged: ${everything}`);
    assert(!everything.includes('FCMBODYMARK'), `the FCM response body was logged: ${everything}`);
  });
}

test('401 with ct: one retry with a fresh token, ct still there, no ct in the logs', async () => {
  const p = await person('auth');
  const ct = cipher(70);
  answers.push({ status: 401, body: { error: { code: 401, status: 'UNAUTHENTICATED', message: 'FCMBODYMARK' } } });
  const before = mints;
  const r = await deliver(await send(await chatWith(p), ct, 0));
  answers.length = 0;
  assertEquals(attempts.length, 2, `refused send and one retry: ${attempts.length}`);
  assertEquals(mints, before + 1, 'one fresh token');
  assert(attempts[1].auth !== attempts[0].auth, 'the retry carries the new token');
  assertEquals([data(attempts[1]).ct, data(attempts[1]).ot], [ct, '0'], 'the retry keeps ct and ot');
  const logs = r.lines.join('\n');
  assert(!logs.includes(ct) && !logs.includes('FCMBODYMARK'), `secret in logs: ${logs}`);
});

test('a successful push with ct logs no ct', async () => {
  const p = await person('quiet');
  const ct = cipher(150);
  const r = await deliver(await send(await chatWith(p), ct, 1));
  assertEquals(data(attempts[0]).ct, ct, 'fixture: ct travelled');
  assert(!r.lines.join('\n').includes(ct), `ct was logged: ${r.lines}`);
});

test('cleanup and close the database connection', async () => {
  const ids = everyone.map((p) => p.id);
  if (ids.length) {
    await sql.begin(async (tx) => {
      await tx`delete from app_private.tag_finds where finder in ${sql(ids)} or found_id in ${sql(ids)}`;
      await tx`delete from app_private.device_tokens where user_id in ${sql(ids)}`;
      await tx`delete from app_private.allowlist where email in ${sql(everyone.map((p) => p.email))}`;
    }).catch(() => {});
  }
  await sql.end();
});
