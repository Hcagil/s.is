// attachment-orphan-cleanup against the real local stack: real Storage API, real
// sweeper_claim / sweeper_done. Written from the contract, not the code.
//
// Contract: POST only (405). Header x-sweeper-secret must equal env
// STORAGE_SWEEPER_SECRET (401 otherwise, also when the env is unset).
// 200 {ok, removed, failed}. A path already missing counts as removed. A
// failed Storage removal leaves the row queued (attempts grows).
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway \
//     -v "$PWD":/w -w /w -e SUPABASE_TEST_SERVICE_KEY="<SECRET_KEY>" \
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/attachment_orphan_cleanup_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const secret = 'qa-orphan-' + crypto.randomUUID();
Deno.env.set('SUPABASE_URL', apiUrl);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', serviceKey);
Deno.env.set('STORAGE_SWEEPER_SECRET', secret);

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
await import('../../supabase/functions/storage-sweeper/index.ts');
const handler = handlers.at(-1)!;

const sql = postgres(dbUrl, { max: 1, onnotice: () => {} });

async function call(opts: { method?: string; secret?: string | null } = {}) {
  const headers: Record<string, string> = {};
  const s = opts.secret === undefined ? secret : opts.secret;
  if (s !== null) headers['x-sweeper-secret'] = s;
  const res = await handler(new Request(`${apiUrl}/functions/v1/storage-sweeper`, {
    method: opts.method ?? 'POST', headers,
  }));
  return { status: res.status, text: await res.text() };
}

const auth = { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
const dir = 'qa-orphan-' + crypto.randomUUID();
const objectUrl = (path: string) => `${apiUrl}/storage/v1/object/attachments/${path}`;
async function upload(path: string) {
  const res = await fetch(objectUrl(path), {
    method: 'POST', headers: { ...auth, 'content-type': 'image/jpeg' }, body: new Uint8Array([1, 2, 3]),
  });
  assertEquals(res.status, 200, `upload ${path}: ${await res.text()}`);
}
async function objectStatus(path: string) {
  const res = await fetch(objectUrl(path), { headers: auth });
  await res.body?.cancel();
  return res.status;
}
const queued = async () =>
  [...await sql`select bucket, path, attempts from app_private.storage_removal_queue order by id`] as
    { bucket: string; path: string; attempts: number }[];

Deno.test({
  name: 'orphan cleanup queues and the sweeper removes through real Storage',
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const uid = crypto.randomUUID();
    const cid = crypto.randomUUID();
    try {
      // 1. upload objects
      const orphan = `${dir}/orph.jpg`;
      const orphanT = `${dir}/orph.jpg.t`;
      const kept = `${dir}/kept.jpg`;
      const keptS = `${dir}/kept.jpg.s`;
      const fresh = `${dir}/fresh.jpg`;
      await upload(orphan);
      await upload(orphanT);
      await upload(kept);
      await upload(keptS);
      await upload(fresh);

      // backdate old objects
      await sql`update storage.objects set created_at = now() - interval '40 days'
                where bucket_id = 'attachments' and name in (${orphan}, ${orphanT}, ${kept}, ${keptS})`;

      // create user, conversation, member, message
      await sql`insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
                values (${uid}, 'qa-orphan-'||${dir}||'@sis.test', now(), '{}'::jsonb)`;
      await sql`insert into public.conversations(id, title) values (${cid}, 'qa-orphan')`;
      await sql`insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from)
                values (${cid}, ${uid}, 'member', now() - interval '200 days', '-infinity')`;
      await sql`insert into public.messages(conversation_id, sender_id, body, attachment_path)
                values (${cid}, ${uid}, '', ${kept})`;

      // 2. queue orphan attachments
      await sql`delete from app_private.storage_removal_queue`;
      const n = (await sql`select app_private.queue_orphan_attachments(1000) as n`)[0].n;
      const queuedRows = (await queued()).filter((r) => r.path.startsWith(dir + '/'));
      const paths = queuedRows.map(r => r.path);
      assertEquals(paths.sort(), [orphan, orphanT].sort(), 'only orphan paths queued');
      assert(n >= 2, 'queue_orphan_attachments returned at least 2');

      // 3. run sweeper
      const ok = await call();
      assertEquals(ok.status, 200, ok.text);
      const body = JSON.parse(ok.text);
      assertEquals([body.ok, body.failed], [true, 0], ok.text);
      assert(body.removed >= 2, ok.text);
      assert((await objectStatus(orphan)) >= 400, 'orphan removed');
      assert((await objectStatus(orphanT)) >= 400, 'orphanT removed');
      assertEquals(await objectStatus(kept), 200, 'kept still exists');
      assertEquals(await objectStatus(keptS), 200, 'keptS still exists');
      assertEquals(await objectStatus(fresh), 200, 'fresh still exists');
      assertEquals((await queued()).filter((r) => r.path.startsWith(dir + '/')).length, 0, 'queue empty after sweep');

      // 4. late message scenario
      const latePath = `${dir}/late.jpg`;
      await upload(latePath);
      await sql`update storage.objects set created_at = now() - interval '40 days'
                where bucket_id = 'attachments' and name = ${latePath}`;
      await sql`delete from app_private.storage_removal_queue`;
      const n2 = (await sql`select app_private.queue_orphan_attachments(1000) as n`)[0].n;
      const queuedRows2 = (await queued()).filter((r) => r.path.startsWith(dir + '/'));
      assertEquals(queuedRows2.map(r => r.path), [latePath], 'latePath queued');
      await sql`insert into public.messages(conversation_id, sender_id, body, attachment_path)
                values (${cid}, ${uid}, '', ${latePath})`;
      const ok2 = await call();
      assertEquals(ok2.status, 200, ok2.text);
      const body2 = JSON.parse(ok2.text);
      assertEquals(body2.failed, 0, 'no failures');
      assertEquals(await objectStatus(latePath), 200, 'latePath kept');
      assertEquals((await queued()).filter((r) => r.path.startsWith(dir + '/')).length, 0, 'queue empty after late message');

    } finally {
      // cleanup
      await sql`delete from app_private.storage_removal_queue where path like ${dir + '/%'}`;
      await sql`delete from public.messages where conversation_id = ${cid}`;
      await sql`delete from public.conversation_members where conversation_id = ${cid}`;
      await sql`delete from public.conversations where id = ${cid}`;
      await sql`delete from auth.users where id = ${uid}`;
      // best-effort delete remaining objects
      const paths = [`${dir}/orph.jpg`, `${dir}/orph.jpg.t`, `${dir}/kept.jpg`, `${dir}/kept.jpg.s`, `${dir}/fresh.jpg`, `${dir}/late.jpg`];
      for (const p of paths) {
        await fetch(objectUrl(p), { method: 'DELETE', headers: auth }).catch(() => {});
      }
      await sql.end();
    }
  },
});
