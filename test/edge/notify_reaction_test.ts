// notify-on-message: the reaction branch, against the real local database
// (public.reaction_push_targets claims and decides who and what) with FCM
// stood in for.
//
// Contract (written from the contract, not the function body):
// - A body {"reaction":{"message_id","user_id"}} with both UUIDs sends the
//   reaction push; anything else is not a reaction. The answer is always 204
//   with an empty body (valid, invalid, unknown ids alike).
// - Data (all strings): user_id, conversation_id, message_id, kind
//   'reaction', reactor_id, title, body, sender/chat (group only), e, q, qk
//   (only when set), encrypted 'true' (when set), ct + ot (only when set and
//   within the size budget). No badge, no action token.
// - Android: data only, android {priority 'high', collapse_key}. iOS:
//   notification {title, body} (a group is titled by the group, the line
//   "Sender: body", as message pushes), apns thread-id = conversation_id,
//   sound default, mutable-content 1, header apns-collapse-id. The collapse
//   id is the first 32 hex of sha256(message_id + ':' + reactor_id).
// - FCM 401: one retry with a fresh token. A claimed push that FCM refused is
//   not sent again. Logs: 'reaction sent N of M' and error codes only; never
//   an emoji, quote, ct or uuid.
//
// The fake FCM is this file's own: it answers each send from a queue (200 by
// default) and records the exact body the function sent.
//
// Run (the local stack must be up, `supabase status -o env` gives the key):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all \
//     test/edge/notify_reaction_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

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
Deno.env.set('FCM_SERVICE_ACCOUNT', JSON.stringify({
  client_email: 'sender@sis-test.iam.gserviceaccount.com',
  private_key: btoa(String.fromCharCode(...der)), // a throwaway key made per run
  project_id: 'sis-test',
}));
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);

// ---- the fake Google ------------------------------------------------------
type Attempt = { auth: string; raw: string; message: Record<string, unknown> };
const attempts: Attempt[] = [];
const answers: { status: number; body: unknown }[] = []; // next FCM answers, in order; empty = 200
let mints = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith('https://oauth2.googleapis.com/')) {
    mints++;
    return Response.json({ access_token: `ya29.rx-fake-${mints}`, token_type: 'Bearer', expires_in: 3600 });
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

/** Posts [body] (a string as is, anything else as JSON); every console line written meanwhile is captured. */
async function post(body: unknown) {
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
      body: typeof body === 'string' ? body : JSON.stringify(body),
    }));
    const text = await res.text();
    await Promise.allSettled([...pending]);
    return { status: res.status, text, lines };
  } finally {
    kinds.forEach((k, i) => (console[k] = saved[i]));
  }
}
const react = (messageId: string, reactor: Person) => post({ reaction: { message_id: messageId, user_id: reactor.id } });

const UUID_ANY = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
/** The logs name no id and none of [secrets]. */
function cleanLogs(lines: string[], secrets: string[]) {
  for (const l of lines) {
    assert(!UUID_ANY.test(l), `a log line carries an id: ${l}`);
    for (const s of secrets) assert(!l.includes(s), `a log line carries "${s}": ${l}`);
  }
}
const b64 = async (alg: string, s: string) =>
  btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest(alg, new TextEncoder().encode(s)))))
    .replace(/=+$/, '');
const collapse = async (m: string, u: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${m}:${u}`))))
    .map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
const GENERIC = 'New reaction to your message';

type Person = { id: string; session: string; email: string; name: string; token: string };
const run = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;

function as<T>(p: Person, body: (tx: postgres.TransactionSql) => Promise<T>) {
  return sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({
      sub: p.id, role: 'authenticated', email: p.email, session_id: p.session,
    })}, true)`;
    await tx`set local role authenticated`;
    return await body(tx);
  });
}

/** A signed-in, allowlisted, keyed person whose one device draws reactions. */
async function person(tag: string, opts: { platform?: 'android' | 'ios'; preview?: 'full' | 'sender' | 'none' } = {}) {
  const p: Person = {
    id: crypto.randomUUID(),
    session: crypto.randomUUID(),
    email: `rx-${tag}-${run}@mail.test`,
    name: `Rx ${tag}`,
    token: `rx-tok-${crypto.randomUUID()}`,
  };
  await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
            values (${p.id}, ${p.email}, now(), ${sql.json({ full_name: p.name })})`;
  await sql`insert into app_private.allowlist(email) values (${p.email})`;
  await sql`insert into auth.sessions (id, user_id, created_at, updated_at) values (${p.session}, ${p.id}, now(), now())`;
  await as(p, (tx) => tx`select public.activate_session()`);
  const keys = await Promise.all(['I', 'S', '1', 'F'].map((k) => b64('SHA-256', `${p.email}${k}`)));
  const sig = await b64('SHA-512', p.email);
  await as(p, (tx) => tx`select public.publish_olm_keys(${keys[0]}, ${keys[1]}, ${sig}, ${[keys[2]]}::text[], ${keys[3]})`);
  await as(p, (tx) => tx`select public.register_device_token(${p.token}, ${opts.platform ?? 'android'}, true, true)`);
  if (opts.preview) await as(p, (tx) => tx`insert into public.notification_settings(preview) values (${opts.preview!})`);
  return p;
}
async function direct(a: Person, b: Person) {
  await sql`insert into app_private.tag_finds(finder, found_id) values (${a.id}, ${b.id})`;
  const [{ id }] = await as(a, (tx) => tx`select public.start_direct_conversation(${b.id}) as id`);
  return id as string;
}
async function group(a: Person, title: string, members: Person[]) {
  for (const m of members) await sql`insert into app_private.tag_finds(finder, found_id) values (${a.id}, ${m.id})`;
  const [{ id }] = await as(a, (tx) => tx`select public.start_group_conversation(${title}, ${members.map((m) => m.id)}::uuid[]) as id`);
  return id as string;
}
async function say(from: Person, conv: string, body: string) {
  const [{ id }] = await as(from, (tx) => tx`insert into public.messages(conversation_id, sender_id, body)
    values (${conv}, ${from.id}, ${body}) returning id`);
  return id as string;
}
const setReaction = (p: Person, m: string, emoji: string | null) =>
  as(p, (tx) => tx`select public.set_reaction(${m}, ${emoji})`);
const data = (a: Attempt) => a.message.data as Record<string, string>;
const test = (name: string, fn: () => Promise<void>) =>
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });

let ben: Person;
test('setup: the reactor', async () => {
  ben = await person('ben');
});

test('group, Android, preview full: data only, the exact data block, collapse key; claimed once; a new emoji sends again', async () => {
  const ava = await person('ava');
  const cyd = await person('cyd');
  const title = `rx-group-${run}`;
  const conv = await group(ava, title, [ben, cyd]);
  const text = 'hello reaction world';
  const m = await say(ava, conv, text);
  await setReaction(ben, m, '👍');

  const r = await react(m, ben);
  assertEquals([r.status, r.text], [204, ''], 'empty 204');
  assertEquals(attempts.length, 1, `one send: ${JSON.stringify(attempts.map((a) => a.raw))}`);
  const key = await collapse(m, ben.id);
  assertEquals(attempts[0].message, {
    token: ava.token,
    data: {
      user_id: ava.id, conversation_id: conv, message_id: m, kind: 'reaction', reactor_id: ben.id,
      title: `${ben.name} @ ${title}`, body: GENERIC, sender: ben.name, chat: title, e: '👍', q: text,
    },
    android: { priority: 'high', collapse_key: key },
  }, `the whole message: ${attempts[0].raw}`);
  assert(r.lines.some((l) => l.includes('reaction sent 1 of 1')), `the count is logged: ${JSON.stringify(r.lines)}`);
  cleanLogs(r.lines, ['👍', text, ben.name, ava.token]);

  const again = await react(m, ben);
  assertEquals([again.status, again.text, attempts.length], [204, '', 0], 'the same change asked again: nothing sent');

  await setReaction(ben, m, '🎉');
  const changed = await react(m, ben);
  assertEquals(attempts.length, 1, 'a new emoji is news again');
  assertEquals([data(attempts[0]).e, (attempts[0].message.android as Record<string, string>).collapse_key], ['🎉', key],
    'the new emoji, under the same collapse key (it replaces the old line)');
  cleanLogs(changed.lines, ['🎉', text]);
});

test('iPhone, 1:1, preview full: notification, apns thread-id, sound, mutable-content, collapse id; no sender/chat, no badge', async () => {
  const ivy = await person('ivy', { platform: 'ios' });
  const conv = await direct(ivy, ben);
  const m = await say(ivy, conv, 'a photo of the sea');
  await setReaction(ben, m, '❤️');
  const r = await react(m, ben);
  assertEquals([r.status, r.text], [204, '']);
  assertEquals(attempts.length, 1, `one send: ${r.lines}`);
  const msg = attempts[0].message;
  assertEquals(msg.token, ivy.token);
  assertEquals(msg.notification, { title: ben.name, body: GENERIC }, 'the 1:1 alert: the reactor and the generic line');
  assertEquals(data(attempts[0]), {
    user_id: ivy.id, conversation_id: conv, message_id: m, kind: 'reaction', reactor_id: ben.id,
    title: ben.name, body: GENERIC, e: '❤️', q: 'a photo of the sea',
  }, `1:1 data has no sender/chat: ${attempts[0].raw}`);
  const apns = msg.apns as { headers: Record<string, string>; payload: { aps: Record<string, unknown> } };
  assertEquals(apns.headers['apns-collapse-id'], await collapse(m, ben.id));
  assertEquals(apns.payload.aps['thread-id'], conv);
  assertEquals(apns.payload.aps.sound, 'default');
  assertEquals(apns.payload.aps['mutable-content'], 1);
  assert(!('badge' in apns.payload.aps) && !('category' in apns.payload.aps), `no badge, no category: ${attempts[0].raw}`);
  cleanLogs(r.lines, ['❤️', 'the sea']);
});

test('iPhone, group: titled by the group, the line names the reactor', async () => {
  const iza = await person('iza', { platform: 'ios' });
  const title = `rx-igroup-${run}`;
  const conv = await group(iza, title, [ben]);
  const m = await say(iza, conv, 'group words');
  await setReaction(ben, m, '👍');
  await react(m, ben);
  assertEquals(attempts.length, 1);
  assertEquals(attempts[0].message.notification, { title, body: `${ben.name}: ${GENERIC}` }, 'as a group message alert');
  assertEquals([data(attempts[0]).sender, data(attempts[0]).chat], [ben.name, title]);
});

test('preview none: SIS, generic, no sender, chat, emoji or quote', async () => {
  const nia = await person('nia', { preview: 'none' });
  const conv = await group(nia, `rx-none-${run}`, [ben]);
  const m = await say(nia, conv, 'hidden words');
  await setReaction(ben, m, '👍');
  await react(m, ben);
  assertEquals(attempts.length, 1);
  assertEquals(data(attempts[0]), {
    user_id: nia.id, conversation_id: conv, message_id: m, kind: 'reaction', reactor_id: ben.id, title: 'SIS', body: GENERIC,
  }, attempts[0].raw);
  assert(!attempts[0].raw.includes('hidden words') && !attempts[0].raw.includes('👍'));
});

test('a media message: qk carries the kind', async () => {
  const pia = await person('pia');
  const conv = await direct(pia, ben);
  // Written as the superuser: a member's photo insert needs an uploaded object, which is not what is under test.
  const [{ id: m }] = await sql`insert into public.messages(conversation_id, sender_id, body, attachment_path)
    values (${conv}, ${pia.id}, '', ${`${conv}/rx-photo.jpg`}) returning id`;
  await setReaction(ben, m, '👍');
  await react(m, ben);
  assertEquals(attempts.length, 1);
  assertEquals([data(attempts[0]).qk, 'q' in data(attempts[0])], ['photo', false], attempts[0].raw);
});

test('private chat: ct and ot, encrypted, never emoji, quote or kind', async () => {
  const amy = await person('amy');
  const dan = await person('dan');
  const conv = await direct(amy, dan);
  const m = await say(amy, conv, 'secret words');
  const ct = `Q1R${crypto.randomUUID().replaceAll('-', '')}`.padEnd(900, 'A');
  await as(dan, (tx) => tx`select public.set_reaction_encrypted(${m}, ${ct}, 1::smallint)`);
  const r = await react(m, dan);
  assertEquals([r.status, r.text], [204, '']);
  assertEquals(attempts.length, 1);
  assertEquals(data(attempts[0]), {
    user_id: amy.id, conversation_id: conv, message_id: m, kind: 'reaction', reactor_id: dan.id,
    title: dan.name, body: GENERIC, encrypted: 'true', ct, ot: '1',
  }, attempts[0].raw);
  assert(!attempts[0].raw.includes('secret words'), 'the quote of a private chat never travels');
  cleanLogs(r.lines, [ct.slice(0, 20), 'secret words']);
});

test('not a reaction, or a malformed one: 204, empty, nothing sent; the well-formed twin sends', async () => {
  const mia = await person('mia');
  const conv = await direct(mia, ben);
  const m = await say(mia, conv, 'twin words');
  await setReaction(ben, m, '👍');
  const bad: unknown[] = [
    { reaction: { message_id: m } },
    { reaction: { user_id: ben.id } },
    { reaction: { message_id: m, user_id: 'not-a-uuid' } },
    { reaction: { message_id: m, user_id: `${ben.id}x` } },
    { reaction: { message_id: ` ${m}`, user_id: ben.id } },
    { reaction: { message_id: 42, user_id: ben.id } },
    { reaction: { message_id: [m], user_id: ben.id } },
    { reaction: `${m}:${ben.id}` },
    { reaction: null },
    { message_id: m, user_id: ben.id },
    {},
    'not json',
  ];
  for (const b of bad) {
    const r = await post(b);
    assertEquals([r.status, r.text, attempts.length], [204, '', 0], `nothing for ${JSON.stringify(b)}`);
    cleanLogs(r.lines, [`${ben.id}x`]);
  }
  const ok = await react(m, ben);
  assertEquals([ok.status, ok.text, attempts.length], [204, '', 1], 'the well-formed twin sends');
});

test('unknown ids: 204, empty, nothing sent', async () => {
  const r = await post({ reaction: { message_id: crypto.randomUUID(), user_id: crypto.randomUUID() } });
  assertEquals([r.status, r.text, attempts.length], [204, '', 0]);
  cleanLogs(r.lines, []);
});

test('FCM 401: one retry with a fresh token', async () => {
  const fay = await person('fay');
  const conv = await direct(fay, ben);
  const m = await say(fay, conv, 'retry words');
  await setReaction(ben, m, '👍');
  answers.push({ status: 401, body: { error: { code: 401, status: 'UNAUTHENTICATED' } } });
  const r = await react(m, ben);
  assertEquals(r.status, 204);
  assertEquals(attempts.length, 2, 'the refused send and one retry');
  assert(attempts[0].auth !== attempts[1].auth, `a fresh token: ${attempts.map((a) => a.auth)}`);
  assertEquals(attempts[1].raw, attempts[0].raw, 'the same push again');
  cleanLogs(r.lines, ['retry words', '👍']);
});

test('FCM 500 on a claimed push: no resend, and asking again sends nothing', async () => {
  const gil = await person('gil');
  const conv = await direct(gil, ben);
  const m = await say(gil, conv, 'lost words');
  await setReaction(ben, m, '👍');
  answers.push({ status: 500, body: { error: { code: 500, status: 'INTERNAL' } } });
  const r = await react(m, ben);
  assertEquals([r.status, r.text, attempts.length], [204, '', 1], 'one try');
  cleanLogs(r.lines, ['lost words', '👍', gil.token]);
  const again = await react(m, ben);
  assertEquals(attempts.length, 0, 'claimed: not sent again');
  answers.length = 0;
  void again;
});

test('teardown', async () => {
  await sql.end();
});
