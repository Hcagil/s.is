-- Per-member "marked unread" flag. One row = this user marked this chat unread.
-- Own rows only; written only by the RPC mark_chat_unread; cleared by mark_read.
--
create table public.chat_marked_unread (
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  marked_at       timestamptz not null default now(),
  primary key (user_id, conversation_id)
);
create index chat_marked_unread_conversation_idx on public.chat_marked_unread (conversation_id);

alter table public.chat_marked_unread enable row level security;
revoke all on table public.chat_marked_unread from anon, authenticated;
grant select on table public.chat_marked_unread to authenticated;

create policy chat_marked_unread_read on public.chat_marked_unread
  for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

create function public.mark_chat_unread(conversation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_private.has_app_access() or auth.uid() is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not app_private.was_member(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into public.chat_marked_unread (user_id, conversation_id)
    values (auth.uid(), conversation)
    on conflict do nothing;
end $$;
revoke all on function public.mark_chat_unread(uuid) from public, anon;
grant execute on function public.mark_chat_unread(uuid) to authenticated;

-- mark_read as in 20261005150000, plus: reading a chat clears its "marked unread" flag (on every phone, since it lives on the server).
create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sharing boolean := app_private.shares_read_status();
  target  public.conversation_members;
  cap     timestamptz;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into target from public.conversation_members m
   where m.conversation_id = conversation and m.user_id = auth.uid()
   order by (m.left_at is null) desc, m.left_at desc
   limit 1
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  delete from public.chat_marked_unread u
   where u.user_id = auth.uid() and u.conversation_id = conversation;
  cap := least(now(), coalesce(target.left_at, 'infinity'::timestamptz));
  update public.conversation_members m
     set last_read_at = cap,
         shared_read_at = case when sharing then cap else m.shared_read_at end
   where m.id = target.id;
  if target.left_at is null then
    perform app_private.advance_delivery(conversation, null);
  end if;
  if sharing and target.left_at is null then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'read_at', cap),
      'read',
      'reads:' || conversation::text,
      true);
  end if;
end $$;

-- chat_list_v2: chat_list as in 20261126120000 plus a "marked_unread" key (own rows only, via RLS). Released apps keep calling chat_list (unchanged answer).
CREATE OR REPLACE FUNCTION public.chat_list_v2()
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
    -- Exactly the columns the app reads (a whitelist, same output as before); every other column stays server-side.
    select jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'avatar_path', c.avatar_path, 'system', c.system, 'members_can_set_avatar', c.members_can_set_avatar, 'members_can_add', c.members_can_add, 'new_members_see_history', c.new_members_see_history, 'pinned_message_id', c.pinned_message_id, 'members_can_pin', c.members_can_pin, 'admin_chat', c.admin_chat, 'closed_at', c.closed_at, 'debug_chat', c.debug_chat, 'staff_key', c.staff_key))
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
  ), '[]'::jsonb),
  'marked_unread', coalesce((
    select jsonb_agg(to_jsonb(x))
    from (
      select conversation_id
      from public.chat_marked_unread
    ) x
  ), '[]'::jsonb)
);
$$;

REVOKE ALL ON FUNCTION public.chat_list_v2() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.chat_list_v2() TO authenticated;

-- chat_list keeps its old answer: v2 minus the new key.
CREATE OR REPLACE FUNCTION public.chat_list()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
SELECT public.chat_list_v2() - 'marked_unread';
$$;
REVOKE ALL ON FUNCTION public.chat_list() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.chat_list() TO authenticated;
