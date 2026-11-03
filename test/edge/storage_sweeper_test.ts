// storage-sweeper against the real local stack: real Storage API, real
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
//     denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/storage_sweeper_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const apiUrl = Deno.env.get('SUPABASE_TEST_URL') ?? 'http://host.docker.internal:54321';
const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const serviceKey = Deno.env.get('SUPABASE_TEST_SERVICE_KEY') ?? '';
if (!serviceKey) throw new Error('SUPABASE_TEST_SERVICE_KEY is not set (the stack\'s SECRET_KEY)');
const secret = 'qa-sweeper-' + crypto.randomUUID();
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
const dir = 'qa-sweeper-' + crypto.randomUUID();
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
  name: 'storage-sweeper removes queued objects from real Storage',
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    try {
      await sql`delete from app_private.storage_removal_queue`;
      const real = `${dir}/real.jpg`;
      const missing = `${dir}/missing.jpg`;
      await upload(real);
      assertEquals(await objectStatus(real), 200, 'the uploaded object is readable');
      await sql`insert into app_private.storage_removal_queue(bucket, path)
                values ('attachments', ${real}), ('attachments', ${missing})`;

      // refused calls change nothing
      assertEquals((await call({ secret: null })).status, 401, 'no secret header');
      assertEquals((await call({ secret: 'wrong' })).status, 401, 'wrong secret');
      assertEquals((await call({ secret: '' })).status, 401, 'empty secret');
      const sameLength = secret.slice(0, -1) + (secret.endsWith('x') ? 'y' : 'x');
      assertEquals((await call({ secret: sameLength })).status, 401, 'wrong secret of the right length');
      assertEquals((await call({ method: 'GET' })).status, 405, 'GET');
      Deno.env.delete('STORAGE_SWEEPER_SECRET');
      try {
        assertEquals((await call({ secret: '' })).status, 401, 'env unset, empty header');
        assertEquals((await call({ secret: 'undefined' })).status, 401, 'env unset, "undefined" header');
      } finally {
        Deno.env.set('STORAGE_SWEEPER_SECRET', secret);
      }
      assertEquals((await queued()).length, 2, 'refused calls leave the queue');
      assertEquals(await objectStatus(real), 200, 'refused calls leave the object');

      // the right secret removes the real object; the missing one counts as removed
      const ok = await call();
      assertEquals(ok.status, 200, ok.text);
      const body = JSON.parse(ok.text);
      assertEquals([body.ok, body.removed, body.failed], [true, 2, 0], ok.text);
      assert((await objectStatus(real)) >= 400, 'object gone from Storage');
      assertEquals((await queued()).length, 0, 'queue empty after');

      // nothing left: a second call removes nothing
      const again = JSON.parse((await call()).text);
      assertEquals([again.removed, again.failed], [0, 0], 'second call is a no-op');

      // Storage refuses the removal: the row stays queued with more attempts. A real Storage
      // error is hard to provoke, so the database calls go through to the real stack and
      // only /storage/ answers 500.
      const proxy = realServe({ hostname: '127.0.0.1', port: 0, onListen: () => {} }, async (req) => {
        const u = new URL(req.url);
        if (u.pathname.startsWith('/storage/')) {
          await req.body?.cancel();
          return Response.json({ statusCode: '500', error: 'qa', message: 'qa storage down' }, { status: 500 });
        }
        return fetch(apiUrl + u.pathname + u.search, {
          method: req.method, headers: req.headers, body: req.body ? await req.arrayBuffer() : undefined,
        });
      });
      const failing = `${dir}/failing.jpg`;
      await sql`insert into app_private.storage_removal_queue(bucket, path) values ('attachments', ${failing})`;
      Deno.env.set('SUPABASE_URL', `http://127.0.0.1:${proxy.addr.port}`);
      let bad;
      try {
        bad = await call();
      } finally {
        Deno.env.set('SUPABASE_URL', apiUrl);
        await proxy.shutdown();
      }
      assertEquals(bad.status, 200, bad.text);
      const badBody = JSON.parse(bad.text);
      assert(badBody.failed >= 1 && badBody.removed === 0, bad.text);
      const left = await queued();
      assertEquals(left.map((r) => r.path), [failing], 'failed row stays queued');
      assert(left[0].attempts >= 1, 'attempts grew');
    } finally {
      await sql`delete from app_private.storage_removal_queue where path like ${dir + '/%'}`;
      await sql.end();
    }
  },
});
