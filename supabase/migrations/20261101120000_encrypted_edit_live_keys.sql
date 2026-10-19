-- edit_message_encrypted as in 20261031120000, plus: the edit is refused when any
-- current member has no live published phone (the insert guard's rule), so a
-- new ciphertext is never locked for a peer who can no longer read it.
-- Errors: 42501 not permitted.
create or replace function public.edit_message_encrypted(p_id uuid, p_ciphertext text, p_olm_type smallint)
returns public.messages language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_id for update;
  if not found
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or m.deleted is not null
     or m.forwarded
     or m.created_at < now() - interval '6 hours'
     or m.ciphertext is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if exists (select 1 from public.conversation_members cm
              where cm.conversation_id = m.conversation_id
                and cm.left_at is null
                and not exists (select 1 from app_private.olm_devices d
                                join app_private.active_sessions s
                                  on s.user_id = d.user_id and s.session_id = d.session_id
                                join auth.sessions x
                                  on x.id = s.session_id and x.user_id = s.user_id
                                where d.user_id = cm.user_id)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_ciphertext is null or char_length(p_ciphertext) not between 1 and 65536
     or p_olm_type is null or p_olm_type not in (0, 1) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.messages
     set ciphertext = p_ciphertext, olm_type = p_olm_type, edited_at = now()
   where id = p_id
  returning * into m;
  return m;
end $$;
revoke all on function public.edit_message_encrypted(uuid, text, smallint) from public, anon;
grant execute on function public.edit_message_encrypted(uuid, text, smallint) to authenticated;

-- edit_message as in 20261031120000, plus: refused in a chat that has ever been
-- encrypted (conversations.encrypted_at), not only on a ciphertext row, so a
-- locked chat never gets a plain edit.
create or replace function public.edit_message(message uuid, body text)
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
     or m.ciphertext is not null
     or m.created_at < now() - interval '6 hours'
     or exists (select 1 from public.conversations c
                 where c.id = m.conversation_id and c.encrypted_at is not null) then
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
