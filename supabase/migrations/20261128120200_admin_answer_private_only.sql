-- The answer function only keeps the life of private cards; any other card is stale.

create or replace function public.admin_answer(card uuid, yes boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p app_private.admin_pending;
  conv uuid;
  card_k text;
  pa regprocedure;
begin
  if not (select app_private.has_app_access()) or not (select app_private.is_owner()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  -- lets this function update the card and write replies
  perform set_config('app_private.admin_write', 'on', true);

  select m.conversation_id, m.admin_msg->>'k' into conv, card_k from public.messages m where m.id = card and m.admin_msg->>'k' in ('conf','card');
  if conv is null or not app_private.is_member(conv) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  select * into p from app_private.admin_pending where card_message_id = card for update;

  -- Only a private card ('card' key and a private kind) is answered here; any other card is stale.
  if not found or p.state <> 'pending' or p.expires_at < now()
     or card_k is distinct from 'card' or p.kind is null or p.kind not like 'private:%' then
    -- stale: used before, or expired. Mark an unanswered one expired; the raw email goes.
    update app_private.admin_pending set state = case when state = 'pending' then 'expired' else state end, email = null
     where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
     where id = card and not (admin_msg ? 'st');
    perform app_private.admin_reply(conv, jsonb_build_object('k','keep'));
    return;
  end if;

  if not yes then
    update app_private.admin_pending set state = 'cancelled', email = null where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','cancelled') where id = card;
    insert into app_private.admin_commands(owner_id, command, email_masked, outcome)
    values (auth.uid(), p.kind, p.email_masked, 'cancelled');
    perform app_private.admin_reply(conv, jsonb_build_object('k','canOk'));
    return;
  end if;

  -- The private code does the work; this function only keeps the card's life: used after a clean return, else expired.
  pa := to_regprocedure('app_private.private_answer(uuid,boolean,uuid)');
  if pa is null then
    update app_private.admin_pending set state = 'expired', email = null where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
     where id = card and not (admin_msg ? 'st');
    perform app_private.admin_reply(conv, jsonb_build_object('k','keep'));
    return;
  end if;
  begin
    execute format('select %s($1,$2,$3)', pa::regproc) using card, yes, conv;
  exception when others then
    perform set_config('app_private.admin_write', 'on', true);
    update app_private.admin_pending set state = 'expired', email = null where card_message_id = card;
    update public.messages set admin_msg = admin_msg || jsonb_build_object('st','expired')
     where id = card and not (admin_msg ? 'st');
    perform app_private.admin_reply(conv, jsonb_build_object('k','err'));
    return;
  end;
  -- the private code's own replies switch the write permission off again
  perform set_config('app_private.admin_write', 'on', true);
  update app_private.admin_pending set state = 'used', email = null where card_message_id = card;
  update public.messages set admin_msg = admin_msg || jsonb_build_object('st','done') where id = card;
end $$;
revoke all on function public.admin_answer(uuid, boolean) from public, anon;
grant execute on function public.admin_answer(uuid, boolean) to authenticated;
