-- Rule 19 / L1 / L2: daily cleanup of groups that have had no current person for 90 days; the storage sweeper's queue gets an attempts counter.

alter table app_private.storage_removal_queue add column attempts int not null default 0;

-- Log table, no content, no client access
create table app_private.group_cleanup_log (
  id bigint generated always as identity primary key,
  conversation_id uuid not null,
  messages_removed int not null,
  files_queued int not null,
  avatar_queued boolean not null,
  cleaned_at timestamptz not null default now()
);
alter table app_private.group_cleanup_log enable row level security;
revoke all on table app_private.group_cleanup_log from public, anon, authenticated;

-- The conversation row is KEPT so former members keep the chat.
-- Bot 1:1 chats and system chats are excluded because they have no title / are system.
-- The Debug group follows the rule.
-- "Current person" ignores bot members.
-- 90 days count from the last departure.
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
create function public.sweeper_claim(batch int)
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
    (q.bucket = 'attachments' and exists (select 1 from public.messages m where m.attachment_path = case when q.path ~ '\.t$' then left(q.path, -2) else q.path end))
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

-- Called by the storage-sweeper edge function using the service role.
create function public.sweeper_done(ids bigint[])
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  delete from app_private.storage_removal_queue q where q.id = any(ids);
end;
$$;
revoke all on function public.sweeper_done(bigint[]) from public, anon, authenticated;
grant execute on function public.sweeper_done(bigint[]) to service_role;

create extension if not exists pg_cron;

-- Posts to the storage-sweeper function; does nothing where the Vault secrets are not set (local, CI) or the queue is empty.
create function app_private.run_storage_sweeper() returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  url text;
  secret text;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'sweeper_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'sweeper_secret';
  if url is null or secret is null then
    return;
  end if;
  if not exists (select 1 from app_private.storage_removal_queue) then
    return;
  end if;
  perform net.http_post(
    url := url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-sweeper-secret', secret),
    timeout_milliseconds := 5000
  );
exception when others then
  -- a bad URL must not stop the cron job; the secret is never logged
  raise warning 'run_storage_sweeper: %', sqlerrm;
end $$;
revoke all on function app_private.run_storage_sweeper() from public, anon, authenticated;

-- 03:17 every day: wipe groups that have been without a person for 90 days.
select cron.schedule('group-cleanup', '17 3 * * *', 'select app_private.cleanup_empty_groups()');
-- every 10 minutes: remove queued Storage files through the edge function.
select cron.schedule('storage-sweeper', '*/10 * * * *', 'select app_private.run_storage_sweeper()');
