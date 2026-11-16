-- Admin view down events trigger a private Realtime broadcast.
-- Only the owner receives the broadcast on topic 'admin_view'.

create function app_private.admin_view_push() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(jsonb_build_object('id', new.id), 'down', 'admin_view', true);
  return null;
end $$;
revoke all on function app_private.admin_view_push() from public, anon, authenticated;

create trigger admin_view_push_down
  after insert on app_private.admin_view_items
  for each row
  when (new.dir = 'down')
execute function app_private.admin_view_push();

create policy admin_view_receive on realtime.messages for select to authenticated
  using (
    extension = 'broadcast'
    and realtime.topic() = 'admin_view'
    and (select app_private.has_app_access())
    and (select app_private.is_owner())
  );
