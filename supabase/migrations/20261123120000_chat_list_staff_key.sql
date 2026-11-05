-- chat_list() also returns conversations.staff_key, so the app knows which staff chat a conversation is from the first frame.
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
    -- Every column the app reads, now including staff_key; the four it never reads stay out.
    select jsonb_agg(to_jsonb(c) - 'direct_key' - 'created_at' - 'encrypted_at' - 'closed_by')
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
      select conversation_id, body, created_at, attachment_path, sender_id, deleted, poll, contact, attachment_name, attachment_duration_ms, location_lat, attachment_mime, sticker_id, sticker_album, admin_msg
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
