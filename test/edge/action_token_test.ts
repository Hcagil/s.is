import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
  ActionClaims,
  ACTION_TTL_SECONDS,
  sha256Hex,
  signActionToken,
  verifyActionToken,
} from '../../supabase/functions/_shared/action_token.ts';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Base64url encode without padding */
function base64urlEncode(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data))
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

/** Base64url decode to Uint8Array */
function base64urlDecode(str: string): Uint8Array {
  const pad = '='.repeat((4 - (str.length % 4)) % 4);
  const base64 = str.replace(/-/g, '+').replace(/_/g, '/') + pad;
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Compute HMAC-SHA256 and return base64url string */
async function hmacSha256Base64url(key: string, data: string): Promise<string> {
  const keyData = encoder.encode(key);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(data));
  return base64urlEncode(new Uint8Array(signature));
}

/** Compute SHA-256 hex digest */
async function sha256HexFromText(text: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(text));
  const hex = Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return hex;
}

Deno.test('sha256Hex works for known inputs', async () => {
  const abc = await sha256Hex('abc');
  assertEquals(
    abc,
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  );
  const empty = await sha256Hex('');
  assertEquals(
    empty,
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  );
});

Deno.test('ACTION_TTL_SECONDS is 3600', () => {
  assertEquals(ACTION_TTL_SECONDS, 3600);
});

Deno.test('signActionToken and verifyActionToken roundtrip', async () => {
  const claims: ActionClaims = {
    u: 'user-uuid',
    c: 'conv-uuid',
    d: await sha256Hex('device-token'),
    a: ['mark_read', 'reply'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const secret = 'super-secret';
  const token = await signActionToken(claims, secret);
  const decoded = await verifyActionToken(token, secret);
  assertNotEquals(decoded, null);
  assertEquals(decoded, claims);
});

Deno.test('token format and allowed characters', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const secret = 's';
  const token = await signActionToken(claims, secret);
  const parts = token.split('.');
  assertEquals(parts.length, 3);
  assert(parts[0] === 'v1');
  const allowed = /^[A-Za-z0-9_-]+$/;
  assert(allowed.test(parts[1]));
  assert(allowed.test(parts[2]));
});

Deno.test('decoding part 2 gives original claims', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const secret = 's';
  const token = await signActionToken(claims, secret);
  const parts = token.split('.');
  const payloadBytes = base64urlDecode(parts[1]);
  const payloadJson = decoder.decode(payloadBytes);
  const decodedClaims: ActionClaims = JSON.parse(payloadJson);
  assertEquals(decodedClaims, claims);
});

Deno.test('signature matches HMAC over label prefix', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const secret = 's';
  const token = await signActionToken(claims, secret);
  const parts = token.split('.');
  const message = 'sis.notification-action.v1.' + parts[1];
  const expectedSig = await hmacSha256Base64url(secret, message);
  assertEquals(expectedSig, parts[2]);
});

Deno.test('hand-built token is accepted', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const secret = 's';
  const payload = base64urlEncode(encoder.encode(JSON.stringify(claims)));
  const message = 'sis.notification-action.v1.' + payload;
  const sig = await hmacSha256Base64url(secret, message);
  const token = `v1.${payload}.${sig}`;
  const decoded = await verifyActionToken(token, secret);
  assertNotEquals(decoded, null);
  assertEquals(decoded, claims);
});

Deno.test('verifyActionToken returns null for wrong secret', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 'correct');
  const decoded = await verifyActionToken(token, 'wrong');
  assertEquals(decoded, null);
});

Deno.test('forged signature (flip one character) returns null', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 's');
  const parts = token.split('.');
  const mid = Math.floor(parts[2].length / 2);
  const forgedSig = parts[2].slice(0, mid) + (parts[2][mid] === 'A' ? 'B' : 'A') + parts[2].slice(mid + 1);
  const forgedToken = `${parts[0]}.${parts[1]}.${forgedSig}`;
  const decoded = await verifyActionToken(forgedToken, 's');
  assertEquals(decoded, null);
});

Deno.test('forged signature (different payload) returns null', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 's');
  const parts = token.split('.');
  const fakeClaims: ActionClaims = { ...claims, c: 'different' };
  const fakePayload = base64urlEncode(encoder.encode(JSON.stringify(fakeClaims)));
  const fakeMessage = 'sis.notification-action.v1.' + fakePayload;
  const fakeSig = await hmacSha256Base64url('s', fakeMessage);
  const forgedToken = `${parts[0]}.${parts[1]}.${fakeSig}`; // another payload's valid signature
  const decoded = await verifyActionToken(forgedToken, 's');
  assertEquals(decoded, null);
});

Deno.test('altered payload with original signature returns null', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 's');
  const parts = token.split('.');
  const alteredClaims: ActionClaims = { ...claims, a: [...claims.a, 'extra'] };
  const alteredPayload = base64urlEncode(encoder.encode(JSON.stringify(alteredClaims)));
  const forgedToken = `${parts[0]}.${alteredPayload}.${parts[2]}`;
  const decoded = await verifyActionToken(forgedToken, 's');
  assertEquals(decoded, null);
});

Deno.test('signature without label prefix is invalid', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 's');
  const parts = token.split('.');
  const sigWithoutLabel = await hmacSha256Base64url('s', parts[1]);
  const forgedToken = `${parts[0]}.${parts[1]}.${sigWithoutLabel}`;
  const decoded = await verifyActionToken(forgedToken, 's');
  assertEquals(decoded, null);
});

Deno.test('expiry handling', async () => {
  const now = Math.floor(Date.now() / 1000);
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: now + 10,
  };
  const token = await signActionToken(claims, 's');
  const beforeExpiry = await verifyActionToken(token, 's', now + 9);
  assertNotEquals(beforeExpiry, null);
  const afterExpiry = await verifyActionToken(token, 's', now + 11);
  assertEquals(afterExpiry, null);
  const farFuture = await verifyActionToken(token, 's', now + 1000);
  assertEquals(farFuture, null);
});

Deno.test('default nowSeconds uses current time', async () => {
  const now = Math.floor(Date.now() / 1000);
  const claimsValid: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: now + ACTION_TTL_SECONDS,
  };
  const tokenValid = await signActionToken(claimsValid, 's');
  const decodedValid = await verifyActionToken(tokenValid, 's');
  assertNotEquals(decodedValid, null);

  const claimsExpired: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: now - 10,
  };
  const tokenExpired = await signActionToken(claimsExpired, 's');
  const decodedExpired = await verifyActionToken(tokenExpired, 's');
  assertEquals(decodedExpired, null);
});

Deno.test('wrong version prefixes return null', async () => {
  const claims: ActionClaims = {
    u: 'u',
    c: 'c',
    d: await sha256Hex('d'),
    a: ['a'],
    e: Math.floor(Date.now() / 1000) + 1000,
  };
  const token = await signActionToken(claims, 's');
  const parts = token.split('.');
  const v2 = `v2.${parts[1]}.${parts[2]}`;
  const v0 = `v0.${parts[1]}.${parts[2]}`;
  const empty = `.${parts[1]}.${parts[2]}`;
  assertEquals(await verifyActionToken(v2, 's'), null);
  assertEquals(await verifyActionToken(v0, 's'), null);
  assertEquals(await verifyActionToken(empty, 's'), null);
});

Deno.test('garbage tokens return null without throwing', async () => {
  const now = Math.floor(Date.now() / 1000);
  const good = await signActionToken(
    { u: 'u', c: 'c', d: await sha256Hex('d'), a: ['mark_read'], e: now + 100 },
    's',
  );
  const [, p, sig] = good.split('.');
  // Correctly signed with the label, but the payload is not JSON / not an object.
  const signed = async (payloadText: string) => {
    const seg = base64urlEncode(encoder.encode(payloadText));
    return `v1.${seg}.${await hmacSha256Base64url('s', 'sis.notification-action.v1.' + seg)}`;
  };
  const garbage = [
    '',
    'v1',
    'v1.',
    'v1..',
    'v1.a.b',
    'not a token',
    `${good}.x`,
    `v1.${p}`,
    `v1.${p}.`,
    `v1..${sig}`,
    `v1.${p}!.${sig}`,
    `v1.${p}.${sig}%%`,
    `V1.${p}.${sig}`,
    await signed('not json'),
    await signed('null'),
    await signed('42'),
    await signed('"str"'),
    await signed('[]'),
    // Correctly signed objects that are not claims: each one field wrong.
    ...await Promise.all([
      { c: 'c', d: 'd', a: ['mark_read'], e: now + 100 },
      { u: 1, c: 'c', d: 'd', a: ['mark_read'], e: now + 100 },
      { u: 'u', d: 'd', a: ['mark_read'], e: now + 100 },
      { u: 'u', c: 'c', a: ['mark_read'], e: now + 100 },
      { u: 'u', c: 'c', d: 'd', a: 'mark_read', e: now + 100 },
      { u: 'u', c: 'c', d: 'd', a: [1], e: now + 100 },
      { u: 'u', c: 'c', d: 'd', a: ['mark_read'], e: String(now + 100) },
      { u: 'u', c: 'c', d: 'd', a: ['mark_read'] },
    ].map((o) => signed(JSON.stringify(o)))),
  ];
  for (const t of garbage) {
    let result: unknown = 'threw';
    try {
      result = await verifyActionToken(t, 's');
    } catch (e) {
      throw new Error(`verifyActionToken threw on ${JSON.stringify(t)}: ${e}`);
    }
    assertEquals(result, null, `garbage accepted: ${JSON.stringify(t)}`);
  }
  // The control: the untouched token is accepted.
  assertNotEquals(await verifyActionToken(good, 's'), null);
});
