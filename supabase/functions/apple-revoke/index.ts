import { createClient } from 'jsr:@supabase/supabase-js@2';

/**
 * Revokes the person's Sign in with Apple access at Apple, then records it with the database; called by the app right before request_account_deletion; if anything fails the deletion must be refused, so every failure is a non-200; never logs tokens, codes, keys or ids.
 * Request: POST JSON { authorization_code }. Deployed WITH JWT verification; the user is identified from the bearer token.
 */
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const base64url = (bytes: Uint8Array): string => {
  let binary = '';
  for (const byte of bytes) { binary += String.fromCharCode(byte); }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

const pemToDer = (pem: string): Uint8Array => {
  const b64 = pem
    .replace(/-----(BEGIN|END) [A-Z ]+-----/g, '')
    .replace(/\\n/g, '')
    .replace(/\s/g, '');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
  return bytes;
};

/** The `sub` claim of an id_token (the payload part only; no signature check, see the caller), or null when it cannot be read. */
const idTokenSub = (jwt: string): string | null => {
  try {
    const part = jwt.split('.')[1] ?? '';
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '='));
    const sub = JSON.parse(json).sub;
    return typeof sub === 'string' && sub !== '' ? sub : null;
  } catch {
    return null;
  }
};

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const raw = await req.text();
  if (raw.length > 4000) return reply(400, { error: 'bad_request' });

  let body: { authorization_code?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return reply(400, { error: 'bad_request' });
  }

  const authorizationCode = body.authorization_code;
  if (typeof authorizationCode !== 'string' || authorizationCode.length === 0) {
    return reply(400, { error: 'bad_request' });
  }

  const APPLE_TEAM_ID = Deno.env.get('APPLE_TEAM_ID');
  const APPLE_KEY_ID = Deno.env.get('APPLE_KEY_ID');
  const APPLE_PRIVATE_KEY = Deno.env.get('APPLE_PRIVATE_KEY');
  const APPLE_CLIENT_ID = Deno.env.get('APPLE_CLIENT_ID');

  // a missing secret refuses the deletion (owner decision: Apple's rule is always met)
  if (!APPLE_TEAM_ID || !APPLE_KEY_ID || !APPLE_PRIVATE_KEY || !APPLE_CLIENT_ID) {
    return reply(500, { error: 'not_configured' });
  }

  const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!jwt) return reply(401, { error: 'unauthorized' });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: u, error } = await db.auth.getUser(jwt);
  if (error || !u.user) return reply(401, { error: 'unauthorized' });
  if (!u.user.identities?.some((i) => i.provider === 'apple')) {
    return reply(400, { error: 'bad_request' });
  }

  let clientSecret: string;
  try {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: 'ES256', kid: APPLE_KEY_ID, typ: 'JWT' };
    const payload = { iss: APPLE_TEAM_ID, iat: now, exp: now + 300, aud: 'https://appleid.apple.com', sub: APPLE_CLIENT_ID };
    const headerB64 = base64url(new TextEncoder().encode(JSON.stringify(header)));
    const payloadB64 = base64url(new TextEncoder().encode(JSON.stringify(payload)));
    const signingInput = `${headerB64}.${payloadB64}`;

    const cryptoKey = await crypto.subtle.importKey(
      'pkcs8',
      pemToDer(APPLE_PRIVATE_KEY),
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign']
    );
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      cryptoKey,
      new TextEncoder().encode(signingInput)
    );
    clientSecret = `${signingInput}.${base64url(new Uint8Array(signature))}`;
  } catch {
    return reply(500, { error: 'not_configured' });
  }

  let refreshToken: string;
  try {
    const tokenRes = await fetch('https://appleid.apple.com/auth/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: APPLE_CLIENT_ID,
        client_secret: clientSecret,
        code: authorizationCode,
        grant_type: 'authorization_code',
      }).toString(),
      signal: AbortSignal.timeout(8000),
    });
    if (!tokenRes.ok) throw new Error('apple_failed');
    const tokenJson = await tokenRes.json();
    if (typeof tokenJson.refresh_token !== 'string') throw new Error('apple_failed');
    // The code must belong to the caller's own Apple account. The id_token comes straight from Apple over TLS in this very call, so its signature needs no check here: only whose account it names. A missing id_token or a different `sub` refuses the request before anything is revoked or marked.
    if (typeof tokenJson.id_token !== 'string') throw new Error('apple_failed');
    const sub = idTokenSub(tokenJson.id_token);
    const own = sub !== null && (u.user.identities ?? []).some(
      (i) => i.provider === 'apple' && (i.identity_data?.sub === sub || i.id === sub),
    );
    if (!own) throw new Error('apple_failed');
    refreshToken = tokenJson.refresh_token;
  } catch {
    console.log('apple-revoke: token request failed');
    return reply(502, { error: 'apple_failed' });
  }

  try {
    const revokeRes = await fetch('https://appleid.apple.com/auth/revoke', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: APPLE_CLIENT_ID,
        client_secret: clientSecret,
        token: refreshToken,
        token_type_hint: 'refresh_token',
      }).toString(),
      signal: AbortSignal.timeout(8000),
    });
    if (!revokeRes.ok) throw new Error('apple_failed');
  } catch {
    console.log('apple-revoke: revoke request failed');
    return reply(502, { error: 'apple_failed' });
  }

  const { error: markErr } = await db.rpc('mark_apple_revoked', { uid: u.user.id });
  if (markErr) {
    console.log('apple-revoke: mark failed');
    return reply(502, { error: 'apple_failed' });
  }

  return reply(200, { ok: true });
});
