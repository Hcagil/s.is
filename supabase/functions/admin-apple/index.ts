// Dispatch an admin job to GitHub.
//
// Called by a database trigger (pg_net) with body {"job_id": "<uuid>"}.
// The first caller wins: the database decides who gets to dispatch.
// No JWT needed: the request carries only a job id, the first caller wins.
//
// Deployed with --no-verify-jwt: the database trigger is the credential.
// Request (POST, JSON):
//   { job_id }
// Answers { ok: true, dispatched: true } (200) on success,
// or { ok: true, dispatched: false } (200) if already taken or not pending,
// or { error: 'method' } (405) if not POST,
// or { error: 'bad_request' } (400) if malformed request,
// or { error: 'not_configured' } (500) if GITHUB_DISPATCH_TOKEN is missing,
// or { error: 'dispatch_failed' } (502) if all retries failed.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });
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

  const { data: taken } = await db.rpc('admin_job_dispatch', { job: jobId });
  if (taken !== true) return reply(200, { ok: true, dispatched: false });

  const token = Deno.env.get('GITHUB_DISPATCH_TOKEN');
  if (!token) {
    await db.rpc('admin_job_dispatch_failed', { job: jobId, reason: 'dispatch' });
    return reply(500, { error: 'not_configured' });
  }

  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
  for (let i = 0; i < 3; i++) {
    if (i > 0) await sleep([0, 5000, 20000][i]);
    try {
      const res = await fetch(
        'https://api.github.com/repos/Hcagil/s.is/actions/workflows/admin-apple.yml/dispatches',
        {
          method: 'POST',
          headers: {
            authorization: `Bearer ${token}`,
            accept: 'application/vnd.github+json',
            'x-github-api-version': '2022-11-28',
            'content-type': 'application/json',
            'user-agent': 'sis-admin-apple',
          },
          body: JSON.stringify({ ref: 'main', inputs: { job_id: jobId } }),
          signal: AbortSignal.timeout(10000),
        }
      );
      if (res.status === 200 || res.status === 204) {
        return reply(200, { ok: true, dispatched: true });
      }
      if (res.status === 429 || res.status >= 500) continue; // retry
      break; // stop on 401, 403, 404, 422 or any other error
    } catch {
      // network error, retry
    }
  }

  await db.rpc('admin_job_dispatch_failed', { job: jobId, reason: 'dispatch' });
  return reply(502, { error: 'dispatch_failed' });
});
