-- Per-chat alert sound and vibration settings, with account-level defaults.
-- The push sender (service_role) reads the resolved values via public.push_alerts.

alter table public.notification_settings
  add column alert_sound boolean not null default true,
  add column alert_vibration boolean not null default true;

create table public.chat_alert_settings (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sound text not null default 'default' check (sound in ('default','on','off')),
  vibration text not null default 'default' check (vibration in ('default','on','off')),
  updated_at timestamptz not null default now(),
  primary key (user_id, conversation_id)
);

create index chat_alert_settings_conversation_idx on public.chat_alert_settings(conversation_id);

alter table public.chat_alert_settings enable row level security;

revoke all on table public.chat_alert_settings from anon, authenticated;
grant select, insert, update, delete on table public.chat_alert_settings to authenticated;

create policy chat_alert_settings_own on public.chat_alert_settings
  for all to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check ((select app_private.has_app_access()) and user_id = (select auth.uid()) and app_private.is_member(conversation_id));

create function public.push_alerts(conversation uuid, users uuid[])
returns table (user_id uuid, sound boolean, vibration boolean)
language sql stable security definer set search_path = ''
as $$
  select u.id,
    case c.sound when 'on' then true when 'off' then false else coalesce(ns.alert_sound, true) end,
    case c.vibration when 'on' then true when 'off' then false else coalesce(ns.alert_vibration, true) end
  from unnest(users) as u(id)
  left join public.chat_alert_settings c on c.user_id = u.id and c.conversation_id = push_alerts.conversation
  left join public.notification_settings ns on ns.user_id = u.id
$$;

revoke all on function public.push_alerts(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.push_alerts(uuid, uuid[]) to service_role;
