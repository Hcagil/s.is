-- v0.10: replies and forwards.
--
-- A reply names the message it answers; the app shows a quote of it. A
-- forward is an ordinary new message in another conversation, marked so the
-- app can say "Forwarded" -- its photo is copied into that conversation's
-- folder, because a photo is readable only by members of the conversation
-- whose folder holds it.

alter table public.messages
  add column reply_to uuid references public.messages(id) on delete set null,
  add column forwarded boolean not null default false;

-- Finding the replies to a message when it is removed by a cascade.
create index messages_reply_to_idx on public.messages(reply_to)
  where reply_to is not null;

grant insert (reply_to, forwarded) on public.messages to authenticated;

-- A reply quotes a message of the same conversation: never one elsewhere,
-- which would reveal that the id exists and let a quote carry it across.
create function app_private.in_conversation(message uuid, conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.is_member(conversation)
     and exists (select 1 from public.messages m
                  where m.id = message and m.conversation_id = conversation)
$$;
revoke all on function app_private.in_conversation(uuid, uuid) from public, anon;
grant execute on function app_private.in_conversation(uuid, uuid) to authenticated;

drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check (app_private.has_app_access()
              and sender_id = auth.uid()
              and app_private.is_member(conversation_id)
              and (attachment_path is null
                   or (split_part(attachment_path, '/', 1) = conversation_id::text
                       and app_private.owns_attachment(attachment_path)))
              and (reply_to is null
                   or app_private.in_conversation(reply_to, conversation_id)));
