-- A new release note goes into every member's SIS chat the moment its row is
-- inserted (the release workflow inserts it after the Play upload), with ONE push
-- per member through the existing notify-on-message path. deliver_release_notes
-- stays as the silent backstop for members who joined later; it skips builds
-- recorded in release_note_sent, so nothing is delivered twice.
--
-- shortcut: loops all members inside the insert; move to a batched job past a few hundred members.

-- Which builds were already put into a member's chat by the broadcast. Private:
-- RLS on, no policy, so no client role can read or write it.
create table app_private.release_note_sent (
  user_id uuid not null references auth.users(id) on delete cascade,
  build integer not null,
  primary key (user_id, build)
);
alter table app_private.release_note_sent enable row level security;

create or replace function app_private.broadcast_release_note()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sender constant uuid := '00000000-0000-0000-0000-00000000515e';
  u record;
  cid uuid;
  mid uuid;
  url text;
begin
  if btrim(new.note, E' \t\r\n') = '' then
    return null;
  end if;

  select decrypted_secret into url
    from vault.decrypted_secrets
   where name = 'notify_on_message_url';

  for u in select au.id from auth.users au
           where au.id <> sender
             and app_private.is_allowed(au.id)
  loop
    -- One member's failure must not stop the others or the release_notes insert.
    begin
      -- Same lock key as deliver_release_notes: the two never interleave.
      perform pg_advisory_xact_lock(hashtextextended('release_notes:' || u.id::text, 0));

      if not exists (select 1 from app_private.release_note_sent s
                      where s.user_id = u.id and s.build = new.build)
      then
        insert into public.conversations(direct_key, system)
        values ('system:' || u.id::text, true)
        on conflict (direct_key) do nothing
        returning id into cid;

        if cid is null then
          select c.id into cid from public.conversations c
           where c.direct_key = 'system:' || u.id::text;
        else
          insert into public.conversation_members(conversation_id, user_id)
          values (cid, u.id);
        end if;

        insert into public.messages(conversation_id, sender_id, body, created_at)
        values (cid, sender, btrim(new.note, E' \t\r\n'), clock_timestamp())
        returning id into mid;

        insert into app_private.release_note_sent(user_id, build)
        values (u.id, new.build);

        if url is not null then
          perform net.http_post(
            url := url,
            body := jsonb_build_object('record', jsonb_build_object('id', mid)),
            headers := '{"content-type": "application/json"}'::jsonb,
            timeout_milliseconds := 5000);
        end if;
      end if;
    exception when others then
      raise warning 'broadcast_release_note: %', sqlerrm;
    end;
  end loop;

  return null;
end $$;
revoke all on function app_private.broadcast_release_note() from public, anon, authenticated;

create trigger release_notes_broadcast
after insert on public.release_notes
for each row execute function app_private.broadcast_release_note();

-- deliver_release_notes as in 20260930120000_whats_new.sql, plus one clause: a build
-- the broadcast already put into this member's chat is not delivered again.
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
     where btrim(r.note, E' \t\r\n') <> ''
       and r.build <= installed_build
       and not exists (select 1 from app_private.release_note_sent x2
                        where x2.user_id = me and x2.build = r.build)
       and case when served is null
                then r.build = (select max(x.build) from public.release_notes x
                                 where btrim(x.note, E' \t\r\n') <> '' and x.build <= installed_build)
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
    values (cid, sender, btrim(n.note, E' \t\r\n'), clock_timestamp());
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

-- A note from the SIS system account has no profile; its push would be titled
-- "Someone". Same function as 20261020120000_notification_photo.sql with the
-- fallback name "SIS" for that sender (three places). Return type is unchanged, so
-- create or replace keeps the existing revoke.
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer, thumb_path text, thumb_video boolean)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end)
           else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end) || coalesce(' @ ' || c.title, '')
         end,
         case
           when coalesce(ns.preview, 'full') <> 'full' then 'New message'
           when m.sticker_id is not null then '😀 Sticker'
           when m.sticker_album then '📂 Sticker album'
           when m.attachment_mime = 'audio/mp4'
                and m.attachment_duration_ms is not null
                and btrim(m.body) = ''
             then '🎤 Voice message'
           when m.attachment_duration_ms is not null and btrim(m.body) = ''
             then '🎥 Video'
           when m.attachment_name is not null and btrim(m.body) = ''
             then '📎 ' || case when char_length(m.attachment_name) <= 100 then m.attachment_name
                                else left(m.attachment_name, 99) || '…' end
           when btrim(m.body) = '' and m.attachment_path is not null then '📷 Photo'
           else case when m.attachment_path is not null then '📷 ' else '' end
                || case when char_length(btrim(m.body)) <= 120 then btrim(m.body)
                        else left(btrim(m.body), 119) || '…' end
         end,
         d.shows_itself,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else coalesce(p.display_name, case when m.sender_id = '00000000-0000-0000-0000-00000000515e' then 'SIS' else 'Someone' end) end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end,
         app_private.unread_total(cm.user_id),
         case when coalesce(ns.preview, 'full') = 'full'
                and m.sticker_id is null
                and m.attachment_path is not null
                and (m.attachment_name is null
                     or (m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null))
              then m.attachment_path || '.t' end,
         coalesce(m.attachment_mime ~ '^video/' and m.attachment_duration_ms is not null, false)
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id <> m.sender_id
     and cm.left_at is null
    join app_private.device_tokens d on d.user_id = cm.user_id
    join app_private.active_sessions s
      on s.user_id = cm.user_id and s.session_id = d.session_id
    join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
    left join public.profiles p on p.user_id = m.sender_id
    left join public.notification_settings ns on ns.user_id = cm.user_id
   where m.id = message_id
     and m.deleted is null
     and app_private.is_allowed(cm.user_id)
     and coalesce(ns.enabled, true)
     and not exists (
       select 1 from public.chat_archives a
        where a.user_id = cm.user_id and a.conversation_id = m.conversation_id)
     and not exists (
       select 1 from public.notification_mutes mu
        where mu.user_id = cm.user_id
          and (mu.until is null or mu.until > now())
          and ((mu.kind = 'conversation' and mu.target = m.conversation_id)
            or (mu.kind = 'person' and mu.target = m.sender_id)))
$$;
