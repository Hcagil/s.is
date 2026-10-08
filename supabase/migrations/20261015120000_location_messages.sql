-- Update 2: send a location. A location is a message (messages.location_lat
-- and location_lng set, body = the place name, a line break, the address when
-- there is one), so notifications, search and the chat list keep working and
-- an older build reads it as plain text.
--
--  * Additive only: two columns, one trigger, one function, and one more
--    column at the END of conversation_previews (a view may gain columns at the
--    end only). RLS is untouched.
--  * The coordinates are not client-insertable (no column grant), so the only
--    write path is send_location(). It refuses the SIS Bot, a caller without
--    app access, a non-member and the read-only system chat with one answer
--    (42501), so a refusal reveals nothing -- the same blanket as send_contact.
--  * A location's body and coordinates are frozen while the message lives, so
--    edit_message (or any other update) can never move a shared place.
--    Delete for everyone clears the body and sets deleted in one update, which
--    is allowed and also erases the coordinates: a deleted message keeps no
--    position.
--  * No position of a SIS member is stored anywhere else: the coordinates in a
--    location message are only what the sender chose to share.

alter table public.messages
  add column location_lat double precision,
  add column location_lng double precision,
  add constraint messages_location_range check (
    (location_lat is null) = (location_lng is null)
    and (location_lat is null
         or (location_lat between -90 and 90 and location_lng between -180 and 180)));

create function app_private.messages_location_frozen() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null then
    new.location_lat := null;
    new.location_lng := null;
  elsif new.location_lat is distinct from old.location_lat
     or new.location_lng is distinct from old.location_lng
     or (old.location_lat is not null and new.body is distinct from old.body) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_location_frozen() from public, anon, authenticated;
create trigger messages_location_frozen before update of body, deleted, location_lat, location_lng on public.messages
  for each row execute function app_private.messages_location_frozen();

-- Sends a location. [p_id] is the new message's id, made on the phone, so a
-- retry after a lost answer is harmless: the same sender, conversation and id
-- is success, a different one is 23505. A name of 1 to 80 characters and an
-- address of 0 to 200 (both after trimming, neither with a control character
-- or line break), a latitude within -90..90 and a longitude within -180..180
-- (so not NaN or infinite either), else 22023. 42501 for every other refusal:
-- no app access, the SIS Bot, not a current member, the read-only system chat.
create function public.send_location(
  p_conversation uuid,
  p_id           uuid,
  p_lat          double precision,
  p_lng          double precision,
  p_name         text,
  p_address      text
) returns void language plpgsql security definer set search_path = '' as $$
declare
  n text := btrim(p_name);
  a text := coalesce(btrim(p_address), '');
begin
  if not app_private.has_app_access()
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(p_conversation)
     or app_private.is_system_conversation(p_conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_id is null or n is null or p_lat is null or p_lng is null
     or char_length(n) not between 1 and 80
     or char_length(a) > 200
     or n ~ '[[:cntrl:]]' or a ~ '[[:cntrl:]]'
     or not (p_lat between -90 and 90)
     or not (p_lng between -180 and 180) then
    raise exception 'invalid location' using errcode = '22023';
  end if;

  insert into public.messages(id, conversation_id, sender_id, body,
                              location_lat, location_lng)
  values (p_id, p_conversation, auth.uid(),
          case when a = '' then n else n || E'\n' || a end, p_lat, p_lng)
  on conflict (id) do nothing;
  if not found then
    if not exists (select 1 from public.messages m
                    where m.id = p_id and m.location_lat is not null
                      and m.sender_id = auth.uid()
                      and m.conversation_id = p_conversation) then
      raise exception 'id in use' using errcode = '23505';
    end if;
  end if;
end $$;
revoke all on function public.send_location(uuid, uuid, double precision, double precision, text, text) from public, anon;
grant execute on function public.send_location(uuid, uuid, double precision, double precision, text, text) to authenticated;

-- The chat list marks a location preview: one more column at the end. Same
-- definition as 20261014120000 (videos), plus location_lat.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms, m.location_lat
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms, mm.location_lat
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;
