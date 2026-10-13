import { assertEquals } from 'jsr:@std/assert@1';
import { verifyGithubOidc, OIDC_ISSUER } from '../../supabase/functions/_shared/github_oidc.ts';

// ---------- helpers ----------
function b64url(input: string | Uint8Array): string {
  let bytes: Uint8Array;
  if (typeof input === 'string') {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = input;
  }
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

async function sign(header: Record<string, unknown>, claims: Record<string, unknown>, key: CryptoKey): Promise<string> {
  const headerB64 = b64url(JSON.stringify(header));
  const payloadB64 = b64url(JSON.stringify(claims));
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, data);
  const sigB64 = b64url(new Uint8Array(signature));
  return `${headerB64}.${payloadB64}.${sigB64}`;
}

// ---------- key generation ----------
const keyPair1 = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const pubJwk1 = await crypto.subtle.exportKey('jwk', keyPair1.publicKey);
(pubJwk1 as any).kid = 'k1';
(pubJwk1 as any).alg = 'RS256';
(pubJwk1 as any).use = 'sig';
const jwks = { keys: [pubJwk1] };

const keyPair2 = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const pubJwk2 = await crypto.subtle.exportKey('jwk', keyPair2.publicKey);
(pubJwk2 as any).kid = 'k2';
(pubJwk2 as any).alg = 'RS256';
(pubJwk2 as any).use = 'sig';

// ---------- test data ----------
const expected = {
  audience: 'sis-admin-apple',
  repositoryId: '123456789',
  workflowRef: 'Hcagil/s.is/.github/workflows/admin-apple.yml@refs/heads/main',
  ref: 'refs/heads/main',
  eventName: 'workflow_dispatch',
};

const now = 1_800_000_000;
const goodClaims = {
  iss: OIDC_ISSUER,
  aud: expected.audience,
  repository_id: expected.repositoryId,
  workflow_ref: expected.workflowRef,
  ref: expected.ref,
  event_name: expected.eventName,
  run_id: '987654321',
  iat: now - 10,
  nbf: now - 10,
  exp: now + 300,
};
const header = { alg: 'RS256', typ: 'JWT', kid: 'k1' };
const tokenGood = await sign(header, goodClaims, keyPair1.privateKey);

// ---------- tests ----------
Deno.test('good token', async () => {
  const res = await verifyGithubOidc(tokenGood, jwks, expected, now);
  assertEquals(res, { runId: '987654321' });
});

const wrongValues: Record<string, string> = {
  iss: 'https://token.actions.githubusercontent.com.evil.test',
  aud: 'sis-admin-applex',
  repository_id: '123456780',
  workflow_ref: 'Hcagil/s.is/.github/workflows/admin-apple.yml@refs/heads/dev',
  ref: 'refs/heads/dev',
  event_name: 'push',
};

for (const [claim, wrong] of Object.entries(wrongValues)) {
  Deno.test(`claim ${claim} wrong value`, async () => {
    const claims = { ...goodClaims, [claim]: wrong };
    const token = await sign(header, claims, keyPair1.privateKey);
    const res = await verifyGithubOidc(token, jwks, expected, now);
    assertEquals(res, null);
  });
}

for (const claim of Object.keys(wrongValues)) {
  Deno.test(`claim ${claim} missing`, async () => {
    const { [claim]: _, ...claims } = goodClaims;
    const token = await sign(header, claims, keyPair1.privateKey);
    const res = await verifyGithubOidc(token, jwks, expected, now);
    assertEquals(res, null);
  });
}

Deno.test('exp too early', async () => {
  const claims = { ...goodClaims, exp: now - 1 };
  const token = await sign(header, claims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('exp missing', async () => {
  const { exp, ...claims } = goodClaims;
  const token = await sign(header, claims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('nbf in the future (beyond clock skew)', async () => {
  const claims = { ...goodClaims, nbf: now + 600 };
  const token = await sign(header, claims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('kid not in JWKS', async () => {
  const hdr = { ...header, kid: 'k2' };
  const token = await sign(hdr, goodClaims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('signed with wrong key', async () => {
  const token = await sign(header, goodClaims, keyPair2.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('signature tampered', async () => {
  const parts = tokenGood.split('.');
  const sig = parts[2];
  // a character in the middle: the last one may only carry padding bits
  const mid = Math.floor(sig.length / 2);
  const altered = sig.slice(0, mid) + (sig[mid] === 'A' ? 'B' : 'A') + sig.slice(mid + 1);
  const token = `${parts[0]}.${parts[1]}.${altered}`;
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('alg none with empty signature', async () => {
  const hdr = { alg: 'none', typ: 'JWT', kid: 'k1' };
  const headerB64 = b64url(JSON.stringify(hdr));
  const payloadB64 = b64url(JSON.stringify(goodClaims));
  const token = `${headerB64}.${payloadB64}.`;
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('alg HS256', async () => {
  const hdr = { alg: 'HS256', typ: 'JWT', kid: 'k1' };
  const token = await sign(hdr, goodClaims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('run_id non-numeric', async () => {
  const claims = { ...goodClaims, run_id: 'abc' };
  const token = await sign(header, claims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

Deno.test('run_id missing', async () => {
  const { run_id, ...claims } = goodClaims;
  const token = await sign(header, claims, keyPair1.privateKey);
  const res = await verifyGithubOidc(token, jwks, expected, now);
  assertEquals(res, null);
});

for (const bad of ['', 'a.b', 'x.y.z', 'a.b.c.d']) {
  Deno.test(`garbage token "${bad}"`, async () => {
    const res = await verifyGithubOidc(bad, jwks, expected, now);
    assertEquals(res, null);
  });
}

Deno.test('empty JWKS', async () => {
  const res = await verifyGithubOidc(tokenGood, { keys: [] }, expected, now);
  assertEquals(res, null);
});
