// notification-action and the admin chat, against the real local stack: a
// ticket honestly minted for the owner's admin chat is refused with 403
// not_permitted for both actions, and nothing reaches the chat (a reply there
// would be parsed as a command). The same owner, same device, in an ordinary
// chat passes -- so the refusal is about the admin chat, not the ticket.
//
// Run (the local stack must be up, app_private.owners empty):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all \
//     test/edge/notification_action_admin_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { type ActionClaims, sha256Hex, signActionToken } from '../../supabase/functions/_shared/action_token.ts';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);

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
await import('../../supabase/functions/notification-action/index.ts');
const action = handlers.at(-1)!;

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });
const run = Date.now().toString(36);
const own = {
  id: crypto.randomUUID(),
  session: crypto.randomUUID(),
  email: `na-admin-own-${run}@mail.test`,
  token: `na-admin-own-${run}`.padEnd(24, '0'),
};
const mate = { id: crypto.randomUUID(), email: `na-admin-mate-${run}@mail.test` };

function asOwn<T>(body: (tx: postgres.TransactionSql) => Promise<T>) {
  return sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({
      sub: own.id, role: 'authenticated', email: own.email, session_id: own.session,
    })}, true)`;
    await tx`set local role authenticated`;
    return await body(tx);
  });
}

const [{ n }] = await sql`select count(*)::int as n from app_private.owners`;
if (n !== 0) throw new Error('app_private.owners is not empty on this stack; this test needs it empty');

for (const x of [own, mate]) {
  await sql`insert into auth.users (id, email, email_confirmed_at) values (${x.id}, ${x.email}, now())`;
  await sql`insert into app_private.allowlist(email) values (${x.email})`;
}
await sql`insert into auth.sessions (id, user_id, created_at, updated_at) values (${own.session}, ${own.id}, now(), now())`;
await asOwn((tx) => tx`select public.activate_session()`);
await asOwn((tx) => tx`select public.register_device_token(${own.token}, 'android', true)`);
await sql`insert into app_private.owners(user_id) values (${own.id})`;
const [{ id: adminConv }] = await sql`select c.id::text from public.conversations c
  join public.conversation_members m on m.conversation_id = c.id where c.admin_chat and m.user_id = ${own.id}`;
await sql`insert into app_private.tag_finds(finder, found_id) values (${own.id}, ${mate.id})`;
const [{ id: ordinary }] = await asOwn(
  (tx) => tx`select public.start_group_conversation(${'na-admin-' + run}, ${[mate.id]}::uuid[])::text as id`,
);

async function mint(c: string, over: Partial<ActionClaims> = {}) {
  return signActionToken({
    u: own.id, c, d: await sha256Hex(own.token), a: ['mark_read', 'reply'],
    e: Math.floor(Date.now() / 1000) + 600, ...over,
  }, serviceKey);
}
async function post(body: unknown): Promise<{ status: number; text: string }> {
  const res = await action(new Request(`${apiUrl}/functions/v1/notification-action`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  }));
  return { status: res.status, text: await res.text() };
}
const adminRows = async () =>
  (await sql`select count(*)::int as n from public.messages where conversation_id = ${adminConv}`)[0].n;

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({
  ...opts,
  name: 'control: the owner\'s ticket for an ordinary chat is accepted',
  fn: async () => {
    const r = await post({ token: await mint(ordinary), conversation_id: ordinary, action: 'mark_read' });
    assertEquals(r.status, 200, r.text);
    const id = crypto.randomUUID();
    const rep = await post({ token: await mint(ordinary), conversation_id: ordinary, action: 'reply', id, body: 'hi' });
    assertEquals(rep.status, 200, rep.text);
  },
});

Deno.test({
  ...opts,
  name: 'the admin chat: reply and mark_read are refused with 403 not_permitted, and nothing is written',
  fn: async () => {
    const before = await adminRows();
    const id = crypto.randomUUID();
    const rep = await post({
      token: await mint(adminConv), conversation_id: adminConv, action: 'reply', id, body: '/listtesters',
    });
    assertEquals(rep.status, 403, rep.text);
    assert(rep.text.includes('not_permitted'), `body names not_permitted: ${rep.text}`);
    const mr = await post({ token: await mint(adminConv), conversation_id: adminConv, action: 'mark_read' });
    assertEquals(mr.status, 403, mr.text);
    assert(mr.text.includes('not_permitted'), `body names not_permitted: ${mr.text}`);
    assertEquals(await adminRows(), before, 'no message (and so no command, no reply) reached the admin chat');
    assertEquals((await sql`select count(*)::int as n from public.messages where id = ${id}`)[0].n, 0);
  },
});

Deno.test({
  ...opts,
  name: 'teardown',
  fn: async () => {
    await sql.begin(async (tx) => {
      await tx`delete from app_private.owners where user_id = ${own.id}`;
      await tx`delete from app_private.tag_finds where finder = ${own.id}`;
      await tx`delete from app_private.device_tokens where user_id = ${own.id}`;
      await tx`delete from app_private.allowlist where email in ${sql([own.email, mate.email])}`;
      await tx`delete from auth.users where id in ${sql([own.id, mate.id])}`;
      await tx`delete from public.conversations c where c.admin_chat and not exists
                 (select 1 from public.conversation_members m where m.conversation_id = c.id)`;
      await tx`delete from public.conversations where id = ${ordinary}`;
    }).catch((e) => console.error('teardown:', e.message));
    await sql.end();
  },
});
