// notify-on-message against the real local database, with FCM stood in for.
//
// The seam under test: what push_targets() says about each recipient ->
// what the function sends to FCM. From 0.12 a device that shows pushes
// itself (device_tokens.shows_itself) must get DATA ONLY -- a notification
// block would make Android draw its own notification beside the app's
// grouped one. Every other device is an older build that cannot draw a
// data-only push, so it must still get the notification block, or it goes
// silent. Both kinds sit on the same delivery list, so both are asserted
// from ONE message: a function that treats everyone alike fails one side.
//
// The function is loaded as deployed (Deno.serve + EdgeRuntime.waitUntil);
// only Google's two endpoints are replaced. Everything else -- the RPC, the
// claim, the per-recipient wording -- is the local stack.
//
// Run (the local stack must be up, `supabase status -o env` gives the key):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all \
//     test/edge/notify_on_message_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');

// A throwaway service account: the function signs its OAuth assertion with
// this key; the stand-in token endpoint accepts anything.
const pair = await crypto.subtle.generateKey(
  {
    name: 'RSASSA-PKCS1-v1_5',
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: 'SHA-256',
  },
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

// Google stood in for; everything else goes to the real stack.
type Sent = { url: string; message: Record<string, unknown> };
const sent: Sent[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith('https://oauth2.googleapis.com/')) {
    return Response.json({ access_token: 'test-access-token', expires_in: 3600, token_type: 'Bearer' });
  }
  if (url.startsWith('https://fcm.googleapis.com/')) {
    const body = JSON.parse(String(init?.body ?? (input as Request).body));
    sent.push({ url, message: body.message });
    return Response.json({ name: `projects/sis-test/messages/${sent.length}` });
  }
  return realFetch(input, init);
};

// The runtime the function is deployed into.
let handler: ((req: Request) => Response | Promise<Response>) | undefined;
const pending: Promise<unknown>[] = [];
(globalThis as Record<string, unknown>).EdgeRuntime = {
  waitUntil: (p: Promise<unknown>) => pending.push(p),
};
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

/** Runs [body] as [uid] on [session], the way a signed-in client reaches SQL. */
function as<T>(uid: string, email: string, session: string, body: (tx: postgres.TransactionSql) => Promise<T>) {
  return sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({
      sub: uid,
      role: 'authenticated',
      email,
      session_id: session,
    })}, true)`;
    await tx`set local role authenticated`;
    return await body(tx);
  });
}

Deno.test({
  name: 'one message: data only to the phone that shows pushes itself, a notification to the older build',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = Date.now().toString(36);
    const people = ['sender', 'newbuild', 'oldbuild'].map((who, i) => ({
      id: crypto.randomUUID(),
      session: crypto.randomUUID(),
      email: `${who}-${run}@edge.test`,
      name: `${who[0].toUpperCase()}${who.slice(1)}`,
      token: `edge-${who}-${run}`.padEnd(16, '0'),
      i,
    }));
    const [sender, newBuild, oldBuild] = people;
    const title = `edge-group-${run}`;
    try {
      for (const p of people) {
        await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values (${p.id}, ${p.email}, now(), ${sql.json({ full_name: p.name })})`;
        await sql`insert into app_private.allowlist(email) values (${p.email})`;
        await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                  values (${p.session}, ${p.id}, now(), now())`;
        await as(p.id, p.email, p.session, (tx) => tx`select public.activate_session()`);
      }
      // 0.12: registers saying it shows pushes itself.
      await as(newBuild.id, newBuild.email, newBuild.session,
        (tx) => tx`select public.register_device_token(${newBuild.token}, 'android', true)`);
      // 0.11: the two-argument call it has always made.
      await as(oldBuild.id, oldBuild.email, oldBuild.session,
        (tx) => tx`select public.register_device_token(${oldBuild.token}, 'android')`);

      const [{ id: conversationId }] = await as(sender.id, sender.email, sender.session,
        (tx) => tx`select public.start_group_conversation(${title}, ${[newBuild.id, oldBuild.id]}::uuid[]) as id`);
      const [{ id: messageId }] = await as(sender.id, sender.email, sender.session,
        (tx) => tx`insert into public.messages(conversation_id, sender_id, body)
                   values (${conversationId}, ${sender.id}, 'edge hello') returning id`);

      // What the database says each recipient gets (read without claiming).
      const expected = await sql`select token, conversation_id::text, title, body, shows_itself
                                   from app_private.push_targets_for_message(${messageId})`;
      assertEquals(expected.length, 2, 'fixture: two recipients on the delivery list');
      assertEquals(
        expected.map((t) => `${t.token}:${t.shows_itself}`).sort(),
        [`${newBuild.token}:true`, `${oldBuild.token}:false`].sort(),
        'fixture: one device of each kind',
      );

      sent.length = 0;
      pending.length = 0;
      const res = await handler!(new Request('http://localhost/notify-on-message', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ type: 'INSERT', table: 'messages', record: { id: messageId } }),
      }));
      assertEquals(res.status, 204);
      await Promise.all(pending);

      assertEquals(sent.length, 2, `one send per recipient, got ${JSON.stringify(sent)}`);
      for (const s of sent) assert(s.url.includes('/projects/sis-test/'), s.url);

      for (const target of expected) {
        const mine = sent.filter((s) => s.message.token === target.token);
        assertEquals(mine.length, 1, `exactly one send to ${target.token}`);
        const m = mine[0].message;
        const data = m.data as Record<string, unknown>;
        // What the app reads (conversation_id, title, body), as strings --
        // FCM refuses a data map with any other value type.
        assertEquals(data, {
          conversation_id: target.conversation_id,
          title: target.title,
          body: target.body,
        }, `data for ${target.token}`);
        assertEquals(data.conversation_id, conversationId);
        if (target.shows_itself) {
          assert(!('notification' in m), `a device that shows pushes itself gets data only: ${JSON.stringify(m)}`);
          const android = (m.android ?? {}) as Record<string, unknown>;
          assert(!('notification' in android), `nor an Android notification block: ${JSON.stringify(m)}`);
        } else {
          assertEquals(m.notification, { title: target.title, body: target.body },
            `an older build still gets a notification it can show: ${JSON.stringify(m)}`);
        }
      }
    } finally {
      await sql.begin(async (tx) => {
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((p) => p.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((p) => p.email))}`;
      }).catch(() => {});
      await sql.end();
    }
  },
});
