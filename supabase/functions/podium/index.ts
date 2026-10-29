// Fetches the Vega money total for one /podium ask.
// Called by a DB trigger (pg_net) with {"job_id": "<uuid>"} and header x-podium-secret.
//
// Deployed with --no-verify-jwt: the shared secret in the header is the credential.
// Request (POST, JSON):
//   { job_id }
// Answers { ok: true, ran: false } (200) if already taken or not pending,
// or { error: 'method' } (405) if not POST,
// or { error: 'unauthorized' } (401) if secret mismatch,
// or { error: 'bad_request' } (400) if malformed request,
// or { ok: true, ran: true, result: 'ok'|'failed' } (200) on success.
// Never logs or returns the amount, the password or Vega's reply.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { fetchVegaTotal, VegaError } from './vega.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const secret = Deno.env.get('PODIUM_SHARED_SECRET');
  const headerSecret = req.headers.get('x-podium-secret');
  if (!secret || !headerSecret || headerSecret.length !== secret.length) {
    return reply(401, { error: 'unauthorized' });
  }

  // Constant-time compare to prevent timing attacks
  const encoder = new TextEncoder();
  const a = encoder.encode(secret);
  const b = encoder.encode(headerSecret);
  let diff = a.length ^ b.length;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ (b[i] ?? 0);
  }
  if (diff !== 0) return reply(401, { error: 'unauthorized' });

  const text = await req.text().catch(() => '');
  if (text.length > 2000) return reply(400, { error: 'bad_request' });
  let q: Record<string, unknown> | null = null;
  try {
    q = JSON.parse(text);
  } catch { /* q stays null */ }
  const { job_id: jobId } = q ?? {};
  if (typeof jobId !== 'string' || !UUID.test(jobId)) {
    return reply(400, { error: 'bad_request' });
  }

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const { data: claim } = await db.rpc('podium_job_claim', { job: jobId });
  if (claim === null || claim === undefined) {
    return reply(200, { ok: true, ran: false });
  }

  let amount: string | null = null;
  let reason = 'other';
  try {
    amount = await Promise.race([
      fetchVegaTotal(claim.day, claim.prev),
      new Promise<never>((_, reject) => setTimeout(() => reject(new VegaError('timeout')), 20000))
    ]);
  } catch (e) {
    reason = e instanceof VegaError ? e.code : 'other';
    console.log('podium: fetch failed');
  }

  if (amount !== null && !/^[0-9][0-9.,' ]{0,24}$/.test(amount)) {
    amount = null;
    reason = 'shape';
  }

  await db.rpc('podium_job_finish', { job: jobId, amount, reason: amount === null ? reason : null });
  return reply(200, { ok: true, ran: true, result: amount === null ? 'failed' : 'ok' });
});
