-- Tracks five phone facts per user; privacy: five facts only, never the phone's name or any device id.
create table app_private.member_device (
  user_id uuid primary key references auth.users(id) on delete cascade,
  model text not null check (char_length(model) between 1 and 64),
  os_version text not null check (char_length(os_version) between 1 and 32),
  app_version text not null check (char_length(app_version) between 1 and 32),
  build integer not null check (build between 0 and 999999999),
  installer text check (char_length(installer) <= 64),
  updated_at timestamptz not null default now());
create index member_device_updated_idx on app_private.member_device (updated_at);
alter table app_private.member_device enable row level security;  -- no policies: no access
revoke all on table app_private.member_device from public, anon, authenticated;

create function public.report_device_info(p_model text, p_os_version text, p_app_version text, p_build integer, p_installer text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  insert into app_private.member_device (user_id, model, os_version, app_version, build, installer, updated_at)
  values (
    auth.uid(),
    left(coalesce(nullif(btrim(p_model),''),'unknown'),64),
    left(coalesce(nullif(btrim(p_os_version),''),'unknown'),32),
    left(coalesce(nullif(btrim(p_app_version),''),'unknown'),32),
    coalesce(p_build, 0),
    nullif(left(p_installer,64),''),
    now()
  )
  on conflict (user_id) do update set
    model=excluded.model,
    os_version=excluded.os_version,
    app_version=excluded.app_version,
    build=excluded.build,
    installer=excluded.installer,
    updated_at=excluded.updated_at;
end $$;
revoke all on function public.report_device_info(text,text,text,integer,text) from public, anon;
grant execute on function public.report_device_info(text,text,text,integer,text) to authenticated;

create function app_private.cleanup_member_device()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  delete from app_private.member_device where updated_at < now() - interval '90 days';
  get diagnostics v_count = row_count;
  return v_count;
end $$;
revoke all on function app_private.cleanup_member_device() from public, anon, authenticated;

-- Cleanup cron job to remove stale records after 90 days
select cron.schedule('member-device-cleanup', '23 3 * * *', 'select app_private.cleanup_member_device()');
