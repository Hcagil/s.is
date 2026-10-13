-- Update 2: send a contact. A contact is a message (messages.contact = true,
-- body = the name, a line break, the phone number), so notifications, search
-- and the chat list keep working and an older build reads it as plain text.
--
--  * Additive only: one boolean column, one trigger, one function, and one
--    more column at the END of conversation_previews (a view may gain columns
--    at the end only). RLS is untouched.
--  * messages.contact is not client-insertable (no column grant), so the only
--    write path is send_contact(). It refuses the SIS Bot, a caller without
--    app access, a non-member and the read-only system chat with one answer
--    (42501), so a refusal reveals nothing -- the same blanket as create_poll.
--  * A contact's body is frozen while the message lives, so edit_message (or
--    any other update of the body) can never change a shared name or number.
--    Delete for everyone clears the body and sets deleted in one update,
--    which is allowed.
--  * No phone number of a SIS member is stored or looked up here: the number
--    in a contact message is only what the sender chose to share.

alter table public.messages add column contact boolean not null default false;

create function app_private.messages_contact_body_frozen() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.contact and new.deleted is null and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_contact_body_frozen() from public, anon, authenticated;
create trigger messages_contact_body_frozen before update of body on public.messages
  for each row execute function app_private.messages_contact_body_frozen();

-- Sends a contact. [p_id] is the new message's id, made on the phone, so a
-- retry after a lost answer is harmless: the same sender, conversation and id
-- is success, a different one is 23505. A name of 1 to 80 characters and a
-- number of 3 to 32 (both after trimming, neither with a control character or
-- line break), else 22023. 42501 for every other refusal: no app access, the
-- SIS Bot, not a current member, the read-only system chat.
create function public.send_contact(
  p_conversation uuid,
  p_id           uuid,
  p_name         text,
  p_phone        text
) returns void language plpgsql security definer set search_path = '' as $$
declare
  n text := btrim(p_name);
  p text := btrim(p_phone);
begin
  if not app_private.has_app_access()
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(p_conversation)
     or app_private.is_system_conversation(p_conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_id is null or n is null or p is null
     or char_length(n) not between 1 and 80
     or char_length(p) not between 3 and 32
     or n ~ '[[:cntrl:]]' or p ~ '[[:cntrl:]]' then
    raise exception 'invalid contact' using errcode = '22023';
  end if;

  insert into public.messages(id, conversation_id, sender_id, body, contact)
  values (p_id, p_conversation, auth.uid(), n || E'\n' || p, true)
  on conflict (id) do nothing;
  if not found then
    if not exists (select 1 from public.messages m
                    where m.id = p_id and m.contact and m.sender_id = auth.uid()
                      and m.conversation_id = p_conversation) then
      raise exception 'id in use' using errcode = '23505';
    end if;
  end if;
end $$;
revoke all on function public.send_contact(uuid, uuid, text, text) from public, anon;
grant execute on function public.send_contact(uuid, uuid, text, text) to authenticated;

-- The chat list marks a contact preview: one more column at the end. Same
-- definition as 20261011120000 (polls), plus contact.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll, mm.contact
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;
