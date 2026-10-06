// The action token a push carries so its Mark as read and Reply buttons work
// on a phone that holds no Supabase session (see notification-action).
//
// Stateless and signed: `v1.<payload>.<signature>`, payload and signature
// base64url, the signature an HMAC-SHA256 over a fixed label plus the payload.
// The key is the project's service-role key, which only the edge runtime
// holds: no new secret to provision, and rotating that key voids every
// outstanding token (they live an hour at most, so that costs nothing).
//
// Claims:
//   u  the member the push was for (user id)
//   c  the conversation the push was about
//   d  sha256 hex of the push token of the device it was sent to; the server
//      refuses it once that device is no longer the member's active one
//   a  the actions it allows: 'mark_read' and/or 'reply'
//   e  expiry, epoch seconds
//
// Nothing in a token is secret, so it can be read by whoever holds it; it can
// not be altered or minted without the key.

export type ActionClaims = { u: string; c: string; d: string; a: string[]; e: number };

export const ACTION_TTL_SECONDS = 60 * 60;
const LABEL = 'sis.notification-action.v1.';
const enc = new TextEncoder();

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
const unb64url = (s: string) =>
  Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

const hmacKey = (secret: string, usage: 'sign' | 'verify') =>
  crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    usage,
  ]);

export async function sha256Hex(text: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(text)));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

export async function signActionToken(claims: ActionClaims, secret: string): Promise<string> {
  const payload = b64url(enc.encode(JSON.stringify(claims)));
  const sig = new Uint8Array(
    await crypto.subtle.sign('HMAC', await hmacKey(secret, 'sign'), enc.encode(LABEL + payload)),
  );
  return `v1.${payload}.${b64url(sig)}`;
}

/** The claims of a genuine, unexpired token, or null. Never throws. */
export async function verifyActionToken(
  token: unknown,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<ActionClaims | null> {
  try {
    if (typeof token !== 'string') return null;
    const [version, payload, sig, extra] = token.split('.');
    if (version !== 'v1' || !payload || !sig || extra !== undefined) return null;
    // crypto.subtle.verify compares in constant time.
    const ok = await crypto.subtle.verify(
      'HMAC',
      await hmacKey(secret, 'verify'),
      unb64url(sig),
      enc.encode(LABEL + payload),
    );
    if (!ok) return null;
    const c = JSON.parse(new TextDecoder().decode(unb64url(payload)));
    if (
      typeof c?.u !== 'string' || typeof c.c !== 'string' || typeof c.d !== 'string' ||
      !Array.isArray(c.a) || !c.a.every((x: unknown) => typeof x === 'string') ||
      typeof c.e !== 'number' || c.e <= nowSeconds
    ) return null;
    return c as ActionClaims;
  } catch {
    return null;
  }
}
