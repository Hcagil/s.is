// Report progress of an admin job to GitHub.
//
// The workflow proves itself with GitHub's signed OIDC token instead of a secret in inputs.
// The first claim binds the job to its run id, and subsequent calls update progress.
//
// Deployed with --no-verify-jwt: the GitHub OIDC token is the credential.
// Request (POST, JSON):
//   { action: 'claim' | 'progress' | 'finish', job_id: uuid, attempt?: 2|3, ok?: boolean, reason?: string }
// Answers:
//   200 { kind: string, email: string }     for claim
//   200 { ok: true }                        for progress and finish
//   400 bad_request                          malformed request
//   403 not_permitted                        invalid or missing token
//   405 method                               not a POST
//   409 not_claimable                        job already claimed or not pending
//   500 failed                               internal error
//   502 jwks                                 JWKS fetch failed
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { type Jwks, OIDC_JWKS_URL, verifyGithubOidc } from '../_shared/github_oidc.ts';
import { unb64url } from '../_shared/action_token.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

let jwksCache: { jwks: Jwks; at: number } | null = null;
let lastRefetch = 0;
const JWKS_TTL = 10 * 60_000;
const RETRY_GAP = 60_000;

const fetchJwks = async (): Promise<Jwks | null> => {
  try {
    const res = await fetch(OIDC_JWKS_URL, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
};

// Returns the token's kid when it is three dot-separated parts with an RS256 header and a kid.
const tokenKid = (token: string): string | null => {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const h = JSON.parse(new TextDecoder().decode(unb64url(parts[0])));
    return h?.alg === 'RS256' && typeof h.kid === 'string' && h.kid ? h.kid : null;
  } catch {
    return null;
  }
};

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });
  const text = await req.text().catch(() => '');
  if (text.length > 2000) return reply(400, { error: 'bad_request' });
  let q: Record<string, unknown> | null = null;
  try {
    q = JSON.parse(text);
  } catch { /* q stays null */ }
  const { action, job_id: jobId, attempt, ok, reason } = q ?? {};
  if (
    typeof action !== 'string' ||
    (action !== 'claim' && action !== 'progress' && action !== 'finish') ||
    typeof jobId !== 'string' || !UUID.test(jobId)
  ) return reply(400, { error: 'bad_request' });

  const authHeader = req.headers.get('authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return reply(403, { error: 'not_permitted' });
  }
  const token = authHeader.substring(7);

  const kid = tokenKid(token);
  if (!kid) return reply(403, { error: 'not_permitted' });
  const now = Date.now();
  if (!jwksCache || now - jwksCache.at > JWKS_TTL) {
    const j = await fetchJwks();
    if (!j) return reply(502, { error: 'jwks' });
    jwksCache = { jwks: j, at: now };
    lastRefetch = now;
  } else if (!jwksCache.jwks.keys.some((k) => k.kid === kid) && now - lastRefetch >= RETRY_GAP) {
    lastRefetch = now;
    const j = await fetchJwks();
    if (j) jwksCache = { jwks: j, at: now };
  }
  const jwks = jwksCache.jwks;

  const expected = {
    audience: 'sis-admin-apple',
    repositoryId: Deno.env.get('GITHUB_REPOSITORY_ID') ?? '',
    workflowRef: 'Hcagil/s.is/.github/workflows/admin-apple.yml@refs/heads/main',
    ref: 'refs/heads/main',
    eventName: 'workflow_dispatch',
  };

  const verified = await verifyGithubOidc(token, jwks, expected);
  if (!verified) return reply(403, { error: 'not_permitted' });
  const runId = verified.runId;

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  try {
    if (action === 'claim') {
      const { data, error } = await db.rpc('admin_job_claim', { job: jobId, run: runId });
      if (error) {
        console.error('admin_job rpc failed', error.code);
        return reply(500, { error: 'failed' });
      }
      if (!data) return reply(409, { error: 'not_claimable' });
      return reply(200, { kind: data.kind, email: data.email });
    } else if (action === 'progress') {
      if (attempt !== 2 && attempt !== 3) return reply(400, { error: 'bad_request' });
      const { error } = await db.rpc('admin_job_progress', { job: jobId, run: runId, attempt });
      if (error) {
        console.error('admin_job rpc failed', error.code);
        return reply(500, { error: 'failed' });
      }
      return reply(200, { ok: true });
    } else if (action === 'finish') {
      if (typeof ok !== 'boolean') return reply(400, { error: 'bad_request' });
      const r = reason === 'rejected' || reason === 'dispatch' ? reason : 'timeout';
      const { error } = await db.rpc('admin_job_finish', { job: jobId, run: runId, succeeded: ok, reason: r });
      if (error) {
        console.error('admin_job rpc failed', error.code);
        return reply(500, { error: 'failed' });
      }
      return reply(200, { ok: true });
    }
    return reply(400, { error: 'bad_request' });
  } catch {
    console.error('Unexpected error in admin-apple-report');
    return reply(500, { error: 'failed' });
  }
});
