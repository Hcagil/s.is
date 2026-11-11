-- answers 'active' | 'replaced' | 'not_allowed'; the old boolean activate_session() stays for old app builds.
create or replace function public.activate_session_status() returns text
language plpgsql security definer set search_path = '' as $$
declare
  sid     uuid := app_private.jwt_session_id();
  created timestamptz;
begin
  if auth.uid() is not null and not app_private.is_allowed_user() then
    return 'not_allowed';
  end if;
  if auth.uid() is null or sid is null then
    return 'replaced';
  end if;
  select s.created_at into created
    from auth.sessions s
   where s.id = sid and s.user_id = auth.uid();
  if not found then
    return 'replaced';
  end if;
  insert into app_private.active_sessions(user_id, session_id, session_created_at)
  values (auth.uid(), sid, created)
  on conflict (user_id) do update
    set session_id = excluded.session_id, session_created_at = excluded.session_created_at
    where app_private.active_sessions.session_id <> excluded.session_id
      and excluded.session_created_at > app_private.active_sessions.session_created_at;
  return case when exists (select 1 from app_private.active_sessions
                 where user_id = auth.uid() and session_id = sid) then 'active' else 'replaced' end;
end $$;
revoke all on function public.activate_session_status() from public, anon;
grant execute on function public.activate_session_status() to authenticated;
