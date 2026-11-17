import { createClient } from 'jsr:@supabase/supabase-js@2';

/**
 * Removes accounts whose 29-day wait is over; called hourly by pg_cron through pg_net; deployed with --no-verify-jwt, the shared secret is the credential; never callable by users; never logs ids, emails or secrets.
 */
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const secret = Deno.env.get('ACCOUNT_DELETION_SECRET');
  const headerSecret = req.headers.get('x-deletion-secret');
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

  let removed = 0;
  let failed = 0;
  let skipped = 0;

  for (let round = 0; round < 5; round++) {
    const { data, error } = await db.rpc('account_deletion_claim', { batch: 10 });
    if (error) return reply(500, { error: 'claim' });
    if (!data || data.length === 0) break;

    for (const row of data as { user_id: string; request_id: string }[]) {
      const { data: ok, error: prepErr } = await db.rpc('account_deletion_prepare', { uid: row.user_id });
      if (prepErr) { failed++; continue; }
      if (ok !== true) { skipped++; continue; }

      const { error: delErr } = await db.auth.admin.deleteUser(row.user_id);
      if (delErr && delErr.status !== 404) {
        failed++;
        console.log('account-deletion: delete failed');
        continue;
      }

      const { error: doneErr } = await db.rpc('account_deletion_done', { rid: row.request_id });
      if (doneErr) {
        console.log('account-deletion: done failed');
      }
      removed++;
    }
  }

  return reply(200, { ok: true, removed, failed, skipped });
});
