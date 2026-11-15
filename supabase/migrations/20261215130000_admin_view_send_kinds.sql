-- admin_view_send: p_kind ('read' | 'other'), 240/h for other, separate 720/h cap for read, seq upper bound.

alter table app_private.admin_view_calls drop constraint admin_view_calls_kind_check;
alter table app_private.admin_view_calls add constraint admin_view_calls_kind_check check (kind in ('owner_send','bridge_put','owner_read'));

drop function public.admin_view_send(integer, bigint, bytea);

-- Errors: 42501 not permitted, 22023 bad input, RLMT1 limit hit. p_kind 'read' (720/h) or 'other' (240/h).
create function public.admin_view_send(p_epoch integer, p_seq bigint, p_body bytea, p_kind text default 'other')
returns bigint
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_id bigint;
  v_me uuid := auth.uid();
  v_n integer;
  v_kind text := case when p_kind = 'read' then 'owner_read' else 'owner_send' end;
  v_limit integer := case when p_kind = 'read' then 720 else 240 end;
begin
  if not (app_private.is_owner() and app_private.has_app_access()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_body is null or octet_length(p_body) < 1073 or octet_length(p_body) > 8241 or (octet_length(p_body) - 49) % 1024 <> 0 or p_seq is null or p_seq <= 0 or p_epoch is null then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('read','other') then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('admin_view', 0));
  delete from app_private.admin_view_calls c where c.user_id = v_me and c.kind = v_kind and c.called_at < now() - interval '1 hour';
  insert into app_private.admin_view_calls(user_id, kind) values (v_me, v_kind);
  select count(*) into v_n from app_private.admin_view_calls c where c.user_id = v_me and c.kind = v_kind and c.called_at >= now() - interval '1 hour';
  if v_n > v_limit then
    raise exception 'too many requests' using errcode = 'RLMT1';
  end if;
  if not exists(select 1 from app_private.admin_view_keys k where k.phone_pub is not null and k.computer_pub is not null and k.epoch = p_epoch) then
    raise exception 'invalid request' using errcode = '22023';
  end if;
  if p_seq <= (select k.last_up_seq from app_private.admin_view_keys k) or p_seq > (select k.last_up_seq from app_private.admin_view_keys k) + 1000 then
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
revoke all on function public.admin_view_send(integer, bigint, bytea, text) from public, anon;
grant execute on function public.admin_view_send(integer, bigint, bytea, text) to authenticated;
