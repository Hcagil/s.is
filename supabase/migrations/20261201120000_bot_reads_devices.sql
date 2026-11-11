-- Bot read access to a short list of member device details.

create function public.bot_member_devices()
returns table(tag text, display_name text, model text, os_version text, app_version text, build integer, installer text, last_seen timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from app_private.bot_accounts b where b.user_id = auth.uid() and b.enabled) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query
    select p.tag,
      p.display_name,
      regexp_replace(d.model, '[^[:alnum:] ._()+/-]', '', 'g'),
      regexp_replace(d.os_version, '[^[:alnum:] ._()+/-]', '', 'g'),
      regexp_replace(d.app_version, '[^[:alnum:] ._()+/-]', '', 'g'),
      d.build,
      regexp_replace(d.installer, '[^[:alnum:] ._()+/-]', '', 'g'),
      d.updated_at
    from app_private.bot_contacts k
    join app_private.member_device d on d.user_id = k.contact_id
    join public.profiles p on p.user_id = k.contact_id
    where k.bot_id = auth.uid()
    order by d.updated_at desc
    limit 500;
end $$;

revoke all on function public.bot_member_devices() from public, anon;
grant execute on function public.bot_member_devices() to authenticated;
