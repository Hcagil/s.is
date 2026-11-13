-- admin view: end-to-end encrypted relay between the owner's phone and one bridge account. The server only stores sealed bytes.

create table app_private.admin_view_keys (
  only_row boolean primary key default true check (only_row),
  phone_pub bytea check (octet_length(phone_pub)=32),
  computer_pub bytea check (octet_length(computer_pub)=32),
  epoch integer not null default 0,
  last_up_seq bigint not null default 0,
  last_down_seq bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table app_private.admin_view_items (
  id bigint generated always as identity primary key,
  dir text not null check (dir in ('down','up')),
  epoch integer not null,
  seq bigint not null check (seq > 0),
  body bytea not null check (octet_length(body) between 1073 and 65585 and (octet_length(body) - 49) % 1024 = 0),
  created_at timestamptz not null default now(),
  unique (dir, epoch, seq)
);

create table app_private.admin_view_calls (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('owner_send','bridge_put')),
  called_at timestamptz not null default now()
);
create index admin_view_calls_user_kind_idx on app_private.admin_view_calls(user_id, kind, called_at);

create table app_private.admin_view_bridge (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

revoke all on app_private.admin_view_keys from public, anon, authenticated;
alter table app_private.admin_view_keys enable row level security;

revoke all on app_private.admin_view_items from public, anon, authenticated;
alter table app_private.admin_view_items enable row level security;

revoke all on app_private.admin_view_calls from public, anon, authenticated;
alter table app_private.admin_view_calls enable row level security;

revoke all on app_private.admin_view_bridge from public, anon, authenticated;
alter table app_private.admin_view_bridge enable row level security;

create or replace function app_private.is_admin_view_bridge()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from app_private.admin_view_bridge b
    where b.user_id = auth.uid()
      and app_private.is_allowed_user()
      and exists (
        select 1 from app_private.active_sessions s
        join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id
        where s.user_id = auth.uid() and s.session_id = app_private.jwt_session_id()
      )
  );
$$;
revoke all on function app_private.is_admin_view_bridge() from public, anon, authenticated;


-- the bridge account may never use the app's own paths.
create or replace function app_private.has_app_access()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select app_private.is_allowed_user()
     and exists (select 1 from app_private.active_sessions s join auth.sessions x on x.id = s.session_id and x.user_id = s.user_id where s.user_id = auth.uid() and s.session_id = app_private.jwt_session_id())
     and not exists (select 1 from app_private.bot_accounts b where b.user_id = auth.uid() and not b.enabled)
     and not exists (select 1 from app_private.admin_view_bridge a where a.user_id = auth.uid());
$$;
revoke all on function app_private.has_app_access() from public, anon, authenticated;
grant execute on function app_private.has_app_access() to authenticated;


-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_state()
returns table(phone_pub bytea, computer_pub bytea, epoch integer)
language plpgsql volatile security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not (app_private.is_owner() and app_private.has_app_access()) then
    return;
  end if;
  return query select k.phone_pub, k.computer_pub, k.epoch from app_private.admin_view_keys k;
  if not found then
    return query select null::bytea, null::bytea, 0;
  end if;
end;
$$;
revoke all on function public.admin_view_state() from public, anon;
grant execute on function public.admin_view_state() to authenticated;

-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_set_phone_key(p_pub bytea)
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_epoch integer;
begin
  if not (app_private.is_owner() and app_private.has_app_access()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_pub is null or octet_length(p_pub) <> 32 then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_view', 0));
  if exists(select 1 from app_private.admin_view_keys k where k.phone_pub = p_pub) then
    select k.epoch into v_epoch from app_private.admin_view_keys k where k.phone_pub = p_pub;
    return v_epoch;
  end if;
  insert into app_private.admin_view_keys(phone_pub, epoch) values (p_pub, 1)
    on conflict (only_row) do update set
      phone_pub = excluded.phone_pub,
      epoch = app_private.admin_view_keys.epoch + 1,
      last_up_seq = 0,
      last_down_seq = 0,
      updated_at = now()
    returning app_private.admin_view_keys.epoch into v_epoch;
  delete from app_private.admin_view_items where true;
  return v_epoch;
end;
$$;
revoke all on function public.admin_view_set_phone_key(bytea) from public, anon;
grant execute on function public.admin_view_set_phone_key(bytea) to authenticated;

-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_fetch(p_after_id bigint)
returns table(id bigint, epoch integer, seq bigint, body bytea, created_at timestamptz)
language plpgsql volatile security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not (app_private.is_owner() and app_private.has_app_access()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select i.id, i.epoch, i.seq, i.body, i.created_at
    from app_private.admin_view_items i
    where i.dir = 'down'
      and i.id > coalesce(p_after_id, 0)
      and i.epoch = (select k.epoch from app_private.admin_view_keys k)
    order by i.id
    limit 200;
end;
$$;
revoke all on function public.admin_view_fetch(bigint) from public, anon;
grant execute on function public.admin_view_fetch(bigint) to authenticated;

-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_send(p_epoch integer, p_seq bigint, p_body bytea)
returns bigint
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id bigint;
  v_me uuid := auth.uid();
  v_n integer;
begin
  if not (app_private.is_owner() and app_private.has_app_access()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_body is null or octet_length(p_body) < 1073 or octet_length(p_body) > 8241 or (octet_length(p_body) - 49) % 1024 <> 0 or p_seq is null or p_seq <= 0 or p_epoch is null then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_view', 0));
  delete from app_private.admin_view_calls c where c.user_id = v_me and c.kind = 'owner_send' and c.called_at < now() - interval '1 hour';
  insert into app_private.admin_view_calls(user_id, kind) values (v_me, 'owner_send');
  select count(*) into v_n from app_private.admin_view_calls c where c.user_id = v_me and c.kind = 'owner_send' and c.called_at >= now() - interval '1 hour';
  if v_n > 60 then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;
  if not exists(select 1 from app_private.admin_view_keys k where k.phone_pub is not null and k.computer_pub is not null and k.epoch = p_epoch) then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  if p_seq <= (select k.last_up_seq from app_private.admin_view_keys k) then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  if (select count(*) from app_private.admin_view_items i where i.dir = 'up') >= 200 then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;
  insert into app_private.admin_view_items(dir, epoch, seq, body) values ('up', p_epoch, p_seq, p_body) returning id into v_id;
  update app_private.admin_view_keys set last_up_seq = p_seq where only_row = true;
  return v_id;
end;
$$;
revoke all on function public.admin_view_send(integer, bigint, bytea) from public, anon;
grant execute on function public.admin_view_send(integer, bigint, bytea) to authenticated;

-- 1. public.admin_view_bridge_state()
-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_bridge_state()
returns table(phone_pub bytea, computer_pub bytea, epoch integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not app_private.is_admin_view_bridge() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select k.phone_pub, k.computer_pub, k.epoch from app_private.admin_view_keys k;
  if not found then
    return query select null::bytea, null::bytea, 0;
  end if;
end;
$$;
revoke all on function public.admin_view_bridge_state() from public, anon;
grant execute on function public.admin_view_bridge_state() to authenticated;

-- 2. public.admin_view_bridge_set_key()
-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_bridge_set_key(p_pub bytea)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_epoch integer;
  v_old bytea;
begin
  if not app_private.is_admin_view_bridge() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_pub is null or octet_length(p_pub) <> 32 then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_view', 0));
  select k.computer_pub into v_old from app_private.admin_view_keys k;
  if v_old is not null and v_old <> p_pub then
    update app_private.admin_view_keys set computer_pub = p_pub, epoch = epoch + 1, last_up_seq = 0, last_down_seq = 0, updated_at = now() where only_row = true returning epoch into v_epoch;
    delete from app_private.admin_view_items where true;
    return v_epoch;
  end if;
  insert into app_private.admin_view_keys(computer_pub) values (p_pub)
    on conflict (only_row) do update set computer_pub = excluded.computer_pub, updated_at = now()
    returning app_private.admin_view_keys.epoch into v_epoch;
  return v_epoch;
end;
$$;
revoke all on function public.admin_view_bridge_set_key(bytea) from public, anon;
grant execute on function public.admin_view_bridge_set_key(bytea) to authenticated;

-- 3. public.admin_view_bridge_put()
-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_bridge_put(p_epoch integer, p_seq bigint, p_body bytea)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_n integer;
  v_id bigint;
  v_keys_row app_private.admin_view_keys%rowtype;
begin
  if not app_private.is_admin_view_bridge() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_body is null or octet_length(p_body) < 1073 or octet_length(p_body) > 65585 or (octet_length(p_body) - 49) % 1024 <> 0 or p_seq is null or p_seq <= 0 or p_epoch is null then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_view', 0));
  delete from app_private.admin_view_calls c where c.user_id = v_me and c.kind = 'bridge_put' and c.called_at < now() - interval '1 hour';
  insert into app_private.admin_view_calls(user_id, kind) values (v_me, 'bridge_put');
  select count(*) into v_n from app_private.admin_view_calls c where c.user_id = v_me and c.kind = 'bridge_put' and c.called_at >= now() - interval '1 hour';
  if v_n > 120 then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;
  select * into v_keys_row from app_private.admin_view_keys where only_row = true;
  if v_keys_row.phone_pub is null or v_keys_row.computer_pub is null or v_keys_row.epoch <> p_epoch then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  if p_seq <= v_keys_row.last_down_seq then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  insert into app_private.admin_view_items(dir, epoch, seq, body) values ('down', p_epoch, p_seq, p_body) returning id into v_id;
  update app_private.admin_view_keys set last_down_seq = p_seq where only_row = true;
  delete from app_private.admin_view_items i where i.dir = 'down' and i.id not in (select j.id from app_private.admin_view_items j where j.dir = 'down' order by j.id desc limit 20);
  return v_id;
end;
$$;
revoke all on function public.admin_view_bridge_put(integer, bigint, bytea) from public, anon;
grant execute on function public.admin_view_bridge_put(integer, bigint, bytea) to authenticated;

-- 4. public.admin_view_bridge_take()
-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_bridge_take(p_after_id bigint)
returns table(id bigint, epoch integer, seq bigint, body bytea, created_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not app_private.is_admin_view_bridge() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return query select i.id, i.epoch, i.seq, i.body, i.created_at from app_private.admin_view_items i where i.dir='up' and i.id > coalesce(p_after_id,0) and i.epoch = (select k.epoch from app_private.admin_view_keys k) order by i.id limit 200;
end;
$$;
revoke all on function public.admin_view_bridge_take(bigint) from public, anon;
grant execute on function public.admin_view_bridge_take(bigint) to authenticated;

-- 5. public.admin_view_bridge_ack()
-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit.
create or replace function public.admin_view_bridge_ack(p_ids bigint[])
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if not app_private.is_admin_view_bridge() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) > 200 then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  delete from app_private.admin_view_items i where i.dir = 'up' and i.id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.admin_view_bridge_ack(bigint[]) from public, anon;
grant execute on function public.admin_view_bridge_ack(bigint[]) to authenticated;

-- 6. Cleanup
create or replace function app_private.cleanup_admin_view() returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from app_private.admin_view_items where created_at < now() - interval '7 days';
  get diagnostics v_n = row_count;
  delete from app_private.admin_view_calls where called_at < now() - interval '1 hour';
  return v_n;
end;
$$;
revoke all on function app_private.cleanup_admin_view() from public, anon, authenticated;
select cron.schedule('admin-view-cleanup', '31 * * * *', 'select app_private.cleanup_admin_view()');

-- The bridge account counts as an automation account: every path that leaves
-- bots out (release-note broadcast, contact search, key claims) now leaves it out too.
create or replace function app_private.is_bot(uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.bot_accounts where user_id = uid)
      or exists (select 1 from app_private.admin_view_bridge where user_id = uid)
$$;
revoke all on function app_private.is_bot(uuid) from public, anon;
grant execute on function app_private.is_bot(uuid) to authenticated;

-- The owner's tester list leaves the bridge account out.
create or replace function app_private.admin_cmd_list(conv uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  select jsonb_build_object(
    'k','list',
    'n', count(*),
    'ios', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform = 'ios'), '[]'::jsonb),
    'and', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform = 'android'), '[]'::jsonb),
    'oth', coalesce(jsonb_agg(a.email order by a.email) filter (where t.platform is null), '[]'::jsonb))
    into r
    from app_private.allowlist a left join app_private.tester_platform t on t.email = a.email
   where not exists (select 1 from auth.users u join app_private.admin_view_bridge b on b.user_id = u.id
                      where lower(u.email) = a.email);
  perform app_private.admin_reply(conv, r);
  return 'ok';
end $$;
revoke all on function app_private.admin_cmd_list(uuid) from public, anon, authenticated;
