-- Queues chat files no message uses, older than 30 days; the storage-sweeper removes them via the Storage API.

create function app_private.queue_orphan_attachments(batch int default 500) returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with o as (
    select ob.name from storage.objects ob
    where ob.bucket_id = 'attachments'
      and ob.created_at < now() - interval '30 days'
      and not exists (select 1 from public.messages m where m.attachment_path in (ob.name, regexp_replace(ob.name, '\.[ts]$', '')))
      and not exists (select 1 from app_private.storage_removal_queue q where q.bucket = 'attachments' and q.path = ob.name)
    order by ob.created_at
    limit least(greatest(batch, 1), 1000)
  ), ins as (
    insert into app_private.storage_removal_queue(bucket, path) select 'attachments', o.name from o
    on conflict (bucket, path) do nothing returning 1
  ) select count(*) into n from ins;
  return n; end
$$;

revoke all on function app_private.queue_orphan_attachments(int) from public, anon, authenticated;

select cron.schedule('attachment-orphan-cleanup', '41 3 * * *', 'select app_private.queue_orphan_attachments()');
