-- The chat list can tell a locked (olm_type / has_ciphertext) preview from a plain one; the ciphertext itself never leaves.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms, m.location_lat, m.attachment_mime,
       m.sticker_id, m.sticker_album, m.admin_msg, m.olm_type, m.has_ciphertext
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms, mm.location_lat,
           mm.attachment_mime, mm.sticker_id, mm.sticker_album, mm.admin_msg,
           mm.olm_type, (mm.ciphertext is not null) as has_ciphertext
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- chat_list() previews also carry olm_type and has_ciphertext (never the ciphertext), so the app can tell a locked row from a plain one.
CREATE OR REPLACE FUNCTION public.chat_list()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
SELECT jsonb_build_object(
  'members', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, user_id, left_at, color_slot, role
      from public.conversation_members
    ) x
  ), '[]'::jsonb),
  'conversations', coalesce((
    -- Every column the app reads, now including staff_key; the four it never reads stay out, and the old per-chat flag is no longer sent (the app uses staff_key).
    select jsonb_agg(to_jsonb(c) - 'direct_key' - 'created_at' - 'encrypted_at' - 'closed_by' - 'bacanaks_chat')
    from public.conversations c
  ), '[]'::jsonb),
  'archives', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_archives
    ) x
  ), '[]'::jsonb),
  'pins', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_pins
    ) x
  ), '[]'::jsonb),
  'hides', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_hides
    ) x
  ), '[]'::jsonb),
  'profiles', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select user_id, display_name, avatar_path
      from public.profiles_public()
      where user_id in (
        select cm.user_id
        from public.conversation_members cm
        where cm.user_id <> (select auth.uid())
      )
    ) x
  ), '[]'::jsonb),
  'previews', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, body, created_at, attachment_path, sender_id, deleted, poll, contact, attachment_name, attachment_duration_ms, location_lat, attachment_mime, sticker_id, sticker_album, admin_msg, olm_type, has_ciphertext
      from public.conversation_previews
    ) x
  ), '[]'::jsonb),
  'unread', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id, unread
      from public.unread_counts()
    ) x
  ), '[]'::jsonb)
);
$$;

REVOKE ALL ON FUNCTION public.chat_list() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.chat_list() TO authenticated;

-- search_messages as in 20261031120000, plus: a row with olm_type set is never matched either (a half-set row; the table check already forbids one).
create or replace function public.search_messages(query text, conversation uuid default null)
returns table (
  id uuid, conversation_id uuid, sender_id uuid, body text, created_at timestamptz,
  attachment_path text, attachment_preview text, deleted text, reply_to uuid,
  forwarded boolean, edited_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.conversation_id, m.sender_id, m.body, m.created_at,
         m.attachment_path, m.attachment_preview, m.deleted, m.reply_to,
         m.forwarded, m.edited_at
    from public.messages m
   where (select app_private.has_app_access())
     and (conversation is null or (select app_private.was_member(conversation)))
     and m.conversation_id = any (
           array(select cm.conversation_id from public.conversation_members cm
                  where cm.user_id = auth.uid())
         )
     and app_private.message_readable(m.*)
     and char_length(regexp_replace(query, '[^[:alnum:]]', '', 'g')) >= 3
     and m.deleted is null
     and m.ciphertext is null
     and m.olm_type is null
     and (conversation is null or m.conversation_id = conversation)
     and m.search_text like (select '%' || public.escape_like(public.fold_search(btrim(query))) || '%') escape '\'
   order by m.created_at desc
   limit 50
$$;
