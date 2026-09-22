// Sends a push notification for a new message.
//
// NOT DEPLOYED. It needs an FCM service account that only the project owner
// can create; see docs/DELIVERY.md, "Push notifications". Everything it
// depends on inside the database already exists and is tested:
// app_private.push_targets_for_message() decides who should hear about a
// message, and returns only members who still hold an active session.
//
// Invoke with a database webhook on insert into public.messages.
import { createClient } from 'jsr:@supabase/supabase-js@2';

// A message body is not a notification body: notifications are shown on a
// locked screen, and an attachment has no text at all.
function preview(body: string | null, hasAttachment: boolean): string {
  const text = (body ?? '').trim();
  if (text.length === 0) return hasAttachment ? 'Sent a photo' : 'New message';
  return text.length <= 120 ? text : `${text.slice(0, 119)}…`;
}

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

Deno.serve(async (req: Request) => {
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!raw) {
    // Loud, not silent: a missing credential must not look like "nobody to
    // notify".
    return new Response('FCM_SERVICE_ACCOUNT is not set', { status: 503 });
  }
  const serviceAccount = JSON.parse(raw);

  const payload = await req.json();
  const message = payload.record ?? payload;
  if (!message?.id) return new Response('no message', { status: 400 });

  // service_role: push_targets_for_message reads across members by design and
  // is revoked from every client role.
  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const { data: targets, error } = await db.rpc('push_targets', {
    message_id: message.id,
  });
  if (error) return new Response(error.message, { status: 500 });
  if (!targets?.length) return new Response('no active devices', { status: 200 });

  const token = await accessToken(serviceAccount);
  const projectId = serviceAccount.project_id;
  const text = preview(message.body, Boolean(message.attachment_path));

  const results = await Promise.allSettled(
    targets.map((t: { token: string; sender_name: string }) =>
      fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: t.token,
            notification: { title: t.sender_name, body: text },
            data: { conversation_id: String(message.conversation_id) },
            android: { priority: 'high' },
          },
        }),
      }),
    ),
  );

  const sent = results.filter((r) => r.status === 'fulfilled').length;
  return new Response(JSON.stringify({ sent, of: targets.length }), {
    headers: { 'content-type': 'application/json' },
  });
});
