-- A bot must never be promoted to admin when an admin's account is deleted.
-- If only bots remain, nobody is promoted.
-- This ensures human oversight for administrative roles.
create or replace function app_private.promote_on_member_deleted() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  conv uuid := old.conversation_id;
begin
  if old.left_at is null and old.role = 'admin'
     and exists (select 1 from public.conversations c where c.id = conv and c.title is not null)
     and exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null and not app_private.is_bot(user_id)
     )
     and not exists (
       select 1 from public.conversation_members
        where conversation_id = conv and left_at is null and role = 'admin'
     )
  then
    update public.conversation_members
       set role = 'admin'
     where id = (
       select id from public.conversation_members
        where conversation_id = conv and left_at is null and not app_private.is_bot(user_id)
        order by joined_at asc, user_id asc
        limit 1
        for update
     );
  end if;
  return null;
end $$;
revoke all on function app_private.promote_on_member_deleted() from public, anon, authenticated;
