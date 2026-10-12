-- The card's url must appear in the message body as a WHOLE link, not as a
-- piece of a longer word or address (a body "see evilhttps://a.com.evil.io"
-- no longer vouches for a card naming https://a.com). Only the body check
-- changes; the rest of the guard is copied unchanged from
-- 20261019120000_link_previews.sql.

create or replace function app_private.messages_link_preview_guard() returns trigger
language plpgsql security invoker set search_path = '' as $$
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
     or lp->>'url' !~* '^https?://[^[:space:][:cntrl:]<>"\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]+$'
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
  if lp->>'title' ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'
     or coalesce(lp->>'description', '') ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'
     or coalesce(lp->>'site', '') ~ '[[:cntrl:]<>\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  if lp ? 'image'
     and (jsonb_typeof(lp->'image') is distinct from 'string'
          or lp->>'image' is distinct from new.conversation_id::text || '/' || new.id::text || '.jpg'
          or not exists (select 1 from storage.objects o
                          where o.bucket_id = 'link-previews' and o.name = lp->>'image'
                            and o.owner_id = new.sender_id::text)) then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;
  if lp ? 'video' and jsonb_typeof(lp->'video') is distinct from 'boolean' then
    raise exception 'invalid link preview' using errcode = 'LNKP1';
  end if;

  -- The card must describe a link the message really contains, as a WHOLE
  -- link: after the start, whitespace, an opening bracket or a quote (with or
  -- without the scheme), and before whitespace, the end or closing punctuation.
  -- The url is regex-escaped first so its dots and symbols match literally.
  if coalesce(new.body, '') !~* (
       '(^|[[:space:](<"''])(https?://)?'
       || regexp_replace(
            regexp_replace(lp->>'url', '^https?://', '', 'i'),
            '([.^$*+?()|{}\[\]\\])', '\\\1', 'g')
       || '[.,;:!?)>"'']*([[:space:]]|$)') then
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
