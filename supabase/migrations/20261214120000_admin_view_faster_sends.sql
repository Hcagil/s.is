-- raises the admin view down-send limit from 120 to 720 per hour so the computer may send every 5 s; every other check unchanged
--
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
  if v_n > 720 then
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
