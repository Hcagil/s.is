-- v0.27: "What's new" messages from SIS, in a read-only system chat.
--
-- Reuses the chat machinery: each member gets one conversation flagged
-- system, holding messages whose sender is a fixed system account. List,
-- unread, read marks, mute and realtime work unchanged; what changes is that
-- nobody can write into it, and no push is sent for it.
--
-- release_notes is written by the release workflow (one row per published
-- build; nothing when no PR carried a "For users:" line) and may be edited by
-- the owner in the dashboard until a member's app has fetched it. Clients
-- never touch it: deliver_release_notes() is the only way a note reaches a
-- member.

-- The system chat ---------------------------------------------------------------
alter table public.conversations
  add column system boolean not null default false;

-- The author of every system message. messages.sender_id references
-- auth.users, so this is a real row: no email, so it is on no allowlist, can
-- never sign in, and has no profile (the profile the signup trigger makes is
-- removed again -- nothing should be able to find it).
insert into auth.users (id, aud, role)
values ('00000000-0000-0000-0000-00000000515e', 'authenticated', 'authenticated')
on conflict (id) do nothing;
delete from public.profiles where user_id = '00000000-0000-0000-0000-00000000515e';

create or replace function app_private.is_system_conversation(conversation uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversations c
                  where c.id = conversation and c.system)
$$;
revoke all on function app_private.is_system_conversation(uuid) from public, anon;
grant execute on function app_private.is_system_conversation(uuid) to authenticated;

-- Nobody sends into it: messages_send (20260927140000) plus one clause. There
-- is no leave path either: leave_group, add_members and remove_member all
-- refuse a conversation without a title, and there is no delete policy on
-- conversations, members or messages.
drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check ((select app_private.has_app_access())
              and sender_id = (select auth.uid())
              and app_private.is_member(conversation_id)
              and not app_private.is_system_conversation(conversation_id)
              and (attachment_path is null
                   or (split_part(attachment_path, '/', 1) = conversation_id::text
                       and app_private.owns_attachment(attachment_path)))
              and (reply_to is null
                   or app_private.in_conversation(reply_to, conversation_id)));

-- No push for a note: it arrives when the app has just been updated and
-- opened. Same function as 20260924120000, one early exit.
create or replace function app_private.notify_new_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  url text;
begin
  if app_private.is_system_conversation(new.conversation_id) then
    return null;
  end if;
  select decrypted_secret into url
    from vault.decrypted_secrets where name = 'notify_on_message_url';
  if url is not null then
    perform net.http_post(
      url := url,
      body := jsonb_build_object('record', jsonb_build_object('id', new.id)),
      headers := '{"content-type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000);
  end if;
  return null;
exception when others then
  raise warning 'notify_new_message: %', sqlerrm;
  return null;
end $$;
revoke all on function app_private.notify_new_message() from public, anon, authenticated;

-- Notes and delivery state ------------------------------------------------------
create table public.release_notes (
  build      integer primary key check (build > 0),
  note       text not null default '' check (char_length(note) <= 4000),
  created_at timestamptz not null default now()
);
comment on table public.release_notes is
  'Plain-language note for the release with this versionCode. Editable until delivered; an empty note delivers nothing.';
alter table public.release_notes enable row level security;
revoke all on public.release_notes from anon, authenticated;

-- The highest build a member has been served notes for. Private: a member
-- neither reads nor writes it, and cannot see anyone else's.
create table app_private.release_note_delivery (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  last_build integer not null
);
alter table app_private.release_note_delivery enable row level security;

-- Delivery ----------------------------------------------------------------------
-- Called by the app on the first start of a build the member has not been
-- served for. First ever call: only the latest non-empty note up to the
-- caller's build (no backlog). Afterwards: every non-empty note in
-- (last served, installed_build], oldest first. A per-member advisory lock
-- makes repeated and concurrent calls (two devices) deliver each note once.
-- Returns how many messages were added.
create or replace function public.deliver_release_notes(installed_build integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  me     uuid := auth.uid();
  sender constant uuid := '00000000-0000-0000-0000-00000000515e';
  served integer;
  cid    uuid;
  n      record;
  sent   integer := 0;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if installed_build is null or installed_build < 1 then
    raise exception 'invalid build' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('release_notes:' || me::text, 0));

  select d.last_build into served from app_private.release_note_delivery d
   where d.user_id = me;
  if served is not null and installed_build <= served then
    return 0;
  end if;

  for n in
    select r.note from public.release_notes r
     where btrim(r.note) <> ''
       and r.build <= installed_build
       and case when served is null
                then r.build = (select max(x.build) from public.release_notes x
                                 where btrim(x.note) <> '' and x.build <= installed_build)
                else r.build > served end
     order by r.build
  loop
    if cid is null then
      insert into public.conversations(direct_key, system)
      values ('system:' || me::text, true)
      on conflict (direct_key) do nothing
      returning id into cid;
      if cid is null then
        select c.id into cid from public.conversations c
         where c.direct_key = 'system:' || me::text;
      else
        insert into public.conversation_members(conversation_id, user_id)
        values (cid, me);
      end if;
    end if;
    -- clock_timestamp, not now(): distinct times keep the notes in order.
    insert into public.messages(conversation_id, sender_id, body, created_at)
    values (cid, sender, btrim(n.note), clock_timestamp());
    sent := sent + 1;
  end loop;

  insert into app_private.release_note_delivery(user_id, last_build)
  values (me, installed_build)
  on conflict (user_id) do update
    set last_build = greatest(app_private.release_note_delivery.last_build, excluded.last_build);
  return sent;
end $$;
revoke all on function public.deliver_release_notes(integer) from public, anon;
grant execute on function public.deliver_release_notes(integer) to authenticated;

-- Notes that already shipped (builds 177 = 0.25.2, 178 = 0.26.0).
insert into public.release_notes(build, note) values
  (177, 'Every message now shows in its chat''s notification, grouped like Telegram, and tapping a notification opens the chat with the new messages already there.'),
  (178, 'You can now choose your notification sound, tone and vibration in Settings > Notifications, and turn sound or vibration on or off for any single chat from its profile page.')
on conflict (build) do nothing;
