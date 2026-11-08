-- Small photo copy `<path>.s`: follows the photo's read, removal and cleanup rules (like the `.t` copy).

create or replace function app_private.attachment_readable(
  object_name text,
  object_owner_id text
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  head text := (storage.foldername(object_name))[1];
begin
  if head is null or head !~
     '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  then
    return false;
  end if;
  return (object_owner_id = auth.uid()::text and app_private.was_member(head::uuid))
      or exists (
           select 1 from public.messages m
            where m.attachment_path = object_name
              and app_private.message_readable(m.*)
         )
      or (object_name ~ '\.t$' and exists (
           select 1 from public.messages m
            where m.attachment_path = left(object_name, -2)
              and (m.attachment_duration_ms is not null or m.attachment_name is null)
              and app_private.message_readable(m.*)
         ))
      or (object_name ~ '\.s$' and exists (
           select 1 from public.messages m
            where m.attachment_path = left(object_name, -2)
              and m.attachment_name is null
              and m.attachment_duration_ms is null
              and app_private.message_readable(m.*)
         ));
end $$;
revoke all on function app_private.attachment_readable(text, text) from public, anon;
grant execute on function app_private.attachment_readable(text, text) to authenticated;

create or replace function app_private.may_remove_attachment(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1
                   from app_private.deleted_attachments d
                   join storage.objects o
                     on o.bucket_id = 'attachments' and o.name = object_name
                  where d.path = case when object_name ~ '\.[ts]$'
                                      then left(object_name, -2) else object_name end
                    and d.user_id = auth.uid()
                    and o.created_at <= d.recorded_at)
     and not exists (select 1 from public.messages m
                      where m.attachment_path = case when object_name ~ '\.[ts]$'
                                                     then left(object_name, -2) else object_name end)
$$;


create or replace function public.delete_message(message uuid) returns text language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
  age interval;
  is_group boolean;
  by_admin boolean;
begin
  if not app_private.has_app_access() then raise exception 'not permitted' using errcode = '42501'; end if;
  select * into m from public.messages where id = message for update;
  if not found or m.deleted is not null or not app_private.is_member(m.conversation_id)
     then raise exception 'not permitted' using errcode = '42501';
  end if;
  age := now() - m.created_at;
  is_group := exists(select 1 from public.conversations c where c.id = m.conversation_id and c.direct_key is null);
  -- rule 12: a 1:1 chat with a bot account allows delete for me only
  if not is_group and exists(select 1 from public.conversation_members cm join app_private.bot_accounts b on b.user_id = cm.user_id
                              where cm.conversation_id = m.conversation_id and cm.user_id <> auth.uid())
     then raise exception 'not permitted' using errcode = '42501';
  end if;
  if m.sender_id = auth.uid() and age <= interval '6 hours' then by_admin := false;
  elsif is_group and app_private.is_admin(m.conversation_id) and app_private.message_readable(m) then by_admin := true;
  else raise exception 'not permitted' using errcode = '42501'; end if;
  if m.attachment_path is not null then
    insert into app_private.deleted_attachments(path, user_id) values (m.attachment_path, auth.uid())
    on conflict (path) do update set user_id = excluded.user_id, recorded_at = now();
  end if;
  if m.attachment_path is not null then
    insert into app_private.storage_removal_queue(bucket, path) values ('attachments', m.attachment_path), ('attachments', m.attachment_path || '.t'), ('attachments', m.attachment_path || '.s') on conflict (bucket, path) do nothing;
  end if;
  -- always: an earlier edit may have cleared link_preview while the picture stayed in Storage
  insert into app_private.storage_removal_queue(bucket, path) values ('link-previews', m.conversation_id::text || '/' || m.id::text || '.jpg') on conflict (bucket, path) do nothing;
  delete from public.polls where message_id = message; -- poll_options and poll_votes cascade
  delete from public.message_reactions where message_id = message;
  update public.messages set body = '', sticker_album = false, ciphertext = null, olm_type = null, attachment_path = null, attachment_preview = null, attachment_name = null, attachment_mime = null, attachment_size = null, attachment_duration_ms = null, attachment_waveform = null, voice_transcript = null, location_lat = null, location_lng = null, photo_group = null, sticker_id = null, sticker_album_id = null, link_preview = null, edited_at = null, deleted = case when not by_admin and age < interval '15 minutes' then 'vanished' else 'placeholder' end, deleted_at = now(), deleted_by = auth.uid(), deleted_by_admin = by_admin where id = message;
  return m.attachment_path;
end
$$;
revoke all on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;

create or replace function app_private.cleanup_empty_groups(batch int default 50)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  g record;
  n_msgs int;
  n_files int;
  done int := 0;
begin
  for g in
    select c.id, c.avatar_path
    from public.conversations c
    where c.title is not null
      and not c.system
      and not exists (
        select 1
        from public.conversation_members cm
        where cm.conversation_id = c.id
          and cm.left_at is null
          and not app_private.is_bot(cm.user_id)
      )
      and coalesce(
        (select max(cm.left_at)
         from public.conversation_members cm
         where cm.conversation_id = c.id),
        c.created_at
      ) <= now() - interval '90 days'
      and (
        c.avatar_path is not null
        or exists (
          select 1
          from public.messages m
          where m.conversation_id = c.id
        )
      )
    order by c.id
    limit batch
    for update of c
    skip locked
  loop
    -- a. Queue message attachments and link previews
    insert into app_private.storage_removal_queue(bucket, path)
      select 'attachments', m.attachment_path
      from public.messages m
      where m.conversation_id = g.id
        and m.attachment_path is not null
      union
      select 'attachments', m.attachment_path || '.t'
      from public.messages m
      where m.conversation_id = g.id
        and m.attachment_path is not null
      union
      select 'attachments', m.attachment_path || '.s'
      from public.messages m
      where m.conversation_id = g.id
        and m.attachment_path is not null
      union
      select 'link-previews', g.id::text || '/' || m.id::text || '.jpg'
      from public.messages m
      where m.conversation_id = g.id
        and (m.link_preview is not null or m.edited_at is not null)
    on conflict (bucket, path) do nothing;
    get diagnostics n_files = row_count;

    -- b. Queue avatar if present
    if g.avatar_path is not null then
      insert into app_private.storage_removal_queue(bucket, path)
        values ('avatars', g.avatar_path)
      on conflict (bucket, path) do nothing;
      update public.conversations
      set avatar_path = null
      where id = g.id;
    end if;

    -- c. Delete polls and reactions (poll options and votes cascade)
    delete from public.polls
    where message_id in (
      select id from public.messages where conversation_id = g.id
    );
    delete from public.message_reactions
    where message_id in (
      select id from public.messages where conversation_id = g.id
    );

    -- d. Delete messages
    delete from public.messages where conversation_id = g.id;
    get diagnostics n_msgs = row_count;

    -- e. Log the cleanup
    insert into app_private.group_cleanup_log(
      conversation_id, messages_removed, files_queued, avatar_queued
    ) values (
      g.id, n_msgs, n_files, g.avatar_path is not null
    );

    done := done + 1;
  end loop;

  return done;
end $$;

revoke all on function app_private.cleanup_empty_groups(int) from public, anon, authenticated;

-- Called by the storage-sweeper edge function using the service role.
create or replace function public.sweeper_claim(batch int)
  returns table(id bigint, bucket text, path text)
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  ids bigint[];
begin
  -- a path a live message (or group / profile picture) still uses is never removed: drop it from the queue
  delete from app_private.storage_removal_queue q where (
    (q.bucket = 'attachments' and exists (select 1 from public.messages m where m.attachment_path = case when q.path ~ '\.[ts]$' then left(q.path, -2) else q.path end))
    or (q.bucket = 'link-previews' and exists (select 1 from public.messages m where m.link_preview is not null and q.path = m.conversation_id::text || '/' || m.id::text || '.jpg'))
    or (q.bucket = 'avatars' and (exists (select 1 from public.conversations c where c.avatar_path = q.path) or exists (select 1 from public.profiles p where p.avatar_path = q.path))));
  -- only buckets re-checked above are handed out; other rows stay queued. A 0-row result means nothing claimable is left.
  ids := array(select q.id from app_private.storage_removal_queue q where q.bucket in ('attachments', 'link-previews', 'avatars') order by q.attempts, q.id limit greatest(least(batch, 200), 1) for update skip locked);
  update app_private.storage_removal_queue q set attempts = q.attempts + 1 where q.id = any(ids);
  return query select q.id, q.bucket, q.path from app_private.storage_removal_queue q where q.id = any(ids) order by q.id;
end;
$$;
revoke all on function public.sweeper_claim(int) from public, anon, authenticated;
grant execute on function public.sweeper_claim(int) to service_role;
