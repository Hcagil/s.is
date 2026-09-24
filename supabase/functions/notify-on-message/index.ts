// Sends a push notification for a new message.
//
// Called by the messages_notify trigger (pg_net) with only the message id,
// and deployed with --no-verify-jwt because a trigger holds no user JWT.
// That is safe because the request decides nothing: public.push_targets()
// claims the message (at most once, and only while it is under two minutes
// old) and returns who to notify and what each of them may see. A forged or
// replayed call can at most send a notification that was due anyway, once.
import { createClient } from 'jsr:@supabase/supabase-js@2';

// What each recipient may see is decided in SQL, by their own preview
// setting (app_private.push_targets_for_message); this only delivers it.
type Target = { token: string; conversation_id: string; title: string; body: string };

async function accessToken(serviceAccount: {
  client_email: string;
  private_key: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claim = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const b64 = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const unsigned = `${b64(header)}.${b64(claim)}`;

  const pem = serviceAccount.private_key
    .replace(/-----[A-Z ]+-----/g, '')
    .replace(/\s/g, '');
  const key = await crypto.subtle.importKey(
    'pkcs8',
    Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)),
  );
  const jwt = `${unsigned}.${btoa(String.fromCharCode(...signature))
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${res.status}`);
  return (await res.json()).access_token;
}

// Supabase's edge runtime keeps the worker alive for promises handed to it.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

// The caller always gets the same empty answer, straight away. The function
// needs no JWT and a member can learn a message id at once, so anything in the
// response -- counts, errors, even how long it took -- would tell a sender
// whether the other person muted them. The work runs after the answer; its
// details go to the log.
Deno.serve(async (req: Request) => {
  const payload = await req.json().catch(() => null);
  const id = payload?.record?.id;
  // Only the id is taken from the request; everything shown comes from the
  // database.
  if (typeof id === 'string' && /^[0-9a-f-]{36}$/i.test(id)) {
    EdgeRuntime.waitUntil(send(id).catch((e) => console.error('notify failed', e)));
  }
  return new Response(null, { status: 204 });
});

async function send(id: string): Promise<void> {
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!raw) {
    // Loud in the log: a missing credential must not look like "nobody to
    // notify".
    console.error('FCM_SERVICE_ACCOUNT is not set');
    return;
  }
  const serviceAccount = JSON.parse(raw);

  // service_role: push_targets is revoked from every client role.
  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const { data, error } = await db.rpc('push_targets', { message_id: id });
  if (error) {
    console.error('push_targets failed', error.message);
    return;
  }
  const targets = (data ?? []) as Target[];
  if (!targets.length) return;

  const token = await accessToken(serviceAccount);
  const projectId = serviceAccount.project_id;

  const results = await Promise.allSettled(
    targets.map((t) =>
      fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: t.token,
            // Data only: the app shows it itself, grouped into one SIS
            // notification per phone, a line per message within each chat.
            data: {
              conversation_id: t.conversation_id,
              title: t.title,
              body: t.body,
            },
            android: { priority: 'high' },
          },
        }),
      }).then((r) => {
        if (!r.ok) throw new Error(`fcm ${r.status}`);
      }),
    ),
  );

  const sent = results.filter((r) => r.status === 'fulfilled').length;
  // ponytail: the message is claimed before FCM answers, so a failed send is
  // not retried; add a retry queue if lost notifications are ever reported.
  console.log(`sent ${sent} of ${targets.length}`);
}
