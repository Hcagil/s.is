// Mark as read and Reply from a notification button.
//
// The push handler on the phone has no Supabase session, so it cannot call
// mark_read or send a message. Instead each push carries an action token
// (_shared/action_token.ts) that notify-on-message signed for exactly one
// member, one conversation, one device and a short time. This function checks
// the token and has the database act as that member
// (public.notification_action), which applies every ordinary rule: the
// member's access, current membership, the one-device rule, rate limit.
//
// Deployed with --no-verify-jwt: the phone has no JWT, the token is the
// credential. Request (POST, JSON):
//   { token, conversation_id, action: 'mark_read' | 'reply', id?, body? }
// `id` (a v4 uuid made on the phone) and `body` are required for 'reply'; a
// retry with the same id never sends twice.
// Answers { ok: true } (200), or { error } with:
//   400 bad_request   malformed request
//   401 invalid_token forged, malformed or expired token, or wrong conversation
//                     or action for it
//   403 not_permitted no longer allowed (member left, device replaced, access off)
//   405 method        not a POST
//   409 id_in_use     the reply id already belongs to a different message
//   429 rate_limited  20 actions per member per minute
//   500 failed        anything else (safe to retry)
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { verifyActionToken } from '../_shared/action_token.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });
  const q = await req.json().catch(() => null);
  const { token, conversation_id: conversation, action, id, body } = q ?? {};
  if (
    typeof conversation !== 'string' || !UUID.test(conversation) ||
    (action !== 'mark_read' && action !== 'reply') ||
    (action === 'reply' &&
      (typeof id !== 'string' || !UUID.test(id) || typeof body !== 'string'))
  ) return reply(400, { error: 'bad_request' });

  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const claims = await verifyActionToken(token, key);
  if (!claims || claims.c.toLowerCase() !== conversation.toLowerCase() || !claims.a.includes(action)) {
    return reply(401, { error: 'invalid_token' });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, key);
  const { error } = await db.rpc('notification_action', {
    p_user: claims.u,
    p_device: claims.d,
    p_conversation: conversation,
    p_action: action,
    p_id: action === 'reply' ? id : null,
    p_body: action === 'reply' ? body : null,
  });
  if (!error) return reply(200, { ok: true });

  console.error('notification_action failed', error.code);
  switch (error.code) {
    case '42501':
      return reply(403, { error: 'not_permitted' });
    case 'P0429':
      return reply(429, { error: 'rate_limited' });
    case '23505':
      return reply(409, { error: 'id_in_use' });
    case '22023':
      return reply(400, { error: 'bad_request' });
    default:
      return reply(500, { error: 'failed' });
  }
});
