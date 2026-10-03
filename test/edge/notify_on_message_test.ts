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
// When set, the delivery list comes back as a database without the 0.30.6
// and 0.30.8 columns returns it: no sender, no chat, no badge (a function
// deployed ahead of its migration, or rolled back behind it).
let oldSchema = false;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (oldSchema && url.includes('/rest/v1/rpc/push_targets')) {
    const res = await realFetch(input, init);
    const rows = (await res.json()) as Record<string, unknown>[];
    return Response.json(rows.map(({ sender: _s, chat: _c, badge: _b, ...rest }) => rest), { status: res.status });
  }
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

/** 0.30.8: [uid]'s own unread total, straight from the database -- the badge their push must carry. */
async function unreadOf(uid: string): Promise<number> {
  const [{ n }] = await sql`select app_private.unread_total(${uid}::uuid)::int as n`;
  return n as number;
}

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
  name: 'one message: data only to the phone that shows pushes itself, a notification to the older build, each addressed to its recipient',
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

      // v0.22.0: starting a conversation needs reach. Seed exactly the pairs
      // this fixture starts, as tag finds (not contacts, which would also
      // open rows and pictures), as the service role.
      await sql`insert into app_private.tag_finds(finder, found_id)
                values (${sender.id}, ${newBuild.id}), (${sender.id}, ${oldBuild.id})`;

      const [{ id: conversationId }] = await as(sender.id, sender.email, sender.session,
        (tx) => tx`select public.start_group_conversation(${title}, ${[newBuild.id, oldBuild.id]}::uuid[]) as id`);
      const [{ id: messageId }] = await as(sender.id, sender.email, sender.session,
        (tx) => tx`insert into public.messages(conversation_id, sender_id, body)
                   values (${conversationId}, ${sender.id}, 'edge hello') returning id`);

      // What the database says each recipient gets (read without claiming).
      const expected = await sql`select token, user_id::text, conversation_id::text, title, body, shows_itself,
                                        sender, chat
                                   from app_private.push_targets_for_message(${messageId})`;
      assertEquals(expected.length, 2, 'fixture: two recipients on the delivery list');
      for (const t of expected) {
        assertEquals([t.sender, t.chat], [sender.name, title], 'fixture: a group message, preview full');
      }
      assertEquals(
        expected.map((t) => `${t.token}:${t.shows_itself}`).sort(),
        [`${newBuild.token}:true`, `${oldBuild.token}:false`].sort(),
        'fixture: one device of each kind',
      );
      // Who each device belongs to, from the fixture, not from the function.
      const recipientOf: Record<string, string> = {
        [newBuild.token]: newBuild.id,
        [oldBuild.token]: oldBuild.id,
      };

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
        // What the app reads (conversation_id, title, body, and the
        // recipient it is addressed to), as strings -- FCM refuses a data
        // map with any other value type. user_id and message_id are on BOTH shapes: the
        // phone drops a push addressed to someone other than its owner.
        assertEquals(data, {
          conversation_id: target.conversation_id,
          title: target.title,
          body: target.body,
          user_id: target.user_id,
          // The message itself, so the phone's push receipt can be matched
          // to it on the server.
          message_id: messageId,
          // 0.30.6: a group message names its sender and the group apart,
          // on both Android shapes.
          sender: target.sender,
          chat: target.chat,
          // 0.30.8: the recipient's own unread total, as a string.
          badge: String(await unreadOf(target.user_id)),
        }, `data for ${target.token}`);
        assertEquals(data.conversation_id, conversationId);
        assertEquals(data.user_id, recipientOf[target.token as string],
          `addressed to the device's own member: ${target.token}`);
        assert(data.user_id !== sender.id, 'never addressed to the sender');
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
        await tx`delete from app_private.tag_finds where finder in ${sql(people.map((p) => p.id))}`;
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((p) => p.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((p) => p.email))}`;
      }).catch(() => {});
    }
  },
});

/** POSTs the database webhook for [messageId] as it is deployed; returns the response once the sends are done. */
async function deliver(messageId: string) {
  sent.length = 0;
  pending.length = 0;
  const res = await handler!(new Request('http://localhost/notify-on-message', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'INSERT', table: 'messages', record: { id: messageId } }),
  }));
  await Promise.all(pending);
  return { status: res.status, text: await res.text() };
}

// 0.28: an iPhone cannot run app code to draw a data-only push, so it gets a
// regular alert: a notification block (the server's wording, so the
// recipient's preview choice holds), the same data map, and an apns block
// that threads it per chat with the default sound. Android is unchanged:
// both Android shapes sit on the same message's delivery list as the
// iPhones, so a function that sends everyone the iOS shape -- or iOS the
// Android one -- fails here. The people who must get nothing are on the same
// message too, each held back by one gate.
Deno.test({
  name: 'one message: iPhones get an alert with apns, both Android shapes are unchanged, and the gates hold on iOS',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = Date.now().toString(36);
    const who = [
      'sender', 'droidnew', 'droidold', 'iosfull', 'iossender', 'iosnone',
      'ioschatmuted', 'iospersonmuted', 'iosrevoked', 'iosdelisted', 'iosdisplaced',
    ];
    const people = who.map((w) => ({
      id: crypto.randomUUID(),
      session: crypto.randomUUID(),
      email: `${w}-${run}@edge.test`,
      name: `${w[0].toUpperCase()}${w.slice(1)}`,
      token: `edge-${w}-${run}`.padEnd(16, '0'),
    }));
    const p = Object.fromEntries(who.map((w, i) => [w, people[i]]));
    const sender = p.sender;
    const recipients = people.slice(1);
    const title = `edge-ios-${run}`;
    const text = `edge ios hello ${run}`;
    const asP = <T>(x: typeof sender, body: (tx: postgres.TransactionSql) => Promise<T>) =>
      as(x.id, x.email, x.session, body);
    try {
      for (const x of people) {
        await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values (${x.id}, ${x.email}, now(), ${sql.json({ full_name: x.name })})`;
        await sql`insert into app_private.allowlist(email) values (${x.email})`;
        await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                  values (${x.session}, ${x.id}, now(), now())`;
        await asP(x, (tx) => tx`select public.activate_session()`);
      }
      // Registered the way each build does, through the RPC.
      const register = (x: typeof sender, platform: string, showsItself: boolean) =>
        asP(x, (tx) => tx`select public.register_device_token(${x.token}, ${platform}, ${showsItself})`);
      await register(p.droidnew, 'android', true);
      await register(p.droidold, 'android', false);
      await register(p.iosfull, 'ios', false);
      await register(p.iossender, 'ios', false);
      // shows_itself means nothing on an iPhone: it still gets the alert.
      await register(p.iosnone, 'ios', true);
      for (const x of [p.ioschatmuted, p.iospersonmuted, p.iosrevoked, p.iosdelisted, p.iosdisplaced]) {
        await register(x, 'ios', false);
      }
      await asP(p.iossender, (tx) => tx`insert into public.notification_settings(preview) values ('sender')`);
      await asP(p.iosnone, (tx) => tx`insert into public.notification_settings(preview) values ('none')`);

      await sql`insert into app_private.tag_finds(finder, found_id)
                select ${sender.id}::uuid, unnest(${recipients.map((r) => r.id)}::uuid[])`;
      const [{ id: conversationId }] = await asP(sender,
        (tx) => tx`select public.start_group_conversation(${title}, ${recipients.map((r) => r.id)}::uuid[]) as id`);

      // Each held-back member fails exactly one gate.
      await asP(p.ioschatmuted, (tx) => tx`insert into public.notification_mutes(kind, target)
                                            values ('conversation', ${conversationId})`);
      await asP(p.iospersonmuted, (tx) => tx`insert into public.notification_mutes(kind, target)
                                              values ('person', ${sender.id})`);
      // Still a member, still holding the device row: only the session is gone.
      await sql`delete from auth.sessions where id = ${p.iosrevoked.session}`;
      // Still a member with a session: only the allowlist entry is gone.
      await sql`delete from app_private.allowlist where email = ${p.iosdelisted.email}`;
      // Signed in on a newer session that has not registered yet: the iPhone's
      // own session is still alive in auth.sessions, only the device moved.
      const newer = crypto.randomUUID();
      await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                values (${newer}, ${p.iosdisplaced.id}, now(), now())`;
      await as(p.iosdisplaced.id, p.iosdisplaced.email, newer, (tx) => tx`select public.activate_session()`);

      const send = (body: string) => asP(sender,
        (tx) => tx`insert into public.messages(conversation_id, sender_id, body)
                   values (${conversationId}, ${sender.id}, ${body}) returning id`);
      const [{ id: messageId }] = await send(text);

      const expected = await sql`select token, user_id::text, conversation_id::text, title, body, platform, shows_itself,
                                        sender, chat
                                   from app_private.push_targets_for_message(${messageId})`;
      const delivered = [p.droidnew, p.droidold, p.iosfull, p.iossender, p.iosnone];
      assertEquals(expected.map((t) => t.token).sort(), delivered.map((x) => x.token).sort(),
        'fixture: the gates leave exactly five devices on the list');
      const target = (x: typeof sender) => expected.find((t) => t.token === x.token)!;
      assertEquals(target(p.iosnone).platform, 'ios', 'fixture: the delivery list says ios');
      assertEquals(target(p.iosnone).shows_itself, true, 'fixture: an iPhone that said it shows pushes itself');

      assertEquals(await deliver(messageId), { status: 204, text: '' }, 'a bare 204');
      assertEquals(sent.length, 5, `one send per delivered device, got ${JSON.stringify(sent)}`);
      const held = [p.ioschatmuted, p.iospersonmuted, p.iosrevoked, p.iosdelisted, p.iosdisplaced].map((x) => x.token);
      for (const s of sent) {
        assert(!held.includes(s.message.token as string), `sent past a gate: ${JSON.stringify(s.message)}`);
      }
      const messageTo = (x: typeof sender) => {
        const mine = sent.filter((s) => s.message.token === x.token);
        assertEquals(mine.length, 1, `exactly one send to ${x.name}`);
        return mine[0].message;
      };
      const badges: Record<string, number> = {};
      for (const x of delivered) badges[x.id] = await unreadOf(x.id);
      const dataFor = (x: typeof sender) => {
        const t = target(x);
        return {
          badge: String(badges[x.id]),
          user_id: x.id,
          message_id: messageId,
          conversation_id: conversationId,
          title: t.title,
          body: t.body,
          // 0.30.6: only for a group message the recipient may see named.
          ...(t.sender != null && t.chat != null ? { sender: t.sender, chat: t.chat } : {}),
        };
      };
      assertEquals([target(p.droidnew).sender, target(p.droidnew).chat], [sender.name, title],
        'fixture: the group message names sender and group for a full preview');
      assertEquals([target(p.iosnone).sender, target(p.iosnone).chat], [null, null],
        'fixture: preview none names neither');

      // Android, exactly as before 0.28.
      assertEquals(messageTo(p.droidnew), {
        token: p.droidnew.token,
        data: dataFor(p.droidnew),
        android: { priority: 'high' },
      }, 'an Android phone that shows pushes itself: data only, high priority, nothing else');
      assertEquals(messageTo(p.droidold), {
        token: p.droidold.token,
        notification: { title: target(p.droidold).title, body: target(p.droidold).body },
        data: dataFor(p.droidold),
        android: { priority: 'high' },
      }, 'an older Android build: a notification plus data, high priority, no apns');

      // 0.30.6: an iPhone cannot reword a group alert itself, so the server
      // does: the group is the title, each line "Sender: text". With preview
      // none there is no sender or group to name: the old wording stands.
      assertEquals(messageTo(p.iosfull).notification, { title, body: `${sender.name}: ${text}` },
        'iPhone, preview full: titled by the group, the line names the sender');
      assertEquals(messageTo(p.iossender).notification, { title, body: `${sender.name}: New message` },
        'iPhone, preview sender: titled by the group, the sender named, no text');
      assertEquals(messageTo(p.iosnone).notification, { title: 'SIS', body: 'New message' },
        'iPhone, preview none: unchanged');
      for (const x of [p.iosfull, p.iossender, p.iosnone]) {
        const m = messageTo(x);
        const t = target(x);
        // The base map the app reads is exactly as before; sender/chat may
        // ride along only with the server's own values.
        const data = m.data as Record<string, unknown>;
        const base = dataFor(x) as Record<string, unknown>;
        for (const k of ['user_id', 'message_id', 'conversation_id', 'title', 'body', 'badge']) {
          assertEquals(data[k], base[k], `${x.name}: data.${k}`);
        }
        for (const k of Object.keys(data)) {
          assert(k in base || (k === 'sender' && data[k] === t.sender) || (k === 'chat' && data[k] === t.chat),
            `${x.name}: unexpected data.${k}: ${JSON.stringify(data)}`);
        }
        const apns = m.apns as { payload?: { aps?: unknown } } | undefined;
        assertEquals(apns?.payload?.aps, { 'thread-id': conversationId, sound: 'default', badge: badges[x.id] },
          `${x.name}: threaded per chat, default sound, its own badge (a number): ${JSON.stringify(m)}`);
        assert(!('android' in m), `${x.name}: no android block: ${JSON.stringify(m)}`);
        const raw = JSON.stringify(m);
        assert(!/content[-_]available/i.test(raw), `${x.name}: not a silent push: ${raw}`);
      }
      // The preview each iPhone's member chose is what the alert shows.
      assert(JSON.stringify(messageTo(p.iosfull).notification).includes(text), 'full preview shows the text');
      for (const x of [p.iossender, p.iosnone]) {
        assert(!JSON.stringify(messageTo(x).notification).includes(text),
          `${x.name}: the text stays off the lock screen: ${JSON.stringify(messageTo(x).notification)}`);
      }
      assert(!JSON.stringify(messageTo(p.iosnone).notification).includes(sender.name),
        `preview none: not even who wrote: ${JSON.stringify(messageTo(p.iosnone).notification)}`);

      // The webhook repeated: already claimed, nothing goes out again.
      const again = messageId;
      assertEquals(await deliver(again), { status: 204, text: '' });
      assertEquals(sent.length, 0, `a repeated call sends nothing: ${JSON.stringify(sent)}`);

      // A message older than two minutes (a webhook retried late) goes to nobody.
      const [{ id: staleId }] = await send(`${text} stale`);
      await sql`update public.messages set created_at = now() - interval '3 minutes' where id = ${staleId}`;
      assertEquals(await deliver(staleId), { status: 204, text: '' });
      assertEquals(sent.length, 0, `an old message sends nothing: ${JSON.stringify(sent)}`);
    } finally {
      await sql.begin(async (tx) => {
        await tx`delete from app_private.tag_finds where finder in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((x) => x.email))}`;
      }).catch(() => {});
    }
  },
});

// 0.30.6, the seam from server to phone. test/fixtures/push/
// android_data_payloads.json is the data map an Android phone that shows
// pushes itself is sent, per case, with the ids replaced by placeholders.
// Here the REAL function's output must equal it; the Dart side
// (test/features/notifications/group_push_display_test.dart) feeds the same
// file through the real background handler. Change either side alone and
// one of the two goes red.
Deno.test({
  name: 'seam: what an Android phone is sent for a group (full, sender, none) and a 1:1 equals the shared fixture',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const fixture = JSON.parse(
      await Deno.readTextFile(new URL('../fixtures/push/android_data_payloads.json', import.meta.url)),
    ) as Record<string, Record<string, string>>;
    const run = Date.now().toString(36);
    const who = ['ann', 'gfull', 'gsender', 'gnone', 'dfull'];
    const people = who.map((w) => ({
      id: crypto.randomUUID(),
      session: crypto.randomUUID(),
      email: `seam-${w}-${run}@edge.test`,
      name: w === 'ann' ? 'Ann Sender' : w,
      token: `edge-seam-${w}-${run}`.padEnd(16, '0'),
    }));
    const p = Object.fromEntries(who.map((w, i) => [w, people[i]]));
    const asP = <T>(x: typeof p.ann, body: (tx: postgres.TransactionSql) => Promise<T>) =>
      as(x.id, x.email, x.session, body);
    try {
      for (const x of people) {
        await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values (${x.id}, ${x.email}, now(), ${sql.json({ full_name: x.name })})`;
        await sql`insert into app_private.allowlist(email) values (${x.email})`;
        await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                  values (${x.session}, ${x.id}, now(), now())`;
        await asP(x, (tx) => tx`select public.activate_session()`);
        if (x !== p.ann) {
          await asP(x, (tx) => tx`select public.register_device_token(${x.token}, 'android', true)`);
        }
      }
      await asP(p.gsender, (tx) => tx`insert into public.notification_settings(preview) values ('sender')`);
      await asP(p.gnone, (tx) => tx`insert into public.notification_settings(preview) values ('none')`);
      await sql`insert into app_private.tag_finds(finder, found_id)
                select ${p.ann.id}::uuid, unnest(${people.slice(1).map((r) => r.id)}::uuid[])`;
      const [{ id: group }] = await asP(p.ann, (tx) =>
        tx`select public.start_group_conversation('Edge Team', ${[p.gfull.id, p.gsender.id, p.gnone.id]}::uuid[]) as id`);
      const [{ id: direct }] = await asP(p.ann, (tx) =>
        tx`select public.start_direct_conversation(${p.dfull.id}) as id`);
      const send = async (conversation: string, body: string) => {
        const [{ id }] = await asP(p.ann, (tx) =>
          tx`insert into public.messages(conversation_id, sender_id, body)
             values (${conversation}, ${p.ann.id}, ${body}) returning id`);
        assertEquals(await deliver(id), { status: 204, text: '' });
        return { id: id as string, sent: [...sent] };
      };
      // The ids are the only run-specific values: put the placeholders back.
      const placeholders = (m: Record<string, unknown>, ids: Record<string, string>) => {
        const data = { ...(m.data as Record<string, string>) };
        for (const [k, v] of Object.entries(ids)) {
          assertEquals(data[k], v, `data.${k}`);
          data[k] = `<${k.replace('_id', '')}>`;
        }
        return data;
      };
      const g = await send(group, 'edge seam hello');
      const d = await send(direct, 'edge direct hello');
      const onlyTo = (sends: Sent[], x: typeof p.ann) => {
        const mine = sends.filter((s) => s.message.token === x.token);
        assertEquals(mine.length, 1, `exactly one send to ${x.email}`);
        const m = mine[0].message;
        assertEquals(Object.keys(m).sort(), ['android', 'data', 'token'], `data only: ${JSON.stringify(m)}`);
        return m;
      };
      const ids = (x: typeof p.ann, conversation: string, message: string) =>
        ({ conversation_id: conversation, user_id: x.id, message_id: message });
      assertEquals(placeholders(onlyTo(g.sent, p.gfull), ids(p.gfull, group, g.id)), fixture.group_full,
        'group, preview full');
      assertEquals(placeholders(onlyTo(g.sent, p.gsender), ids(p.gsender, group, g.id)), fixture.group_sender,
        'group, preview sender');
      assertEquals(placeholders(onlyTo(g.sent, p.gnone), ids(p.gnone, group, g.id)), fixture.group_none,
        'group, preview none: no sender, no chat');
      const direct1 = placeholders(onlyTo(d.sent, p.dfull), ids(p.dfull, direct, d.id));
      assertEquals(direct1, fixture.direct_full, '1:1: the five keys it always had, plus the badge');
      // As before 0.30.6, plus only 0.30.8's badge: no sender, no chat.
      assertEquals(Object.keys(direct1).sort(), ['badge', 'body', 'conversation_id', 'message_id', 'title', 'user_id']);
    } finally {
      await sql.begin(async (tx) => {
        await tx`delete from app_private.tag_finds where finder in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((x) => x.email))}`;
      }).catch(() => {});
    }
  },
});

// The contract's group test is `chat != null && sender != null`: a row with
// neither column at all (the old schema) is not a group, and every shape
// falls back to the server's title/body exactly as before 0.30.6.
Deno.test({
  name: 'old schema: rows without sender/chat send the pre-0.30.6 shapes on Android and iOS',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = Date.now().toString(36);
    const who = ['ann', 'droidnew', 'droidold', 'iphone'];
    const people = who.map((w) => ({
      id: crypto.randomUUID(),
      session: crypto.randomUUID(),
      email: `old-${w}-${run}@edge.test`,
      name: `Old ${w}`,
      token: `edge-old-${w}-${run}`.padEnd(16, '0'),
    }));
    const p = Object.fromEntries(who.map((w, i) => [w, people[i]]));
    const asP = <T>(x: typeof p.ann, body: (tx: postgres.TransactionSql) => Promise<T>) =>
      as(x.id, x.email, x.session, body);
    try {
      for (const x of people) {
        await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values (${x.id}, ${x.email}, now(), ${sql.json({ full_name: x.name })})`;
        await sql`insert into app_private.allowlist(email) values (${x.email})`;
        await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                  values (${x.session}, ${x.id}, now(), now())`;
        await asP(x, (tx) => tx`select public.activate_session()`);
      }
      const register = (x: typeof p.ann, platform: string, showsItself: boolean) =>
        asP(x, (tx) => tx`select public.register_device_token(${x.token}, ${platform}, ${showsItself})`);
      await register(p.droidnew, 'android', true);
      await register(p.droidold, 'android', false);
      await register(p.iphone, 'ios', false);
      await sql`insert into app_private.tag_finds(finder, found_id)
                select ${p.ann.id}::uuid, unnest(${people.slice(1).map((r) => r.id)}::uuid[])`;
      const [{ id: group }] = await asP(p.ann, (tx) =>
        tx`select public.start_group_conversation(${`old-${run}`}, ${people.slice(1).map((r) => r.id)}::uuid[]) as id`);
      const [{ id: messageId }] = await asP(p.ann, (tx) =>
        tx`insert into public.messages(conversation_id, sender_id, body)
           values (${group}, ${p.ann.id}, 'old schema hello') returning id`);
      const expected = await sql`select token, title, body
                                   from app_private.push_targets_for_message(${messageId})`;
      const t = (x: typeof p.ann) => expected.find((r) => r.token === x.token)!;

      oldSchema = true;
      try {
        assertEquals(await deliver(messageId), { status: 204, text: '' });
      } finally {
        oldSchema = false;
      }
      assertEquals(sent.length, 3, JSON.stringify(sent));
      const to = (x: typeof p.ann) => sent.find((s) => s.message.token === x.token)!.message;
      const data = (x: typeof p.ann) => ({
        user_id: x.id,
        message_id: messageId,
        conversation_id: group,
        title: t(x).title,
        body: t(x).body,
      });
      assertEquals(to(p.droidnew), { token: p.droidnew.token, data: data(p.droidnew), android: { priority: 'high' } });
      assertEquals(to(p.droidold), {
        token: p.droidold.token,
        notification: { title: t(p.droidold).title, body: t(p.droidold).body },
        data: data(p.droidold),
        android: { priority: 'high' },
      });
      assertEquals(to(p.iphone).notification, { title: t(p.iphone).title, body: t(p.iphone).body },
        `iPhone: the server's own wording, not a group rewording: ${JSON.stringify(to(p.iphone))}`);
      assertEquals(to(p.iphone).data, data(p.iphone));
    } finally {
      await sql.begin(async (tx) => {
        await tx`delete from app_private.tag_finds where finder in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((x) => x.email))}`;
      }).catch(() => {});
    }
  },
});

// 0.30.8: the badge is the recipient's own unread total. Here the two
// recipients and the sender all have different totals before the message
// (Cat sent Bob and Ann three messages elsewhere), so a function that sends
// one shared number, the sender's, or none at all fails here.
Deno.test({
  name: 'badge: each recipient gets their own unread total, not the sender\'s and not each other\'s',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = Date.now().toString(36);
    const who = ['ann', 'bob', 'cat'];
    const people = who.map((w) => ({
      id: crypto.randomUUID(),
      session: crypto.randomUUID(),
      email: `badge-${w}-${run}@edge.test`,
      name: `Badge ${w}`,
      token: `edge-badge-${w}-${run}`.padEnd(16, '0'),
    }));
    const p = Object.fromEntries(who.map((w, i) => [w, people[i]]));
    const asP = <T>(x: typeof p.ann, body: (tx: postgres.TransactionSql) => Promise<T>) =>
      as(x.id, x.email, x.session, body);
    try {
      for (const x of people) {
        await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                  values (${x.id}, ${x.email}, now(), ${sql.json({ full_name: x.name })})`;
        await sql`insert into app_private.allowlist(email) values (${x.email})`;
        await sql`insert into auth.sessions (id, user_id, created_at, updated_at)
                  values (${x.session}, ${x.id}, now(), now())`;
        await asP(x, (tx) => tx`select public.activate_session()`);
      }
      await asP(p.bob, (tx) => tx`select public.register_device_token(${p.bob.token}, 'android', true)`);
      await asP(p.cat, (tx) => tx`select public.register_device_token(${p.cat.token}, 'ios', false)`);
      await sql`insert into app_private.tag_finds(finder, found_id)
                values (${p.ann.id}, ${p.bob.id}), (${p.ann.id}, ${p.cat.id}),
                       (${p.cat.id}, ${p.ann.id}), (${p.cat.id}, ${p.bob.id})`;
      // Before the message: Bob and Ann each have three unread from Cat, Cat none.
      const [{ id: other }] = await asP(p.cat, (tx) =>
        tx`select public.start_group_conversation(${`badge-other-${run}`}, ${[p.ann.id, p.bob.id]}::uuid[]) as id`);
      for (let i = 0; i < 3; i++) {
        await asP(p.cat, (tx) => tx`insert into public.messages(conversation_id, sender_id, body)
                                     values (${other}, ${p.cat.id}, ${`earlier ${i}`})`);
      }
      const [{ id: group }] = await asP(p.ann, (tx) =>
        tx`select public.start_group_conversation(${`badge-${run}`}, ${[p.bob.id, p.cat.id]}::uuid[]) as id`);
      const [{ id: messageId }] = await asP(p.ann, (tx) =>
        tx`insert into public.messages(conversation_id, sender_id, body)
           values (${group}, ${p.ann.id}, 'badge hello') returning id`);
      const bob = await unreadOf(p.bob.id);
      const cat = await unreadOf(p.cat.id);
      const ann = await unreadOf(p.ann.id);
      // The fixture itself: three different totals, else the test proves nothing.
      assert(bob > 0 && cat > 0, `both recipients have unread: bob ${bob}, cat ${cat}`);
      assert(bob !== cat && bob !== ann && cat !== ann, `distinct totals: bob ${bob}, cat ${cat}, ann ${ann}`);
      // Each recipient reads the same count back through the app's own call.
      assertEquals((await asP(p.bob, (tx) => tx`select public.unread_total()::int as n`))[0].n, bob);
      assertEquals((await asP(p.cat, (tx) => tx`select public.unread_total()::int as n`))[0].n, cat);

      assertEquals(await deliver(messageId), { status: 204, text: '' });
      assertEquals(sent.length, 2, JSON.stringify(sent));
      // deno-lint-ignore no-explicit-any
      const to = (x: typeof p.ann) => sent.find((s) => s.message.token === x.token)!.message as any;
      assertEquals(to(p.bob).data?.badge, String(bob), `Bob: his own total, a string: ${JSON.stringify(to(p.bob))}`);
      assertEquals(to(p.cat).data?.badge, String(cat), `Cat: her own total, a string: ${JSON.stringify(to(p.cat))}`);
      const aps = to(p.cat).apns?.payload?.aps;
      assertEquals(aps?.badge, cat, `Cat's iPhone: the icon badge is her own total, a number: ${JSON.stringify(aps)}`);
    } finally {
      await sql.begin(async (tx) => {
        await tx`delete from app_private.tag_finds where finder in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.device_tokens where user_id in ${sql(people.map((x) => x.id))}`;
        await tx`delete from app_private.allowlist where email in ${sql(people.map((x) => x.email))}`;
      }).catch(() => {});
    }
  },
});

Deno.test({
  name: 'close the database connection',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: () => sql.end(),
});
