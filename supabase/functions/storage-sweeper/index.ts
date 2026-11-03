import { createClient } from 'jsr:@supabase/supabase-js@2';

/**
 * Removes queued files from Storage (rule 19 / delete rules). Called by pg_cron through pg_net every 10 minutes. Deployed with --no-verify-jwt: the shared secret in the header is the credential. Never callable by users. A path a live message still uses is skipped by the database (public.sweeper_claim), never removed here.
 */
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const secret = Deno.env.get('STORAGE_SWEEPER_SECRET');
  const headerSecret = req.headers.get('x-sweeper-secret');
  if (!secret || !headerSecret || headerSecret.length !== secret.length) {
    return reply(401, { error: 'unauthorized' });
  }

  // Constant-time compare to prevent timing attacks
  const encoder = new TextEncoder();
  const a = encoder.encode(secret);
  const b = encoder.encode(headerSecret);
  let diff = a.length ^ b.length;
  for (let i = 0; i < a.length; i++) { diff |= a[i] ^ (b[i] ?? 0); }
  if (diff !== 0) return reply(401, { error: 'unauthorized' });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  let totalRemoved = 0;
  let totalFailed = 0;

  for (let round = 0; round < 5; round++) {
    const { data, error } = await db.rpc('sweeper_claim', { batch: 100 });
    if (error) return reply(500, { error: 'claim' });
    if (!data || data.length === 0) break;

    const byBucket = new Map<string, { id: number; path: string }[]>();
    for (const row of data as { id: number; bucket: string; path: string }[]) {
      const rows = byBucket.get(row.bucket) || [];
      rows.push({ id: row.id, path: row.path });
      byBucket.set(row.bucket, rows);
    }

    let roundDone: number[] = [];
    let roundFailed = 0;

    for (const [bucket, rows] of byBucket) {
      const { error: rmErr } = await db.storage.from(bucket).remove(rows.map(r => r.path));
      if (rmErr === null) {
        roundDone = roundDone.concat(rows.map(r => r.id));
      } else {
        roundFailed += rows.length;
        console.log('storage-sweeper: remove failed');
      }
    }

    totalFailed += roundFailed;
    if (roundDone.length === 0) break;
    const { error: doneErr } = await db.rpc('sweeper_done', { ids: roundDone });
    if (doneErr) {
      console.log('storage-sweeper: done failed');
      break;
    }
    totalRemoved += roundDone.length;
  }

  return reply(200, { ok: true, removed: totalRemoved, failed: totalFailed });
});
