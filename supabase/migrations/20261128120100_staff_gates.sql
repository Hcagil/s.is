-- The two staff gates call one generic hook; the private code decides what a word does.

create or replace function app_private.admin_on_message() returns trigger
    language plpgsql security definer set search_path = ''
as $$
declare
  pd regprocedure;
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not app_private.is_admin_chat(new.conversation_id)
     or not exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key = 'staff_a')
     or new.sender_id is distinct from (select auth.uid())
     or not exists (select 1 from app_private.owners o where o.user_id = new.sender_id)
  then
    return null;
  end if;

  pd := to_regprocedure('app_private.private_dispatch(uuid,uuid,text)');
  if pd is null then
    return null;
  end if;

  begin
    execute format('select %s($1,$2,$3)', pd::regproc) using new.conversation_id, new.sender_id, new.body;
  exception when others then
    begin
      perform app_private.admin_reply(new.conversation_id, jsonb_build_object('k','err'));
    exception when others then
      null;
    end;
  end;

  return null;
end;
$$;

revoke all on function app_private.admin_on_message() from public, anon, authenticated;

create or replace function app_private.sales_on_message() returns trigger
    language plpgsql security definer set search_path = ''
as $$
declare
  pd regprocedure;
begin
  if new.sender_id = '00000000-0000-0000-0000-00000000ad41'
     or not exists (select 1 from public.conversations c where c.id = new.conversation_id and c.staff_key = 'staff_b')
     or new.sender_id is distinct from (select auth.uid())
     or not (exists (select 1 from app_private.owners o where o.user_id = new.sender_id)
             or exists (select 1 from app_private.command_admins a where a.user_id = new.sender_id))
  then
    return null;
  end if;

  pd := to_regprocedure('app_private.private_dispatch(uuid,uuid,text)');
  if pd is null then
    return null;
  end if;

  begin
    execute format('select %s($1,$2,$3)', pd::regproc) using new.conversation_id, new.sender_id, new.body;
  exception when others then
    begin
      perform app_private.admin_reply(new.conversation_id, jsonb_build_object('k','err'));
    exception when others then
      null;
    end;
  end;

  return null;
end;
$$;

revoke all on function app_private.sales_on_message() from public, anon, authenticated;
