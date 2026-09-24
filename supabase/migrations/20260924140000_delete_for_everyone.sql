-- v0.10: a sender can delete a message for everyone, within 6 hours.
--
-- Owner's rule: within 1 hour of sending the message disappears (the app
-- animates it away); between 1 and 6 hours it becomes "This message was
-- deleted"; after 6 hours it stays. Either way its content leaves the server:
-- the row keeps only who sent it and when, so the conversation still reads in
-- order.
--
-- The row is wiped and marked, never deleted: Realtime delivers UPDATEs only
-- to subscribers who may read the row, but a DELETE to every subscriber of the
-- table (see 20260922120000_chat.sql), so a real delete would fan the id out to
-- people outside the conversation.

alter table public.messages
  add column deleted text check (deleted in ('vanished', 'placeholder')),
  add column deleted_at timestamptz,
  add constraint messages_deleted_at_check check ((deleted is null) = (deleted_at is null));

-- A deleted message carries nothing; a live one still needs text, a photo, or
-- both.
alter table public.messages drop constraint messages_body_check;
alter table public.messages
  add constraint messages_body_check
  check (
    case
      when deleted is not null then
        body = '' and attachment_path is null and attachment_preview is null
      else
        (attachment_path is not null and char_length(btrim(body)) between 0 and 4000)
        or char_length(btrim(body)) between 1 and 4000
    end
  );

-- Photos of deleted messages, which their sender may now remove from storage.
-- Attachments are otherwise immutable (no delete policy): this list is the one
-- way in, and only delete_message() writes to it, inside the 6-hour window.
create table app_private.deleted_attachments (
  path    text primary key,
  user_id uuid not null references auth.users(id) on delete cascade
);
alter table app_private.deleted_attachments enable row level security;  -- no policies: no access
revoke all on table app_private.deleted_attachments from anon, authenticated;

-- Each photo belongs to exactly one message, in that message's own
-- conversation folder. Otherwise a member could point a message of their own
-- at someone else's photo and claim it here first (so its sender could never
-- remove it), or a sender could reuse an old photo's path in a new message
-- and delete that to remove the old photo after its 6 hours.
create unique index messages_attachment_path_key on public.messages(attachment_path)
  where attachment_path is not null;

-- And the sender must have uploaded the photo themselves: otherwise a
-- member could re-post a just-deleted photo before its file is removed.
create function app_private.owns_attachment(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from storage.objects o
                  where o.bucket_id = 'attachments'
                    and o.name = object_name
                    and o.owner_id = auth.uid()::text)
$$;
revoke all on function app_private.owns_attachment(text) from public, anon;
grant execute on function app_private.owns_attachment(text) to authenticated;

drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check (app_private.has_app_access()
              and sender_id = auth.uid()
              and app_private.is_member(conversation_id)
              and (attachment_path is null
                   or (split_part(attachment_path, '/', 1) = conversation_id::text
                       and app_private.owns_attachment(attachment_path))));

-- Removable: recorded by delete_message for this member, and no live message
-- still shows it.
create function app_private.may_remove_attachment(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.deleted_attachments d
                  where d.path = object_name and d.user_id = auth.uid())
     and not exists (select 1 from public.messages m
                      where m.attachment_path = object_name)
$$;
revoke all on function app_private.may_remove_attachment(text) from public, anon;
grant execute on function app_private.may_remove_attachment(text) to authenticated;

create policy attachments_remove_deleted on storage.objects for delete to authenticated
  using (bucket_id = 'attachments'
         and app_private.has_app_access()
         and owner_id = auth.uid()::text
         and app_private.may_remove_attachment(name));

-- Deletes the caller's own message for everyone and returns the photo path to
-- remove from storage (or null). Refused (42501) when the caller has no app
-- access, did not send it, it is already deleted, or it is over 6 hours old.
create function public.delete_message(message uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.sender_id <> auth.uid()
     or m.deleted is not null
     or m.created_at < now() - interval '6 hours' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id)
    values (m.attachment_path, m.sender_id)
    on conflict do nothing;
  end if;
  update public.messages
     set body = '',
         attachment_path = null,
         attachment_preview = null,
         deleted = case when m.created_at >= now() - interval '1 hour'
                        then 'vanished' else 'placeholder' end,
         deleted_at = now()
   where id = message;
  return m.attachment_path;
end $$;
revoke all on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;

-- Open screens learn of a deletion through Realtime UPDATEs, which respect the
-- read policy. Deletes stay unpublished. The setting covers the whole
-- publication, which holds public.messages alone: a table added to it later
-- publishes updates too, and must be checked for that.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'alter publication supabase_realtime set (publish = ''insert, update'')';
  end if;
end $$;

-- The chat list: a vanished message is as if never sent; a placeholder
-- previews as deleted. Unread counts ignore deleted messages.
create or replace view public.conversation_previews
with (security_invoker = true) as
select distinct on (m.conversation_id)
       m.conversation_id,
       m.body,
       m.attachment_path,
       m.created_at,
       m.sender_id,
       m.deleted
  from public.messages m
 where m.deleted is distinct from 'vanished'
 order by m.conversation_id, m.created_at desc;

create or replace function public.unread_counts()
returns table (conversation_id uuid, unread integer)
language sql stable security definer set search_path = '' as $$
  select cm.conversation_id, count(*)::integer
    from public.conversation_members cm
    join public.messages m
      on m.conversation_id = cm.conversation_id
     and m.created_at > cm.last_read_at
     and m.sender_id <> cm.user_id
     and m.deleted is null
   where cm.user_id = auth.uid()
     and app_private.has_app_access()
   group by cm.conversation_id
$$;

-- A message deleted within the push window is not announced.
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text)
language sql stable security definer set search_path = '' as $$
  -- What the lock screen shows, by the recipient's own preview setting:
  -- 'full' = who and what (a group adds its name), 'sender' = only the
  -- person, 'none' = only that there is something.
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when btrim(m.body) = '' and m.attachment_path is not null then '📷 Photo'
           else case when m.attachment_path is not null then '📷 ' else '' end
                || case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s on s.user_id = cm.user_id
    -- The session must still EXIST, exactly as has_app_access() requires:
    -- active_sessions outlives the session it names.
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
    left join public.notification_settings ns on ns.user_id = cm.user_id
   where m.id = message_id
     -- Deleted before the sender got to it: nothing to announce.
     and m.deleted is null
     -- Taken off the allowlist = no more message text on their lock screen,
     -- even while their session and token still exist (has_app_access()
     -- checks both, and so must this).
     and app_private.is_allowed(cm.user_id)
     and coalesce(ns.enabled, true)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
