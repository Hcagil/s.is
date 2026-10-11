-- Update 2 step 10b: members upload their own sticker images.
--
--  * A sticker image is uploaded by the client to the private `stickers` bucket
--    as `<id>.webp` AFTER create_sticker() made the row. The bucket already
--    limits size (100 KB) and type (image/webp).
--  * A member can own at most 700 stickers (10 albums x 50 + 200 favourites,
--    the most anyone can hold): STKS1.
--  * Known limit (shortcut): a failed upload leaves an unused row that still
--    counts toward the cap; add a cleanup when it matters.

create function public.create_sticker() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  new_id uuid;
begin
  perform app_private.sticker_gate();
  insert into public.stickers(owner_id) values (auth.uid())
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.create_sticker() from public, anon;
grant execute on function public.create_sticker() to authenticated;

create function app_private.stickers_owner_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('stickers_owner:' || new.owner_id, 0));
  if (select count(*) from public.stickers where owner_id = new.owner_id) >= 700 then
    raise exception 'too many stickers' using errcode = 'STKS1';
  end if;
  return new;
end $$;
revoke all on function app_private.stickers_owner_limit() from public, anon, authenticated;
create trigger stickers_owner_limit before insert on public.stickers
  for each row when (new.owner_id is not null)
  execute function app_private.stickers_owner_limit();

-- The bucket: a member may upload `<uuid>.webp` only for a sticker row they own.
-- There is no update and no delete policy: an uploaded image is never replaced.
create function app_private.sticker_object_uploadable(object_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  if object_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.webp$' then
    return false;
  end if;
  return exists (select 1 from public.stickers s
                  where s.id = left(object_name, 36)::uuid
                    and s.owner_id = auth.uid()
                    and not s.starter);
end $$;
revoke all on function app_private.sticker_object_uploadable(text) from public, anon;
grant execute on function app_private.sticker_object_uploadable(text) to authenticated;

drop policy if exists stickers_insert on storage.objects;
create policy stickers_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'stickers'
              and (select app_private.has_app_access())
              and not app_private.is_bot(auth.uid())
              and app_private.sticker_object_uploadable(name));
