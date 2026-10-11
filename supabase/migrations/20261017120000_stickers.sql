-- Update 2 (step 10a): stickers, favourites, private albums and shared albums.
--
--  * A sticker is a square 512x512 WebP (still, transparent, at most 100 KB)
--    kept in the private `stickers` bucket as `<sticker id>.webp`. Its row in
--    `stickers` carries only the owner; the SIS starter stickers are flagged
--    `starter` (owner_id null) and ship inside the app, so their rows exist only to be
--    referenced. This migration creates no way to ADD a sticker image: making
--    stickers (crop, background removal, text, drawing) is step 10b and adds
--    its own upload policy and function.
--  * Who may read a sticker (can_read_sticker, used by the bucket policy and by
--    every function below): a starter; its owner; a member who can read a
--    message that carries it; a member who can read a message that shares an
--    album holding it; and whoever holds it in their own album or favourites
--    (a holder got it through add_sticker_to_album / add_sticker_favourite /
--    add_shared_album, each of which checks the same rule at that moment).
--  * Albums are private. 10 albums per person (STKA1), 50 stickers per album
--    (STKA2), 200 favourites per person (STKF1). The limits live in BEFORE
--    INSERT triggers on the tables, serialised by an advisory lock, so no
--    function and no race can pass them. Clients have no write grant on any
--    table here: every change goes through the functions below.
--  * A sticker message has sticker_id set and an empty body; an album card has
--    sticker_album set, the album's name as its body and, while the album
--    still exists, sticker_album_id (set null when the album is deleted, so
--    the card then reads "album gone"). Both are written only by
--    send_sticker / send_sticker_album, their body is frozen, and delete for
--    everyone clears the sticker columns with the rest.
--  * The chat list preview carries sticker_id and sticker_album (one more
--    column each, at the END of conversation_previews); the push text for a
--    sticker is "Sticker".

-- Storage ---------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stickers', 'stickers', false, 102400, array['image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Tables ----------------------------------------------------------------
create table public.stickers (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid references auth.users(id) on delete set null,
  starter    boolean not null default false,
  created_at timestamptz not null default now()
);
create index stickers_owner_idx on public.stickers(owner_id) where owner_id is not null;
alter table public.stickers enable row level security;  -- no policies: read through the functions
revoke all on public.stickers from anon, authenticated;

create table public.sticker_albums (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 40 and name !~ '[[:cntrl:]]'),
  created_at timestamptz not null default now()
);
create index sticker_albums_owner_idx on public.sticker_albums(owner_id);
alter table public.sticker_albums enable row level security;
revoke all on public.sticker_albums from anon, authenticated;
grant select on public.sticker_albums to authenticated;
create policy sticker_albums_read on public.sticker_albums for select to authenticated
  using ((select app_private.has_app_access()) and owner_id = (select auth.uid()));

create table public.sticker_album_items (
  album_id   uuid not null references public.sticker_albums(id) on delete cascade,
  sticker_id uuid not null references public.stickers(id) on delete cascade,
  added_at   timestamptz not null default now(),
  primary key (album_id, sticker_id)
);
create index sticker_album_items_sticker_idx on public.sticker_album_items(sticker_id);
alter table public.sticker_album_items enable row level security;
revoke all on public.sticker_album_items from anon, authenticated;
grant select on public.sticker_album_items to authenticated;
create policy sticker_album_items_read on public.sticker_album_items for select to authenticated
  using ((select app_private.has_app_access())
         and exists (select 1 from public.sticker_albums a
                      where a.id = album_id and a.owner_id = (select auth.uid())));

create table public.sticker_favourites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  sticker_id uuid not null references public.stickers(id) on delete cascade,
  added_at   timestamptz not null default now(),
  primary key (user_id, sticker_id)
);
create index sticker_favourites_sticker_idx on public.sticker_favourites(sticker_id);
alter table public.sticker_favourites enable row level security;
revoke all on public.sticker_favourites from anon, authenticated;
grant select on public.sticker_favourites to authenticated;
create policy sticker_favourites_read on public.sticker_favourites for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

-- The SIS starter album: sixteen stickers drawn for SIS, bundled in the app
-- (assets/stickers/starter_NN.webp). The ids are fixed so every build agrees.
insert into public.stickers(id, owner_id, starter)
select ('5151c000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, null, true
  from generate_series(1, 16) n
on conflict do nothing;

-- The limits (insert triggers) ---------------------------------------------
create function app_private.sticker_albums_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('sticker_albums:' || new.owner_id, 0));
  if (select count(*) from public.sticker_albums where owner_id = new.owner_id) >= 10 then
    raise exception 'too many albums' using errcode = 'STKA1';
  end if;
  return new;
end $$;
revoke all on function app_private.sticker_albums_limit() from public, anon, authenticated;
create trigger sticker_albums_limit before insert on public.sticker_albums
  for each row execute function app_private.sticker_albums_limit();

create function app_private.sticker_album_items_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('sticker_album:' || new.album_id, 0));
  if (select count(*) from public.sticker_album_items where album_id = new.album_id) >= 50 then
    raise exception 'too many stickers in the album' using errcode = 'STKA2';
  end if;
  return new;
end $$;
revoke all on function app_private.sticker_album_items_limit() from public, anon, authenticated;
create trigger sticker_album_items_limit before insert on public.sticker_album_items
  for each row execute function app_private.sticker_album_items_limit();

create function app_private.sticker_favourites_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('sticker_favourites:' || new.user_id, 0));
  if (select count(*) from public.sticker_favourites where user_id = new.user_id) >= 200 then
    raise exception 'too many favourites' using errcode = 'STKF1';
  end if;
  return new;
end $$;
revoke all on function app_private.sticker_favourites_limit() from public, anon, authenticated;
create trigger sticker_favourites_limit before insert on public.sticker_favourites
  for each row execute function app_private.sticker_favourites_limit();

-- The message half ---------------------------------------------------------
alter table public.messages
  add column sticker_id       uuid references public.stickers(id) on delete restrict,
  add column sticker_album_id uuid references public.sticker_albums(id) on delete set null,
  add column sticker_album    boolean not null default false,
  add constraint messages_sticker_check check (
    (sticker_id is null or (not sticker_album and sticker_album_id is null
                            and attachment_path is null and body = ''))
    and (not sticker_album or (sticker_id is null and attachment_path is null))
    and (sticker_album or sticker_album_id is null));
create index messages_sticker_idx on public.messages(sticker_id) where sticker_id is not null;
create index messages_sticker_album_idx on public.messages(sticker_album_id)
  where sticker_album_id is not null;

-- A sticker message has an empty body: the body check lets it through.
alter table public.messages drop constraint messages_body_check;
alter table public.messages
  add constraint messages_body_check
  check (
    case
      when deleted is not null then
        body = '' and attachment_path is null and attachment_preview is null
      else
        (attachment_path is not null and char_length(btrim(body)) between 0 and 4000)
        or (sticker_id is not null and body = '')
        or char_length(btrim(body)) between 1 and 4000
    end
  );

create function app_private.messages_sticker_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted is not null then
    new.sticker_id := null;
    new.sticker_album_id := null;
    new.sticker_album := false;
  elsif (old.sticker_id is not null or old.sticker_album)
        and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_sticker_guard() from public, anon, authenticated;
create trigger messages_sticker_guard before update of body, deleted on public.messages
  for each row execute function app_private.messages_sticker_guard();

-- Who may read what -------------------------------------------------------
-- The album is shared into a chat the caller can read.
-- Current members only, no history check: a departed member loses access, a late joiner gains it.
create function app_private.album_shared_to_me(p_album uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.messages m
                  where m.sticker_album_id = p_album
                    and m.deleted is null
                    and app_private.is_member(m.conversation_id))
$$;
revoke all on function app_private.album_shared_to_me(uuid) from public, anon;
grant execute on function app_private.album_shared_to_me(uuid) to authenticated;

create function app_private.can_read_sticker(p_sticker uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.stickers s
                  where s.id = p_sticker
                    and (s.starter or s.owner_id = auth.uid()))
      or exists (select 1 from public.sticker_favourites f
                  where f.user_id = auth.uid() and f.sticker_id = p_sticker)
      or exists (select 1 from public.sticker_album_items i
                   join public.sticker_albums a on a.id = i.album_id
                  where i.sticker_id = p_sticker and a.owner_id = auth.uid())
      or exists (select 1 from public.messages m
                  where m.sticker_id = p_sticker and m.deleted is null
                    and app_private.message_readable(m.*))
      or exists (select 1 from public.sticker_album_items i
                  where i.sticker_id = p_sticker
                    and app_private.album_shared_to_me(i.album_id))
$$;
revoke all on function app_private.can_read_sticker(uuid) from public, anon;
grant execute on function app_private.can_read_sticker(uuid) to authenticated;

-- The bucket: `<uuid>.webp`; whoever can read the sticker can read the file.
create function app_private.sticker_object_readable(object_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  if object_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.webp$' then
    return false;
  end if;
  return app_private.can_read_sticker(left(object_name, 36)::uuid);
end $$;
revoke all on function app_private.sticker_object_readable(text) from public, anon;
grant execute on function app_private.sticker_object_readable(text) to authenticated;

drop policy if exists stickers_read on storage.objects;
create policy stickers_read on storage.objects for select to authenticated
  using (bucket_id = 'stickers'
         and (select app_private.has_app_access())
         and app_private.sticker_object_readable(name));

-- The functions -----------------------------------------------------------
-- Common gate: app access, not the SIS Bot. 42501 otherwise.
create function app_private.sticker_gate() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() or app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
end $$;
revoke all on function app_private.sticker_gate() from public, anon;
grant execute on function app_private.sticker_gate() to authenticated;

-- Makes a private album. 22023 for a name that is empty, over 40 characters
-- or has a control character; STKA1 at 10 albums.
create function public.create_sticker_album(p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  n text := btrim(p_name);
  new_id uuid;
begin
  perform app_private.sticker_gate();
  if n is null or char_length(n) not between 1 and 40 or n ~ '[[:cntrl:]]' then
    raise exception 'invalid album name' using errcode = '22023';
  end if;
  insert into public.sticker_albums(owner_id, name) values (auth.uid(), n)
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.create_sticker_album(text) from public, anon;
grant execute on function public.create_sticker_album(text) to authenticated;

create function public.rename_sticker_album(p_album uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  n text := btrim(p_name);
begin
  perform app_private.sticker_gate();
  if n is null or char_length(n) not between 1 and 40 or n ~ '[[:cntrl:]]' then
    raise exception 'invalid album name' using errcode = '22023';
  end if;
  update public.sticker_albums set name = n
   where id = p_album and owner_id = auth.uid();
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
end $$;
revoke all on function public.rename_sticker_album(uuid, text) from public, anon;
grant execute on function public.rename_sticker_album(uuid, text) to authenticated;

create function public.delete_sticker_album(p_album uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  delete from public.sticker_albums where id = p_album and owner_id = auth.uid();
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
end $$;
revoke all on function public.delete_sticker_album(uuid) from public, anon;
grant execute on function public.delete_sticker_album(uuid) to authenticated;

-- Puts a sticker the caller can read into one of their albums. Already there:
-- nothing happens. STKA2 at 50 stickers.
create function public.add_sticker_to_album(p_album uuid, p_sticker uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  if not exists (select 1 from public.sticker_albums
                  where id = p_album and owner_id = auth.uid())
     or not app_private.can_read_sticker(p_sticker) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if exists (select 1 from public.sticker_album_items
              where album_id = p_album and sticker_id = p_sticker) then
    return;
  end if;
  insert into public.sticker_album_items(album_id, sticker_id) values (p_album, p_sticker);
end $$;
revoke all on function public.add_sticker_to_album(uuid, uuid) from public, anon;
grant execute on function public.add_sticker_to_album(uuid, uuid) to authenticated;

create function public.remove_sticker_from_album(p_album uuid, p_sticker uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  if not exists (select 1 from public.sticker_albums
                  where id = p_album and owner_id = auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  delete from public.sticker_album_items where album_id = p_album and sticker_id = p_sticker;
end $$;
revoke all on function public.remove_sticker_from_album(uuid, uuid) from public, anon;
grant execute on function public.remove_sticker_from_album(uuid, uuid) to authenticated;

-- Favourites: STKF1 at 200; already a favourite: nothing happens.
create function public.add_sticker_favourite(p_sticker uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  if not app_private.can_read_sticker(p_sticker) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if exists (select 1 from public.sticker_favourites
              where user_id = auth.uid() and sticker_id = p_sticker) then
    return;
  end if;
  insert into public.sticker_favourites(user_id, sticker_id) values (auth.uid(), p_sticker);
end $$;
revoke all on function public.add_sticker_favourite(uuid) from public, anon;
grant execute on function public.add_sticker_favourite(uuid) to authenticated;

create function public.remove_sticker_favourite(p_sticker uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  delete from public.sticker_favourites where user_id = auth.uid() and sticker_id = p_sticker;
end $$;
revoke all on function public.remove_sticker_favourite(uuid) from public, anon;
grant execute on function public.remove_sticker_favourite(uuid) to authenticated;

-- The stickers of an album, oldest first: the caller's own album, or one
-- shared into a chat they can read (the card's preview). 42501 otherwise.
create function public.album_stickers(p_album uuid) returns setof uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.sticker_gate();
  if not (exists (select 1 from public.sticker_albums
                   where id = p_album and owner_id = auth.uid())
          or app_private.album_shared_to_me(p_album)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select i.sticker_id from public.sticker_album_items i
                where i.album_id = p_album order by i.added_at, i.sticker_id;
end $$;
revoke all on function public.album_stickers(uuid) from public, anon;
grant execute on function public.album_stickers(uuid) to authenticated;

-- "Add album" on a shared album card: a new private album of the caller's,
-- with the same name and stickers. Returns its id. STKA1 at 10 albums.
create function public.add_shared_album(p_album uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  album_name text;
  new_id uuid;
begin
  perform app_private.sticker_gate();
  select a.name into album_name from public.sticker_albums a
   where a.id = p_album and app_private.album_shared_to_me(a.id);
  if album_name is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into public.sticker_albums(owner_id, name) values (auth.uid(), album_name)
  returning id into new_id;
  insert into public.sticker_album_items(album_id, sticker_id, added_at)
  select new_id, i.sticker_id, i.added_at from public.sticker_album_items i
   where i.album_id = p_album;
  return new_id;
end $$;
revoke all on function public.add_shared_album(uuid) from public, anon;
grant execute on function public.add_shared_album(uuid) to authenticated;

-- "Add to favourites" on a shared album card: every sticker of it that is not
-- yet a favourite. All or nothing: STKF1 (and nothing added) if they would
-- not all fit. Returns how many were added.
create function public.add_shared_album_to_favourites(p_album uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  added integer;
begin
  perform app_private.sticker_gate();
  if not app_private.album_shared_to_me(p_album) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into public.sticker_favourites(user_id, sticker_id)
  select auth.uid(), i.sticker_id from public.sticker_album_items i
   where i.album_id = p_album
     and not exists (select 1 from public.sticker_favourites f
                      where f.user_id = auth.uid() and f.sticker_id = i.sticker_id);
  get diagnostics added = row_count;
  return added;
end $$;
revoke all on function public.add_shared_album_to_favourites(uuid) from public, anon;
grant execute on function public.add_shared_album_to_favourites(uuid) to authenticated;

-- Sends a sticker. [p_id] is the new message's id made on the phone, so a retry
-- after a lost answer is harmless (same sender, conversation and id is success,
-- a different one 23505). [p_reply_to] answers a message of the same
-- conversation; [p_forwarded] marks a forward. 42501 for every refusal: no app
-- access, the SIS Bot, not a current member, the read-only system chat, a
-- sticker the caller cannot read, a reply target outside the chat.
create function public.send_sticker(
  p_conversation uuid,
  p_id           uuid,
  p_sticker      uuid,
  p_reply_to     uuid default null,
  p_forwarded    boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access()
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(p_conversation)
     or app_private.is_system_conversation(p_conversation)
     or p_id is null
     or not app_private.can_read_sticker(p_sticker)
     or (p_reply_to is not null
         and not app_private.in_conversation(p_reply_to, p_conversation)) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into public.messages(id, conversation_id, sender_id, body, sticker_id,
                              reply_to, forwarded)
  values (p_id, p_conversation, auth.uid(), '', p_sticker, p_reply_to,
          coalesce(p_forwarded, false))
  on conflict (id) do nothing;
  if not found then
    if not exists (select 1 from public.messages m
                    where m.id = p_id and m.sticker_id is not null
                      and m.sender_id = auth.uid()
                      and m.conversation_id = p_conversation) then
      raise exception 'id in use' using errcode = '23505';
    end if;
  end if;
end $$;
revoke all on function public.send_sticker(uuid, uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.send_sticker(uuid, uuid, uuid, uuid, boolean) to authenticated;

-- Shares one of the caller's own albums (it must hold a sticker) as a card.
-- The card's body is the album's name. Same idempotence and refusals.
create function public.send_sticker_album(
  p_conversation uuid,
  p_id           uuid,
  p_album        uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare
  album_name text;
begin
  if not app_private.has_app_access()
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(p_conversation)
     or app_private.is_system_conversation(p_conversation)
     or p_id is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select a.name into album_name from public.sticker_albums a
   where a.id = p_album and a.owner_id = auth.uid();
  if album_name is null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.sticker_album_items where album_id = p_album) then
    raise exception 'empty album' using errcode = '22023';
  end if;
  insert into public.messages(id, conversation_id, sender_id, body, sticker_album,
                              sticker_album_id)
  values (p_id, p_conversation, auth.uid(), album_name, true, p_album)
  on conflict (id) do nothing;
  if not found then
    if not exists (select 1 from public.messages m
                    where m.id = p_id and m.sticker_album
                      and m.sender_id = auth.uid()
                      and m.conversation_id = p_conversation) then
      raise exception 'id in use' using errcode = '23505';
    end if;
  end if;
end $$;
revoke all on function public.send_sticker_album(uuid, uuid, uuid) from public, anon;
grant execute on function public.send_sticker_album(uuid, uuid, uuid) to authenticated;

-- The chat list marks sticker previews: two more columns at the end. Same
-- definition as 20261016120000 (voice), plus sticker_id and sticker_album.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll, m.contact, m.attachment_name,
       m.attachment_duration_ms, m.location_lat, m.attachment_mime,
       m.sticker_id, m.sticker_album
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll,
           mm.contact, mm.attachment_name, mm.attachment_duration_ms, mm.location_lat,
           mm.attachment_mime, mm.sticker_id, mm.sticker_album
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

-- Push text: "Sticker" for a sticker, "Sticker album" for an album card. Same
-- body as 20261016120000 with those two branches added first.
create or replace function app_private.push_targets_for_message(message_id uuid)
returns table (user_id uuid, token text, platform text, conversation_id uuid,
               title text, body text, shows_itself boolean,
               sender text, chat text, badge integer)
language sql stable security definer set search_path = '' as $$
  select d.user_id, d.token, d.platform, m.conversation_id,
         case coalesce(ns.preview, 'full')
           when 'none' then 'SIS'
           when 'sender' then coalesce(p.display_name, 'Someone')
           else coalesce(p.display_name, 'Someone') || coalesce(' @ ' || c.title, '')
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
              else coalesce(p.display_name, 'Someone') end,
         case when coalesce(ns.preview, 'full') = 'none' then null
              else c.title end,
         app_private.unread_total(cm.user_id)
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
