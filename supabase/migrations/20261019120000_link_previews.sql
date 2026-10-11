-- Update 2 step 11a: link preview cards on chat messages.
--
--  * A message may carry a card in messages.link_preview (jsonb): url, title,
--    and optionally description, site, image (a path in the link-previews
--    bucket) and video (the link is on a video site). The sender's phone reads
--    the page once and sends the card with the message; readers never contact
--    the website.
--  * The private `link-previews` bucket holds the card picture as
--    `<conversation id>/<message id>.jpg` (256 KB, jpeg/png/webp), readable
--    and writable by members of that conversation only, never changed after.
--  * messages_link_preview_guard validates the card on every write (text only,
--    http/https url, capped lengths, picture inside the message's own
--    conversation folder) and accepts it on plain text messages only. An edit
--    or a delete for everyone drops the card.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('link-previews', 'link-previews', false, 262144, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists link_previews_read on storage.objects;
create policy link_previews_read on storage.objects for select to authenticated
  using (bucket_id = 'link-previews'
         and (select app_private.has_app_access())
         and app_private.is_member_of_path(name));

drop policy if exists link_previews_write on storage.objects;
create policy link_previews_write on storage.objects for insert to authenticated
  with check (bucket_id = 'link-previews'
              and (select app_private.has_app_access())
              and app_private.is_member_of_path(name)
              and owner_id = (select auth.uid())::text);
-- No update or delete policy: card pictures are immutable, like attachments.

alter table public.messages add column link_preview jsonb;
grant insert (link_preview) on public.messages to authenticated;

create function app_private.messages_link_preview_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  lp jsonb := new.link_preview;
  k text;
begin
  if tg_op = 'UPDATE' and (new.deleted is not null or new.body is distinct from old.body) then
    new.link_preview := null;
    return new;
  end if;
  if lp is null then
    return new;
  end if;

  -- jsonb_typeof(null) is null, so every type check uses "is distinct from":
  -- a MISSING key fails too.
  if jsonb_typeof(lp) is distinct from 'object' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  for k in select jsonb_object_keys(lp) loop
    if k not in ('url', 'title', 'description', 'site', 'image', 'video') then
      raise exception 'invalid link preview' using errcode = 'LNKP1';
    end if;
  end loop;

  if jsonb_typeof(lp->'url') is distinct from 'string'
     or lp->>'url' !~* '^https?://[^[:space:]<>"]+$'
     or char_length(lp->>'url') > 2000 then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if jsonb_typeof(lp->'title') is distinct from 'string'
     or char_length(lp->>'title') not between 1 and 200 then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'description'
     and (jsonb_typeof(lp->'description') is distinct from 'string'
          or char_length(lp->>'description') > 400) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'site'
     and (jsonb_typeof(lp->'site') is distinct from 'string'
          or char_length(lp->>'site') > 100) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- Text only, never markup.
  if lp->>'title' ~ '[[:cntrl:]<>]'
     or coalesce(lp->>'description', '') ~ '[[:cntrl:]<>]'
     or coalesce(lp->>'site', '') ~ '[[:cntrl:]<>]' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  if lp ? 'image'
     and (jsonb_typeof(lp->'image') is distinct from 'string'
          or char_length(lp->>'image') not between 3 and 400
          or lp->>'image' ~ '[[:cntrl:]]'
          or left(lp->>'image', 37) is distinct from new.conversation_id::text || '/') then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'video' and jsonb_typeof(lp->'video') is distinct from 'boolean' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- A card rides on a plain text message only.
  if new.attachment_path is not null or new.sticker_id is not null
     or new.sticker_album or new.poll or new.contact
     or new.location_lat is not null or new.deleted is not null then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_link_preview_guard() from public, anon, authenticated;
create trigger messages_link_preview_guard
  before insert or update of body, deleted, link_preview on public.messages
  for each row execute function app_private.messages_link_preview_guard();
