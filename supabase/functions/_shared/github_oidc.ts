// Verifies GitHub Actions OIDC tokens issued to public repos.
// The workflow proves itself with GitHub's signed token instead of a secret in inputs.

export const OIDC_ISSUER = 'https://token.actions.githubusercontent.com';
export const OIDC_JWKS_URL = `${OIDC_ISSUER}/.well-known/jwks`;
export type Jwks = { keys: Array<Record<string, unknown>> };
export type OidcExpected = {
  audience: string;        // the aud we asked the workflow to request
  repositoryId: string;    // numeric repository id, as a string
  workflowRef: string;     // e.g. Hcagil/s.is/.github/workflows/admin-apple.yml@refs/heads/main
  ref: string;             // refs/heads/main
  eventName: string;       // workflow_dispatch
};
/** Verifies a GitHub Actions OIDC token. Returns the run id (digits only, string) when EVERY check passes, else null. Never throws, never logs. */
export async function verifyGithubOidc(token: string, jwks: Jwks, expected: OidcExpected, nowSeconds = Math.floor(Date.now() / 1000)): Promise<{ runId: string } | null> {
  try {
    const [part0, part1, part2] = token.split('.');
    if (!part0 || !part1 || !part2) return null;
    
    const header = JSON.parse(new TextDecoder().decode(base64urlUnescape(part0)));
    if (header.alg !== 'RS256' || typeof header.kid !== 'string') return null;
    
    const key = jwks.keys.find(k => k.kid === header.kid && k.kty === 'RSA');
    if (!key) return null;
    
    const cryptoKey = await crypto.subtle.importKey(
      'jwk',
      {
        kty: key.kty as string,
        n: key.n as string,
        e: key.e as string,
        alg: 'RS256',
      },
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    
    const signature = base64urlUnescape(part2);
    const dataToVerify = `${part0}.${part1}`;
    const isValid = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      cryptoKey,
      signature,
      new TextEncoder().encode(dataToVerify),
    );
    
    if (!isValid) return null;
    
    const payload = JSON.parse(new TextDecoder().decode(base64urlUnescape(part1)));
    
    if (payload.iss !== OIDC_ISSUER) return null;
    
    const aud = payload.aud;
    const audienceMatches = Array.isArray(aud)
      ? aud.includes(expected.audience)
      : aud === expected.audience;
    if (!audienceMatches) return null;
    
    if (typeof payload.exp !== 'number' || payload.exp <= nowSeconds) return null;
    
    if (typeof payload.nbf === 'number' && payload.nbf > nowSeconds + 60) return null;
    
    if (String(payload.repository_id) !== expected.repositoryId) return null;
    
    if (payload.workflow_ref !== expected.workflowRef) return null;
    
    if (payload.ref !== expected.ref) return null;
    
    if (payload.event_name !== expected.eventName) return null;
    
    const runId = String(payload.run_id);
    if (!/^[0-9]{1,18}$/.test(runId)) return null;
    
    return { runId };
  } catch {
    return null;
  }
}

const base64urlUnescape = (s: string) =>
  Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
