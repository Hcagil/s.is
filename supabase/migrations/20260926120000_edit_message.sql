-- v0.13: a sender may edit their own text message, or the caption of their
-- own photo message, within 6 hours of sending (same window as delete for
-- everyone). No history is kept -- only the latest body survives, so there is
-- nothing to reveal to anyone who was not already reading the conversation.
--
-- Like delete_message this is an UPDATE, never a client-visible DELETE:
-- Realtime fans an UPDATE out only to subscribers whose read policy still
-- passes (20260922120000_chat.sql), so an edit reaches exactly the members
-- who could already read the message, the same way a deletion does.

alter table public.messages
  add column edited_at timestamptz;

-- Edits [message] to [body] and returns the updated row. Refused (42501) when
-- the caller has no app access, is not its sender, has left the conversation,
-- it is deleted, forwarded, over 6 hours old, or [body] would not pass the
-- same check the table itself enforces on send (messages_body_check): a photo
-- message may carry an empty caption, a text-only message may not.
--
-- Direct UPDATE stays impossible for clients: this is the only write path,
-- exactly as delete_message is the only way to clear a message's content --
-- there is no update grant on public.messages for authenticated.
create function public.edit_message(message uuid, body text)
returns public.messages language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  trimmed text := btrim(coalesce(body, ''));
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or m.deleted is not null
     or m.forwarded
     or m.created_at < now() - interval '6 hours' then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not (
    (m.attachment_path is not null and char_length(trimmed) between 0 and 4000)
    or char_length(trimmed) between 1 and 4000
  ) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.messages
     set body = trimmed,
         edited_at = now()
   where id = message
  returning * into m;
  return m;
end $$;
revoke all on function public.edit_message(uuid, text) from public, anon;
grant execute on function public.edit_message(uuid, text) to authenticated;

-- delete_message, redefined: a deleted message keeps only who sent it and
-- when, so its edited mark must go too -- otherwise a vanished or
-- placeholder row could still read as edited. Identical to the definition in
-- 20260924140000_delete_for_everyone.sql (not yet released, so amended here
-- rather than layering a second migration on top of it) except the UPDATE
-- also clears edited_at.
create or replace function public.delete_message(message uuid)
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
         edited_at = null,
         deleted = case when m.created_at >= now() - interval '1 hour'
                        then 'vanished' else 'placeholder' end,
         deleted_at = now()
   where id = message;
  return m.attachment_path;
end $$;
revoke all on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;
