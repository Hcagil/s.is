// podium_handle's rate limit (30 commands per user per 10 minutes) holds under
// parallel calls by one user: each call takes a per-user transaction advisory
// lock before it counts, so a second call waits for the first to commit and
// then sees its audit row. Needs two live sessions, so it is not a pgTAP file.
//
// Run (the local stack must be up):
//   docker run --rm --add-host host.docker.internal:host-gateway -v "$PWD":/w -w /w \
//     -e SUPABASE_TEST_SERVICE_KEY=x denoland/deno:2.9.7 test --no-check --no-lock --allow-all test/edge/podium_rate_lock_test.ts
import postgres from 'npm:postgres@3.4.5';
import { assert, assertEquals } from 'jsr:@std/assert@1';

const dbUrl = Deno.env.get('SUPABASE_TEST_DB_URL') ??
  'postgresql://postgres:postgres@host.docker.internal:54322/postgres';
const sql = postgres(dbUrl, { max: 20, onnotice: () => {} });
const opts = { sanitizeOps: false, sanitizeResources: false };

const uid = crypto.randomUUID();
const other = crypto.randomUUID();
await sql`insert into auth.users (id, email, email_confirmed_at) values
  (${uid}, ${'qa-lock-' + uid.slice(0, 8) + '@mail.test'}, now()),
  (${other}, ${'qa-lock-' + other.slice(0, 8) + '@mail.test'}, now())`;
const [{ id: conv }] = await sql`insert into public.conversations(system, admin_chat, bacanaks_chat)
  values (true, true, true) returning id::text`;
const [saved] = await sql`select amount, day, fetched_at, fail_count, off from app_private.podium_state`;

// A fresh cached answer, so an accepted ask is answered from the cache (no job, no Vega).
async function prepare(used: number, user = uid) {
  await sql`delete from app_private.podium_commands where user_id in (${uid}, ${other})`;
  await sql`delete from public.messages where conversation_id = ${conv}`;
  await sql`update app_private.podium_state set amount = '1', day = app_private.podium_business_day(now()),
              fetched_at = now(), fail_count = 0, off = false`;
  await sql`insert into app_private.podium_commands(user_id, at, command, outcome)
    select ${user}, now() - interval '5 minutes', '/podium', 'cache' from generate_series(1, ${used}::int)`;
}
const replies = async () =>
  (await sql`select admin_msg->>'k' as k from public.messages where conversation_id = ${conv}`).map((r) => r.k as string);
const refused = (ks: string[]) => ks.filter((k) => k === 'podRate').length;

Deno.test({ ...opts, name: 'fixture: one call under the limit is answered, one over it is refused', fn: async () => {
  await prepare(30);
  await sql`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`;
  assertEquals(await replies(), ['podRate']);
  await prepare(29);
  await sql`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`;
  const ks = await replies();
  assertEquals([ks.length, refused(ks)], [1, 0], `got ${ks}`);
} });

Deno.test({ ...opts, name: 'a second call by the same user waits for the first to commit, then sees it and is refused (29 used)', fn: async () => {
  await prepare(29);
  const a = await sql.reserve();
  const b = await sql.reserve();
  try {
    await a`begin`;
    await a`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`;
    await b`begin`;
    let bDone = false;
    const bCall = b`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`.then((r) => {
      bDone = true;
      return r;
    });
    await new Promise((r) => setTimeout(r, 700));
    assert(!bDone, 'the second call did not wait for the first one\'s transaction');
    const [{ n }] = await sql`select count(*)::int as n from pg_locks where locktype = 'advisory' and not granted`;
    assert(n >= 1, 'the second call waits on an advisory lock');
    await a`commit`;
    await bCall;
    await b`commit`;
  } finally {
    await a`rollback`.catch(() => {});
    await b`rollback`.catch(() => {});
    a.release();
    b.release();
  }
  const ks = await replies();
  assertEquals([ks.length, refused(ks)], [2, 1], `the 30th is answered, the 31st refused; got ${ks}`);
} });

// Other users may still queue on shared rows (the cache row); the contract is
// only that the advisory lock is keyed per user.
Deno.test({ ...opts, name: 'the advisory lock is per user: another user\'s call never waits on it', fn: async () => {
  await prepare(0);
  const a = await sql.reserve();
  const b = await sql.reserve();
  let bCall: Promise<void> = Promise.resolve();
  try {
    await a`begin`;
    await a`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`;
    const [{ pid }] = await b`select pg_backend_pid() as pid`;
    bCall = b`select app_private.podium_handle(${conv}::uuid, ${other}::uuid, '/podium')`.then(() => {});
    await new Promise((r) => setTimeout(r, 700));
    const waits = await sql`select locktype from pg_locks where pid = ${pid} and not granted`;
    assertEquals(waits.filter((w) => w.locktype === 'advisory').length, 0, 'another user waits on the first user\'s advisory lock');
    await a`commit`;
    await bCall;
  } finally {
    await a`rollback`.catch(() => {});
    await bCall.catch(() => {}); // a failed run must not leave a reply behind for the next test
    a.release();
    b.release();
  }
} });

Deno.test({ ...opts, name: 'a burst of 12 parallel calls with 25 used: exactly 5 answered, 7 refused', fn: async () => {
  await prepare(25);
  await Promise.all(Array.from({ length: 12 }, () => sql`select app_private.podium_handle(${conv}::uuid, ${uid}::uuid, '/podium')`));
  const ks = await replies();
  assertEquals([ks.length, refused(ks)], [12, 7], `got ${ks}`);
} });

Deno.test({ ...opts, name: 'teardown', fn: async () => {
  try {
    await sql`delete from public.conversations where id = ${conv}`;
    await sql`delete from auth.users where id in (${uid}, ${other})`;
    await sql`update app_private.podium_state set amount = ${saved.amount}, day = ${saved.day}, fetched_at = ${saved.fetched_at},
                fail_count = ${saved.fail_count}, off = ${saved.off}`;
  } finally {
    await sql.end();
  }
} });
