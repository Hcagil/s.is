// The Mark as read / Reply notification buttons, end to end against the real
// local stack: a message -> notify-on-message mints the push's action ticket
// -> the phone POSTs it to notification-action -> public.notification_action
// -> the database row. Both functions are loaded as deployed (Deno.serve);
// only Google's endpoints are stood in for. The HMAC secret is what the
// deployed functions use: the service role key.
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all \
//     test/edge/notification_action_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  type ActionClaims,
  sha256Hex,
  signActionToken,
} from '../../supabase/functions/_shared/action_token.ts';

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
const pem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...der)).match(/.{1,64}/g)!.join('\n')
}\n-----END PRIVATE KEY-----\n`;
Deno.env.set('FCM_SERVICE_ACCOUNT', JSON.stringify({
  client_email: 'sender@sis-test.iam.gserviceaccount.com',
  private_key: pem,
  project_id: 'sis-test',
}));
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);

const sent: Record<string, unknown>[] = [];
// When set, the next RPC call to notification_action answers with this instead
// of reaching the database (a database error the function has no mapping for).
let rpcAnswer: (() => Response | Promise<Response>) | null = null;
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith('https://oauth2.googleapis.com/')) {
    return Response.json({ access_token: 'ya29.test', token_type: 'Bearer', expires_in: 3600 });
  }
  if (url.startsWith('https://fcm.googleapis.com/')) {
    sent.push(JSON.parse(String(init?.body ?? (input as Request).body)).message);
    return Response.json({ name: `projects/sis-test/messages/${sent.length}` });
  }
  if (rpcAnswer && url.includes('/rest/v1/rpc/notification_action')) {
    const a = rpcAnswer;
    rpcAnswer = null;
    return await a();
  }
  return realFetch(input, init);
};

// The runtime: capture each function's handler as it registers.
const handlers: ((req: Request) => Response | Promise<Response>)[] = [];
const pending: Promise<unknown>[] = [];
(globalThis as Record<string, unknown>).EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
Object.defineProperty(Deno, 'serve', {
  configurable: true,
  writable: true,
  value: (h: (req: Request) => Response | Promise<Response>) => {
    handlers.push(h);
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  },
});
await import('../../supabase/functions/notify-on-message/index.ts');
const notify = handlers.at(-1)!;
await import('../../supabase/functions/notification-action/index.ts');
const action = handlers.at(-1)!;
assert(notify !== action, 'both functions registered a handler');

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });

function as<T>(uid: string, email: string, session: string, body: (tx: postgres.TransactionSql) => Promise<T>) {
  return sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({
      sub: uid, role: 'authenticated', email, session_id: session,
    })}, true)`;
    await tx`set local role authenticated`;
    return await body(tx);
  });
}

type Person = { id: string; session: string; email: string; name: string; token: string };
const run = Date.now().toString(36);
const names = ['bob', 'ann', 'ivy', 'cat', 'dee', 'rat'];
const people: Person[] = names.map((w) => ({
  id: crypto.randomUUID(),
  session: crypto.randomUUID(),
  email: `na-${w}-${run}@edge.test`,
  name: w[0].toUpperCase() + w.slice(1),
  token: `na-edge-${w}-${run}`.padEnd(24, '0'),
}));
const p = Object.fromEntries(names.map((w, i) => [w, people[i]])) as Record<string, Person>;
let conv = '';
let catConv = '';

for (const x of people) {
  await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
            values (${x.id}, ${x.email}, now(), ${sql.json({ full_name: x.name })})`;
  await sql`insert into app_private.allowlist(email) values (${x.email})`;
  await sql`insert into auth.sessions (id, user_id, created_at, updated_at) values (${x.session}, ${x.id}, now(), now())`;
  await as(x.id, x.email, x.session, (tx) => tx`select public.activate_session()`);
  await as(x.id, x.email, x.session,
    (tx) => tx`select public.register_device_token(${x.token}, ${x === p.ivy ? 'ios' : 'android'}, true)`);
}
await sql`insert into app_private.tag_finds(finder, found_id)
          select ${p.bob.id}::uuid, unnest(${people.slice(1).map((x) => x.id)}::uuid[])`;
[{ id: conv }] = await as(p.bob.id, p.bob.email, p.bob.session,
  (tx) => tx`select public.start_group_conversation(${'na-edge-' + run}, ${[p.ann.id, p.ivy.id, p.dee.id, p.rat.id]}::uuid[]) as id`);
[{ id: catConv }] = await as(p.bob.id, p.bob.email, p.bob.session,
  (tx) => tx`select public.start_group_conversation(${'na-edge-cat-' + run}, ${[p.cat.id]}::uuid[]) as id`);

async function bobSays(text: string): Promise<string> {
  const [{ id }] = await as(p.bob.id, p.bob.email, p.bob.session,
    (tx) => tx`insert into public.messages(conversation_id, sender_id, body) values (${conv}, ${p.bob.id}, ${text}) returning id`);
  return id;
}

async function deliver(messageId: string) {
  sent.length = 0;
  pending.length = 0;
  const res = await notify(new Request('http://localhost/notify-on-message', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'INSERT', table: 'messages', record: { id: messageId } }),
  }));
  await Promise.all(pending);
  assertEquals(res.status, 204);
}

/** POSTs [body] to notification-action as the phone does: JSON, no Authorization. */
async function post(body: unknown, raw = false): Promise<number> {
  const res = await action(new Request(`${apiUrl}/functions/v1/notification-action`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: raw ? String(body) : JSON.stringify(body),
  }));
  await res.body?.cancel();
  return res.status;
}

async function mint(x: Person, over: Partial<ActionClaims> = {}, secret = serviceKey) {
  return signActionToken({
    u: x.id,
    c: conv,
    d: await sha256Hex(x.token),
    a: ['mark_read', 'reply'],
    e: Math.floor(Date.now() / 1000) + 600,
    ...over,
  }, secret);
}

async function lastRead(x: Person, c = conv): Promise<Date | null> {
  const [r] = await sql`select last_read_at from public.conversation_members
                         where conversation_id = ${c} and user_id = ${x.id} and left_at is null`;
  return r?.last_read_at ?? null;
}
async function backdate(x: Person) {
  await sql`update public.conversation_members set last_read_at = now() - interval '1 hour'
             where conversation_id = ${conv} and user_id = ${x.id}`;
}
async function messageRow(id: string) {
  const rows = await sql`select sender_id::text, conversation_id::text, body from public.messages where id = ${id}`;
  return rows[0] ?? null;
}
const recent = (d: Date | null) => d !== null && Date.now() - d.getTime() < 60_000;

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({
  ...opts,
  name: 'seam: the ticket a real push carries replies and marks read in the database, as its recipient',
  fn: async () => {
    const msg = await bobSays(`hello ${run}`);
    await deliver(msg);
    const toAnn = sent.find((m) => m.token === p.ann.token)!;
    const toIvy = sent.find((m) => m.token === p.ivy.token)!;
    assert(toAnn && toIvy, `ann and ivy were sent pushes: ${JSON.stringify(sent)}`);
    const data = toAnn.data as Record<string, string>;
    // The old keys are still there, unchanged in meaning.
    assertEquals([data.conversation_id, data.user_id, data.message_id], [conv, p.ann.id, msg]);
    assertEquals(data.action_url, `${apiUrl}/functions/v1/notification-action`);
    assertEquals((toIvy.apns as any)?.payload?.aps?.category, 'SIS_MESSAGE');
    const ivyData = toIvy.data as Record<string, string>;
    assert(ivyData.action_token && ivyData.action_token !== data.action_token, 'each device its own token');

    // The phone answers with exactly what the push carried.
    await backdate(p.ann);
    const replyId = crypto.randomUUID();
    const reply = { token: data.action_token, conversation_id: data.conversation_id, action: 'reply', id: replyId, body: 'on my way' };
    assertEquals(await post(reply), 200, 'reply accepted');
    assertEquals(await messageRow(replyId), { sender_id: p.ann.id, conversation_id: conv, body: 'on my way' },
      'the reply is stored as ann, in the chat, with the phone\'s id');
    assert(recent(await lastRead(p.ann)), 'replying marked the chat read for ann');
    assertEquals(await post(reply), 200, 'the same reply retried (lost answer) is still 200');
    assertEquals((await sql`select count(*)::int as n from public.messages where id = ${replyId}`)[0].n, 1, 'stored once');
    assertEquals(await post({ ...reply, body: 'something else' }), 409, 'the id reused with a different body');
    assertEquals((await messageRow(replyId))?.body, 'on my way');

    await backdate(p.ann);
    const bobBefore = await lastRead(p.bob);
    assertEquals(await post({ token: data.action_token, conversation_id: conv, action: 'mark_read' }), 200);
    assert(recent(await lastRead(p.ann)), 'mark as read moved ann\'s read mark');
    assertEquals(await lastRead(p.bob), bobBefore, 'nobody else\'s');

    // Ivy's token cannot be used as ann: it names ivy.
    await backdate(p.ivy);
    assertEquals(await post({ token: ivyData.action_token, conversation_id: conv, action: 'mark_read' }), 200);
    assert(recent(await lastRead(p.ivy)), 'ivy\'s ticket marks ivy read');
  },
});

Deno.test({
  ...opts,
  name: 'refused tickets: forged, expired, wrong chat, action not granted, non-member -- 403, and nothing changes',
  fn: async () => {
    const id = () => crypto.randomUUID();
    const wrong: string[] = [];
    const soft = (have: number, want: number, what: string) => {
      if (have !== want) wrong.push(`${what}: ${have}, want ${want}`);
    };
    const tried: string[] = [];
    const reply = async (token: string, c = conv) => {
      const mid = id();
      tried.push(mid);
      return await post({ token, conversation_id: c, action: 'reply', id: mid, body: 'x' });
    };
    // Controls: the same shapes, honestly minted, pass.
    assertEquals(await post({ token: await mint(p.ann), conversation_id: conv, action: 'mark_read' }), 200, 'control');
    assertEquals(await post({ token: await mint(p.cat, { c: catConv }), conversation_id: catConv, action: 'mark_read' }), 200,
      'control: cat in her own chat');

    await backdate(p.ann);
    soft(await reply(await mint(p.ann, {}, 'not-the-secret')), 403, 'signed with another secret');
    const good = await mint(p.ann);
    const [v, payload, sig] = good.split('.');
    const forged = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
    forged.u = p.dee.id;
    const forgedPayload = btoa(JSON.stringify(forged)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
    soft(await reply(`${v}.${forgedPayload}.${sig}`), 403, 'payload altered under the signature');
    soft(await reply(`${v}.${payload}.${sig.slice(0, 10)}${sig[10] === 'A' ? 'B' : 'A'}${sig.slice(11)}`), 403,
      'signature altered');
    soft(await reply(await mint(p.ann, { e: Math.floor(Date.now() / 1000) - 5 })), 403, 'expired');
    soft(await reply('garbage'), 403, 'not a token');
    soft(await reply(await mint(p.ann, { c: catConv }), conv), 403, 'token for another chat than the body names');
    soft(await reply(await mint(p.ann), catConv), 403, 'body names another chat than the token');
    soft(await reply(await mint(p.ann, { a: ['mark_read'] })), 403, 'reply not in the token');
    soft(await post({ token: await mint(p.ann, { a: ['reply'] }), conversation_id: conv, action: 'mark_read' }), 403,
      'mark_read not in the token');
    soft(await reply(await mint(p.ann, { d: await sha256Hex('another-phone') })), 403, 'a device ann never had');
    soft(await reply(await mint(p.cat)), 403, 'cat is not a member of the group (42501)');
    soft(await post({ token: await mint(p.cat), conversation_id: conv, action: 'mark_read' }), 403,
      'cat cannot mark the group read');

    assertEquals(wrong, [], 'every refused ticket answers 403');
    const stored = await sql`select id from public.messages where id in ${sql(tried)}`;
    assertEquals(stored.length, 0, 'no refused reply was stored');
    assert(!recent(await lastRead(p.ann)), 'no refused call marked ann read');
  },
});

Deno.test({
  ...opts,
  name: 'invalid requests are 400 (including a reply the database refuses as 22023)',
  fn: async () => {
    const t = await mint(p.ann);
    const ok = { token: t, conversation_id: conv, action: 'reply', id: crypto.randomUUID(), body: 'x' };
    const bad: [string, unknown, boolean?][] = [
      ['not JSON', '{nope', true],
      ['an array', [], false],
      ['no token', { ...ok, token: undefined }],
      ['no conversation', { ...ok, conversation_id: undefined }],
      ['an unknown action', { ...ok, action: 'delete' }],
      ['no action', { ...ok, action: undefined }],
      ['a reply without an id', { ...ok, id: undefined }],
      ['a reply whose id is not a uuid', { ...ok, id: 'abc' }],
      ['a reply without a body', { ...ok, body: undefined }],
      ['an empty reply', { ...ok, body: '' }],
      ['a 4001-character reply', { ...ok, body: 'x'.repeat(4001) }],
      ['a reply body that is not a string', { ...ok, body: 42 }],
      ['a whitespace-only reply', { ...ok, body: '   ' }],
    ];
    const wrong: string[] = [];
    for (const [what, body, raw] of bad) {
      const have = await post(body, raw ?? false);
      // A request with no token at all may be read as invalid (400) or as a
      // bad token (403); both are the contract, nothing else is.
      const want = what === 'no token' ? [400, 403] : [400];
      if (!want.includes(have)) wrong.push(`${what}: ${have}, want ${want.join(' or ')}`);
    }
    assertEquals(wrong, [], 'every invalid request is refused as invalid');
    const id4000 = crypto.randomUUID();
    assertEquals(await post({ ...ok, id: id4000, body: 'y'.repeat(4000) }), 200, 'a 4000-character reply is fine');
    assertEquals((await messageRow(id4000))?.body.length, 4000);
  },
});

Deno.test({
  ...opts,
  name: 'a replaced phone (newer sign-in) is refused even with an unexpired ticket',
  fn: async () => {
    const t = await mint(p.dee);
    assertEquals(await post({ token: t, conversation_id: conv, action: 'mark_read' }), 200, 'control: before');
    const newer = crypto.randomUUID();
    await sql`insert into auth.sessions (id, user_id, created_at, updated_at) values (${newer}, ${p.dee.id}, now(), now())`;
    await as(p.dee.id, p.dee.email, newer, (tx) => tx`select public.activate_session()`);
    assertEquals(await post({ token: t, conversation_id: conv, action: 'mark_read' }), 403, 'mark_read after');
    const mid = crypto.randomUUID();
    assertEquals(await post({ token: t, conversation_id: conv, action: 'reply', id: mid, body: 'x' }), 403, 'reply after');
    assertEquals(await messageRow(mid), null);
  },
});

Deno.test({
  ...opts,
  name: 'rate limit: the 21st action in a minute is 429',
  fn: async () => {
    const t = await mint(p.rat);
    for (let i = 1; i <= 20; i++) {
      const body = i % 2
        ? { token: t, conversation_id: conv, action: 'mark_read' }
        : { token: t, conversation_id: conv, action: 'reply', id: crypto.randomUUID(), body: `r${i}` };
      assertEquals(await post(body), 200, `action ${i}`);
    }
    assertEquals(await post({ token: t, conversation_id: conv, action: 'mark_read' }), 429, 'the 21st');
    assertEquals(await post({ token: await mint(p.ann), conversation_id: conv, action: 'mark_read' }), 200,
      'per member: ann is not limited by rat');
  },
});

Deno.test({
  ...opts,
  name: 'any other failure is 500',
  fn: async () => {
    rpcAnswer = () => Response.json({ code: 'XX000', message: 'internal', details: null, hint: null }, { status: 500 });
    assertEquals(await post({ token: await mint(p.ann), conversation_id: conv, action: 'mark_read' }), 500, 'an unmapped database error');
    rpcAnswer = () => Promise.reject(new TypeError('connection reset'));
    assertEquals(await post({ token: await mint(p.ann), conversation_id: conv, action: 'mark_read' }), 500, 'the database unreachable');
    rpcAnswer = null;
  },
});

Deno.test({
  ...opts,
  name: 'act_as: the member\'s identity does not outlive the transaction on the connection',
  fn: async () => {
    // One connection (max: 1), so the next statement runs where the claims were set.
    const [{ r }] = await sql.begin(async (tx) => {
      await tx`set local role service_role`;
      return await tx`select public.notification_action(${p.ann.id}::uuid, ${await sha256Hex(p.ann.token)},
                        ${conv}::uuid, 'mark_read', null, null) as r`;
    });
    assertEquals(r, 'done');
    const [{ claims, me }] = await sql`select coalesce(current_setting('request.jwt.claims', true), '') as claims,
                                              auth.uid() as me`;
    assertEquals([claims, me], ['', null], 'nothing of ann is left on the connection');
  },
});

Deno.test({
  ...opts,
  name: 'teardown',
  fn: async () => {
    await sql.begin(async (tx) => {
      await tx`delete from app_private.tag_finds where finder in ${sql(people.map((x) => x.id))}`;
      await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((x) => x.id))}`;
      await tx`delete from app_private.allowlist where email in ${sql(people.map((x) => x.email))}`;
    }).catch(() => {});
    await sql.end();
  },
});
