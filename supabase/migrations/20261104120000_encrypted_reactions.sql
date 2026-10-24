-- Reactions in a direct chat that holds ciphertext are locked with Olm like
-- message text. The server still sees who reacted to which message and when
-- (and set versus cleared), never the emoji.
--
--  * A row holds either a plain emoji or (ciphertext, olm_type), never both.
--  * set_reaction_encrypted() is the locked write path. It uses the same gate
--    as the message guard (messages_ciphertext_guard, 20261031120000): a
--    direct human chat, no bot, every current member with live keys; and, as
--    the first locked message does, it sets conversations.encrypted_at.
--  * set_reaction() refuses a plain emoji once the chat is encrypted (no
--    downgrade); a clear still works and clears the ciphertext too.
--  * Realtime stays postgres_changes only (inserts and updates, no deletes).

alter table public.message_reactions
  add column ciphertext text,
  add column olm_type smallint,
  add constraint message_reactions_lock_check check (
    (ciphertext is null) = (olm_type is null)
    and not (emoji is not null and ciphertext is not null)
    and (ciphertext is null or (
      char_length(ciphertext) between 1 and 1024
      and olm_type in (0, 1)))
  );

grant select (ciphertext, olm_type) on public.message_reactions to authenticated;

-- May this chat hold ciphertext? Same rule as messages_ciphertext_guard.
create function app_private.chat_lockable(conv uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversations c
     where c.id = conv
       and c.direct_key is not null and not c.system and not c.admin_chat
       and not exists (select 1 from public.conversation_members cm
                        where cm.conversation_id = conv
                          and app_private.is_bot(cm.user_id))
       and not exists (select 1 from public.conversation_members cm
                        where cm.conversation_id = conv
                          and cm.left_at is null
                          and not exists (select 1 from app_private.olm_devices d
                                          join app_private.active_sessions s
                                            on s.user_id = d.user_id and s.session_id = d.session_id
                                          join auth.sessions x
                                            on x.id = s.session_id and x.user_id = s.user_id
                                          where d.user_id = cm.user_id)))
$$;
revoke all on function app_private.chat_lockable(uuid) from public, anon, authenticated;

create or replace function public.set_reaction(message uuid, emoji text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m)
     or app_private.is_system_conversation(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if emoji is null then
    update public.message_reactions r
       set emoji = null, ciphertext = null, olm_type = null, updated_at = now()
     where r.message_id = message and r.user_id = auth.uid()
       and (r.emoji is not null or r.ciphertext is not null);
    return;
  end if;
  -- No plain set once the chat is encrypted. FOR SHARE: cannot race the first
  -- locked message or reaction that sets encrypted_at.
  if exists (select 1 from public.conversations c
              where c.id = m.conversation_id and c.encrypted_at is not null
                for share) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if octet_length(emoji) not between 1 and 64 or emoji ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid emoji' using errcode = '22023';
  end if;
  if app_private.is_bot(auth.uid()) then
    perform app_private.bot_send_charge(auth.uid());
  end if;
  insert into public.message_reactions(message_id, user_id, conversation_id, emoji)
  values (message, auth.uid(), m.conversation_id, emoji)
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, ciphertext = null, olm_type = null,
                updated_at = now();
end $$;
revoke all on function public.set_reaction(uuid, text) from public, anon;
grant execute on function public.set_reaction(uuid, text) to authenticated;

-- Sets the caller's locked reaction on [message]. 42501 for every refusal alike
-- (no app access, message missing, deleted or unreadable, not a member, system
-- chat, a bot, a chat that cannot hold ciphertext); 22023 for a malformed
-- ciphertext.
create function public.set_reaction_encrypted(message uuid, ciphertext text, olm_type smallint)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m)
     or app_private.is_system_conversation(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if app_private.is_bot(auth.uid())
     or not app_private.chat_lockable(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if set_reaction_encrypted.ciphertext is null
     or char_length(set_reaction_encrypted.ciphertext) not between 1 and 1024
     or set_reaction_encrypted.olm_type is null
     or set_reaction_encrypted.olm_type not in (0, 1) then
    raise exception 'invalid ciphertext' using errcode = '22023';
  end if;
  update public.conversations set encrypted_at = coalesce(encrypted_at, now())
   where id = m.conversation_id;
  insert into public.message_reactions(message_id, user_id, conversation_id, ciphertext, olm_type)
  values (message, auth.uid(), m.conversation_id,
          set_reaction_encrypted.ciphertext, set_reaction_encrypted.olm_type)
  on conflict (message_id, user_id)
  do update set emoji = null, ciphertext = excluded.ciphertext,
                olm_type = excluded.olm_type, updated_at = now();
end $$;
revoke all on function public.set_reaction_encrypted(uuid, text, smallint) from public, anon;
grant execute on function public.set_reaction_encrypted(uuid, text, smallint) to authenticated;

-- Plain reactions made at or after the chat became private are cleared (the
-- update is published, so phones drop the chip). Rows from before
-- encrypted_at stay: sent before encryption. Backups and point-in-time
-- recovery keep the old plain values until they expire.
update public.message_reactions r
   set emoji = null, updated_at = now()
  from public.conversations c
 where c.id = r.conversation_id
   and c.encrypted_at is not null
   and r.emoji is not null
   and r.updated_at >= c.encrypted_at;
