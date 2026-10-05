begin;
select plan(121);

-- Delivery marks (Update 1 slice 5a): conversation_members.delivered_at,
-- public.mark_delivered(), mark_read()'s delivery advance, read_marks()'s
-- delivered_at, the delivered:<conversation> broadcast and its receive branch.
-- Two grey ticks mean delivered to EVERY recipient, so a member's delivery is
-- reported whatever her read-receipt switch says.
--
-- Written from the contract, not the migration:
--   mark_delivered(conv, up_to default null): 42501 'not permitted' without
--   app access or without a CURRENT membership. The position snaps to a real
--   message: max(created_at) of the conversation's messages with created_at
--   <= least(coalesce(up_to, now()), now()); none -> no-op. It only moves the
--   caller's own delivered_at forward, and a call that changes nothing does
--   not rewrite the row (same ctid) and sends nothing. mark_read advances
--   delivered_at the same way (greatest; capped for departed members).
--   Broadcast: private, topic delivered:<conv>, event delivered, payload
--   {user_id, delivered_at}, only on a strict advance.
--
-- Everything runs in one transaction, so now() is one instant T throughout.
-- Group G timeline: m0 T-6h, m1 T-3h, m2 T-1h (a future-dated m3 T+1h is added
-- later). Every current membership starts planted at T-2d.
--
-- People (each refusal fails ONE gate; ada is the positive control):
--   ada  member of G, E, X, B, D            ben  member of G (sharing)
--   cal  member of G, sharing OFF           dan  member of G, delisted later
--   bea  left G at T-5h; current in B       fay  member of G, old phone replaced
--   xan  active, NOT in G; in X with ada    bot  member of D (Debug), OFF/ON

-- fixtures -----------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-0000000deb07'::uuid
              else ('00000000-0000-0000-0000-0000000de1' || n)::uuid end
$$;
create function c(n text) returns uuid language sql immutable as $$
  select ('c0000000-0000-0000-0000-0000000de1' || n)::uuid
$$;
-- G=c('01') E=c('02') X=c('03') B=c('04') D=c('05')
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@delivery.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ada'),('02','ben'),('03','cal'),('04','dan'),('05','bea'),
               ('06','fay'),('08','xan')) v(n, name);
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'bot@delivery.test', now(), '{"full_name":"Bot"}');
insert into app_private.allowlist(email)
select name || '@delivery.test' from unnest(array['ada','ben','cal','dan','bea','fay','xan','bot']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('de100000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','08']) n;
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('de100000-0000-0000-0000-0000000000f6', u('06'), now() - interval '1 hour', now()),
  ('de100000-0000-0000-0000-0000000000b0', u('bot'), now(), now());

create function as_(n text, sess text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', coalesce(sess, case when n = 'bot' then 'de100000-0000-0000-0000-0000000000b0'
                                        else 'de100000-0000-0000-0000-0000000000' || n end))::text, true);
  execute 'set local role authenticated';
end $$;
create function anon_() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;
-- A runbook statement: postgres, no JWT.
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;

-- mark_delivered as the current caller: 'ok', or 'SQLSTATE message'.
create function md(conv uuid, up timestamptz default null) returns text
language plpgsql security invoker as $$
begin
  perform public.mark_delivered(conv, up);
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;
create function mr(conv uuid) returns text language plpgsql security invoker as $$
begin
  perform public.mark_read(conv);
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;
-- read_marks() columns for one target, as the caller.
create function rm_dlv(conv uuid, target uuid) returns timestamptz language sql security invoker as $$
  select delivered_at from public.read_marks(conv) where user_id = target
$$;
create function rm_shares(conv uuid, target uuid) returns boolean language sql security invoker as $$
  select shares from public.read_marks(conv) where user_id = target
$$;
create function rm_read(conv uuid, target uuid) returns timestamptz language sql security invoker as $$
  select read_at from public.read_marks(conv) where user_id = target
$$;
create function can_send(topic text, ext text) returns boolean language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  insert into realtime.messages (topic, extension, payload, event, private)
  values (coalesce(topic, ''), ext, '{}'::jsonb, 'probe', true);
  return true;
exception when insufficient_privilege then
  return false;
end $$;
create function can_receive(topic text, ext text) returns boolean language plpgsql security invoker as $$
begin
  perform set_config('realtime.topic', coalesce(topic, ''), true);
  return exists (select 1 from realtime.messages m where m.extension = ext and m.event = 'fixture');
end $$;
grant execute on function u(text), c(text), md(uuid, timestamptz), mr(uuid),
  rm_dlv(uuid, uuid), rm_shares(uuid, uuid), rm_read(uuid, uuid),
  can_send(text, text), can_receive(text, text) to authenticated, anon;

-- The truth, RLS bypassed (call after reset role). The newest row is the
-- current window (or, for bea in G, her departed one).
create function dlv(conv uuid, n text) returns timestamptz language sql as $$
  select delivered_at from public.conversation_members
   where conversation_id = conv and user_id = u(n) order by joined_at desc limit 1
$$;
create function loc(conv uuid, n text) returns text language sql as $$
  select ctid::text from public.conversation_members
   where conversation_id = conv and user_id = u(n) order by joined_at desc limit 1
$$;
create function sent(conv uuid) returns bigint language sql as $$
  select count(*) from realtime.messages where topic = 'delivered:' || conv::text
$$;
-- Broadcasts on delivered:<conv> carrying exactly this (user, position).
create function sent_for(conv uuid, n text, at timestamptz) returns bigint language sql as $$
  select count(*) from realtime.messages
   where topic = 'delivered:' || conv::text and event = 'delivered' and private
     and extension = 'broadcast'
     and payload->>'user_id' = u(n)::text and (payload->>'delivered_at')::timestamptz = at
$$;
create temp table snap(k text primary key, v text);

do $$
declare n text;
begin
  perform as_('06', 'de100000-0000-0000-0000-0000000000f6');
  perform public.activate_session(); execute 'reset role';
  foreach n in array array['01','02','03','04','05','06','08'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;
select runbook();

insert into public.conversations(id, title) values
  (c('01'), 'dlv G'), (c('02'), 'dlv E'), (c('03'), null), (c('04'), null), (c('05'), 'dlv Debug');
insert into public.conversation_members(conversation_id, user_id) values
  (c('01'), u('01')), (c('01'), u('02')), (c('01'), u('03')), (c('01'), u('04')), (c('01'), u('06')),
  (c('02'), u('01')), (c('02'), u('02')),
  (c('03'), u('01')), (c('03'), u('08')),
  (c('04'), u('01')), (c('04'), u('05')),
  (c('05'), u('01'));
insert into public.conversation_members(conversation_id, user_id, role, joined_at, history_from, left_at, left_reason)
values (c('01'), u('05'), 'member', now() - interval '10 hours', '-infinity', now() - interval '5 hours', 'left');
insert into public.messages(conversation_id, sender_id, body, created_at) values
  (c('01'), u('01'), 'm0', now() - interval '6 hours'),
  (c('01'), u('02'), 'm1', now() - interval '3 hours'),
  (c('01'), u('01'), 'm2', now() - interval '1 hour'),
  (c('03'), u('01'), 'x1', now() - interval '1 hour'),
  (c('04'), u('01'), 'b1', now() - interval '1 hour'),
  (c('05'), u('01'), 'd1', now() - interval '1 hour');
-- The bot: its Debug is D; joined by the runbook, then switched on and active.
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), c('05'));
insert into public.conversation_members(conversation_id, user_id) values (c('05'), u('bot'));
update app_private.bot_accounts set enabled = true where user_id = u('bot');
select as_('bot'); select public.activate_session(); reset role;
select runbook();

update public.profiles set share_read_status = false where user_id = u('03');
update public.conversation_members set delivered_at = now() - interval '2 days',
                                       last_read_at = now() - interval '2 days'
 where conversation_id in (c('01'), c('02'), c('03'), c('04'), c('05')) and left_at is null;
update public.conversation_members set delivered_at = now() - interval '2 days',
                                       last_read_at = now() - interval '9 hours'
 where conversation_id = c('01') and user_id = u('05') and left_at is not null;
insert into realtime.messages (topic, extension, payload, event, private) values
  ('fixture', 'broadcast', '{}'::jsonb, 'fixture', true),
  ('fixture', 'presence',  '{}'::jsonb, 'fixture', true);

-- 1 schema, grants, publication ------------------------------------------------
select col_type_is('public', 'conversation_members', 'delivered_at', 'timestamp with time zone',
                   'delivered_at is a timestamptz');
select col_not_null('public', 'conversation_members', 'delivered_at', 'delivered_at is not null');
select col_default_is('public', 'conversation_members', 'delivered_at', 'now()', 'delivered_at defaults to now()');
select ok(not has_column_privilege('authenticated', 'public.conversation_members', 'delivered_at', 'select'),
          'authenticated cannot select delivered_at');
select ok(not has_column_privilege('anon', 'public.conversation_members', 'delivered_at', 'select'),
          'anon cannot select delivered_at');
select ok(has_function_privilege('authenticated', 'public.mark_delivered(uuid, timestamptz)', 'execute'),
          'authenticated may execute mark_delivered');
select ok(not has_function_privilege('anon', 'public.mark_delivered(uuid, timestamptz)', 'execute'),
          'anon may not execute mark_delivered');
select ok(not has_function_privilege('authenticated', 'app_private.advance_delivery(uuid, timestamptz)', 'execute')
          and not has_function_privilege('anon', 'app_private.advance_delivery(uuid, timestamptz)', 'execute'),
          'no client may execute the internal advance_delivery');
select is((select prosecdef from pg_proc where oid = 'public.mark_delivered(uuid, timestamptz)'::regprocedure),
          true, 'mark_delivered is security definer');
select is(pg_get_function_result('public.read_marks(uuid)'::regprocedure),
          'TABLE(user_id uuid, shares boolean, read_at timestamp with time zone, delivered_at timestamp with time zone)',
          'read_marks returns (user_id, shares, read_at, delivered_at)');
select set_eq($$select schemaname || '.' || tablename from pg_publication_tables where pubname = 'supabase_realtime'$$,
              array['public.messages', 'public.message_reactions'],
              'no table was added to the Realtime publication');
select policies_are('realtime', 'messages', array['realtime_receive', 'realtime_send'],
                    'realtime.messages still has exactly the receive and send policies');
select as_('01');
select throws_ok($$select delivered_at from public.conversation_members$$, '42501', null,
                 'a member cannot read delivered_at directly');
select throws_ok($$select app_private.advance_delivery('c0000000-0000-0000-0000-0000000de101', now())$$,
                 '42501', null, 'a member cannot call advance_delivery');
reset role;
select anon_();
select throws_ok($$select public.mark_delivered('c0000000-0000-0000-0000-0000000de101')$$, '42501', null,
                 'anon cannot call mark_delivered');
reset role;
select runbook();

-- 2 delivered_conversation(): the topic -> uuid mapping ---------------------------
select is(app_private.delivered_conversation('delivered:' || c('01')), c('01'), 'delivered:<uuid> maps to it');
select is(app_private.delivered_conversation('reads:' || c('01')), null, 'reads:<uuid> maps to null');
select is(app_private.delivered_conversation('typing:' || c('01')), null, 'typing:<uuid> maps to null');
select is(app_private.delivered_conversation(c('01')::text), null, 'a bare uuid maps to null');
select is(app_private.delivered_conversation('delivered:'), null, 'nothing after the prefix maps to null');
select is(app_private.delivered_conversation('delivered:not-a-uuid'), null, 'a junk suffix maps to null');
select is(app_private.delivered_conversation('delivered:' || c('01') || 'x'), null, 'a trailing tail maps to null');
select is(app_private.delivered_conversation('xdelivered:' || c('01')), null, 'a leading tail maps to null');
select is(app_private.delivered_conversation(null), null, 'null maps to null');
select lives_ok($$select app_private.delivered_conversation('delivered:zzz')$$, 'a junk topic never raises');

-- 3 mark_delivered: the position snaps to a real message ------------------------
select is(sent(c('01')), 0::bigint, 'nothing broadcast on G yet');
insert into snap values ('ben', loc(c('01'), '02'));
select as_('01');
select is(md(c('01'), now() - interval '2 hours'), 'ok', 'ada marks G delivered up to T-2h');
reset role;
select is(dlv(c('01'), '01'), now() - interval '3 hours', 'ada''s mark snaps back to m1 (T-3h), the newest message at or before T-2h');
select is(sent(c('01')), 1::bigint, 'the advance broadcast once');
select is(sent_for(c('01'), '01', now() - interval '3 hours'), 1::bigint,
          'a private broadcast, event delivered, payload {ada, T-3h}');
select is(dlv(c('01'), '02'), now() - interval '2 days', 'ben''s mark did not move');
select is(loc(c('01'), '02'), (select v from snap where k = 'ben'), 'ben''s row was not even rewritten');

insert into snap values ('ada', loc(c('01'), '01'));
select as_('01');
select is(md(c('01'), now() - interval '150 minutes'), 'ok', 'ada steps up_to between m1 and m2 (F3)');
select is(md(c('01'), now() - interval '4 hours'), 'ok', 'ada calls with an earlier up_to');
select is(md(c('01'), now() - interval '3 hours'), 'ok', 'ada repeats exactly m1');
reset role;
select is(dlv(c('01'), '01'), now() - interval '3 hours', 'a micro-step, a backwards and a repeat call leave her at m1');
select is(loc(c('01'), '01'), (select v from snap where k = 'ada'), 'none of them rewrote her row');
select is(sent(c('01')), 1::bigint, 'none of them broadcast');

select as_('01');
select is(md(c('01'), now() + interval '1 day'), 'ok', 'ada marks up to tomorrow');
reset role;
select is(dlv(c('01'), '01'), now() - interval '1 hour', 'clamped to now(): m2 (T-1h)');
select is(sent_for(c('01'), '01', now() - interval '1 hour'), 1::bigint, 'that advance broadcast {ada, T-1h}');
select is(sent(c('01')), 2::bigint, 'two broadcasts on G in all');
delete from snap where k = 'ada'; insert into snap values ('ada', loc(c('01'), '01'));
select as_('01');
select is(md(c('01'), now() + interval '1 day'), 'ok', 'ada repeats the clamped call');
select is(md(c('01')), 'ok', 'and calls with no up_to');
reset role;
select is(loc(c('01'), '01'), (select v from snap where k = 'ada'), 'a clamped repeat does not rewrite her row');
select is(sent(c('01')), 2::bigint, 'nor broadcast');

select as_('02');
select is(md(c('01')), 'ok', 'ben marks G delivered with no up_to');
reset role;
select is(dlv(c('01'), '02'), now() - interval '1 hour', 'no up_to means now(): ben reaches m2');
select is(sent_for(c('01'), '02', now() - interval '1 hour'), 1::bigint, 'ben''s advance broadcast {ben, T-1h}');

-- the up_to bound is inclusive
select as_('04');
select is(md(c('01'), now() - interval '6 hours'), 'ok', 'dan marks up to exactly m0');
reset role;
select is(dlv(c('01'), '04'), now() - interval '6 hours', 'a message exactly at up_to counts');

-- a future-dated message is not delivered before its time
insert into public.messages(conversation_id, sender_id, body, created_at)
values (c('01'), u('02'), 'm3', now() + interval '1 hour');
delete from snap where k = 'ada'; insert into snap values ('ada', loc(c('01'), '01'));
select as_('01');
select is(md(c('01'), now() + interval '2 hours'), 'ok', 'ada marks up_to past the future message');
reset role;
select is(dlv(c('01'), '01'), now() - interval '1 hour', 'the T+1h message is beyond now(): she stays at m2');
select is(loc(c('01'), '01'), (select v from snap where k = 'ada'), 'and her row is untouched');
select is(sent(c('01')), 4::bigint, 'no broadcast beyond ada''s two, ben''s and dan''s');

-- 4 no message to snap to: a no-op ------------------------------------------------
insert into snap values ('adaE', loc(c('02'), '01'));
select as_('01');
select is(md(c('02')), 'ok', 'ada marks an empty conversation delivered');
select is(md(c('02'), now() - interval '1 hour'), 'ok', 'with an up_to too');
reset role;
select is(dlv(c('02'), '01'), now() - interval '2 days', 'with no messages her mark does not move');
select is(loc(c('02'), '01'), (select v from snap where k = 'adaE'), 'nor is her row rewritten');
select is(sent(c('02')), 0::bigint, 'nor anything broadcast');
insert into public.messages(conversation_id, sender_id, body, created_at)
values (c('02'), u('02'), 'e1', now() + interval '1 hour');
select as_('01');
select is(md(c('02'), now() + interval '2 hours'), 'ok', 'E now holds only a future message');
reset role;
select is(dlv(c('02'), '01'), now() - interval '2 days', 'a message after now() gives nothing to snap to');
select is(sent(c('02')), 0::bigint, 'still nothing broadcast on E');

-- 5 refusals: 42501 not permitted, nothing moved, nothing sent ----------------------
select as_('08');
select is(md(c('03')), 'ok', 'xan marks her own X delivered (control)');
select is(md(c('01')), '42501 not permitted', 'xan, active but not in G, is refused');
select is(md('c0000000-0000-0000-0000-00000000ffff'), '42501 not permitted', 'an unknown conversation is refused');
reset role;
select is(dlv(c('03'), '08'), now() - interval '1 hour', 'control: xan''s X mark moved');
select is((select count(*) from public.conversation_members where conversation_id = c('01') and user_id = u('08')),
          0::bigint, 'xan did not become a member of G');

insert into snap values ('bea', loc(c('01'), '05'));
select as_('05');
select is(md(c('04')), 'ok', 'bea marks B, where she is current (control)');
select is(md(c('01')), '42501 not permitted', 'bea, who left G, is refused there');
reset role;
select is(dlv(c('01'), '05'), now() - interval '2 days', 'bea''s departed G row did not move');
select is(loc(c('01'), '05'), (select v from snap where k = 'bea'), 'nor was it rewritten');

update public.conversation_members set delivered_at = now() - interval '2 days'
 where conversation_id = c('01') and user_id = u('06');
select as_('06', 'de100000-0000-0000-0000-0000000000f6');
select is(md(c('01')), '42501 not permitted', 'fay''s replaced phone is refused');
reset role;
select is(dlv(c('01'), '06'), now() - interval '2 days', 'and moved nothing');
select as_('06');
select is(md(c('01')), 'ok', 'fay''s new phone may (control)');
reset role;
select is(dlv(c('01'), '06'), now() - interval '1 hour', 'control: her new phone moved her mark');

delete from app_private.allowlist where email = 'dan@delivery.test';
select as_('04');
select is(md(c('01')), '42501 not permitted', 'dan, delisted but still a member with his session, is refused');
reset role;
select is(dlv(c('01'), '04'), now() - interval '6 hours', 'dan''s mark did not move');

select as_('bot');
select is(md(c('05'), now() - interval '2 hours'), 'ok', 'the bot, ON, may mark its Debug delivered (control)');
reset role;
update app_private.bot_accounts set enabled = false where user_id = u('bot');
select as_('bot');
select is(md(c('05')), '42501 not permitted', 'the bot, OFF, is refused');
reset role;
select is(dlv(c('05'), 'bot'), now() - interval '2 days', 'the OFF bot''s mark did not move');
select is(sent(c('05')), 0::bigint, 'and nothing was broadcast on Debug');
update app_private.bot_accounts set enabled = true where user_id = u('bot');

-- 6 mark_read advances delivery to the newest message, never to the clock ---------
update public.conversation_members set delivered_at = now() - interval '2 days'
 where conversation_id = c('01') and user_id = u('03');
select as_('03');
select is(mr(c('01')), 'ok', 'cal (receipts off) marks G read');
reset role;
select is(dlv(c('01'), '03'), now() - interval '1 hour',
          'cal''s delivery advances to m2, the newest message at or before now() (F1)');
select cmp_ok(dlv(c('01'), '03'), '<', now(), 'never to the read time itself (F1)');
select is(sent_for(c('01'), '03', now() - interval '1 hour'), 1::bigint,
          'the advance broadcast {cal, T-1h}, although cal shares no read status');
select as_('03');
select is(mr(c('01')), 'ok', 'cal marks G read again, no new message');
reset role;
select is(sent(c('01')), 6::bigint, 'the repeat sends no delivered: broadcast');

select as_('01');
select is(mr(c('01')), 'ok', 'ada, already delivered to m2, marks G read');
reset role;
select is(dlv(c('01'), '01'), now() - interval '1 hour', 'her delivery stays at m2');
select is(sent(c('01')), 6::bigint, 'and nothing is broadcast');

-- departed bea: capped at her leaving (T-5h), and never moved backwards
select as_('05');
select is(mr(c('01')), 'ok', 'bea, departed, marks G read');
reset role;
select cmp_ok(dlv(c('01'), '05'), '<=', now() - interval '5 hours', 'her delivery stops at the moment she left');
select cmp_ok(dlv(c('01'), '05'), '>', now() - interval '2 days', 'control: it did move, up to then');
update public.conversation_members set delivered_at = now() - interval '4 hours'
 where conversation_id = c('01') and user_id = u('05') and left_at is not null;
select as_('05');
select is(mr(c('01')), 'ok', 'bea marks G read again with her delivery planted at T-4h');
reset role;
select is(dlv(c('01'), '05'), now() - interval '4 hours', 'mark_read never moves delivery backwards (greatest)');

-- 7 read_marks reports delivery whatever the read-receipt setting -----------------
select as_('01');
select is(rm_dlv(c('01'), u('02')), now() - interval '1 hour', 'ada sees ben''s delivery (control)');
select is(rm_shares(c('01'), u('03')), false, 'cal shares no read status with ada');
select is(rm_read(c('01'), u('03')), null, 'so her read time is withheld');
select is(rm_dlv(c('01'), u('03')), now() - interval '1 hour', 'but her delivery is still reported');
select is(rm_shares(c('01'), u('04')), false, 'dan, delisted, shows as not sharing');
select is(rm_read(c('01'), u('04')), null, 'with a null read time');
select is(rm_dlv(c('01'), u('04')), now() - interval '6 hours', 'but his delivery is still reported');
select is((select count(*) from public.read_marks(c('01')) where user_id in (u('01'), u('05'))), 0::bigint,
          'neither the caller nor the departed bea is listed');
reset role;
select as_('03');
select is(rm_dlv(c('01'), u('01')), now() - interval '1 hour', 'cal, receipts off herself, still sees ada''s delivery');
reset role;

-- 8 the delivered:<conversation> channel ------------------------------------------
select as_('01');
select ok(can_receive('delivered:' || c('01'), 'broadcast'), 'ada receives on delivered:G');
select ok(not can_receive('delivered:' || c('01'), 'presence'), 'no presence extension on delivered:');
select ok(not can_send('delivered:' || c('01'), 'broadcast'), 'no client may send on delivered:');
select ok(not can_receive('delivered:not-a-uuid', 'broadcast'), 'a junk delivered: topic is closed');
select ok(can_receive('delivered:' || c('05'), 'broadcast'), 'ada receives on delivered:Debug (control for the bot)');
reset role;
select as_('03');
select ok(can_receive('delivered:' || c('01'), 'broadcast'), 'cal, receipts off, still receives delivery');
select ok(not can_receive('reads:' || c('01'), 'broadcast'), 'control: but not reads (the gate this branch skips)');
reset role;
select as_('08');
select ok(can_receive('delivered:' || c('03'), 'broadcast'), 'xan receives on her own delivered:X (control)');
select ok(not can_receive('delivered:' || c('01'), 'broadcast'), 'xan, an outsider, gets nothing on delivered:G');
reset role;
select as_('05');
select ok(can_receive('delivered:' || c('04'), 'broadcast'), 'bea receives on delivered:B (control)');
select ok(not can_receive('delivered:' || c('01'), 'broadcast'), 'bea, departed from G, gets nothing');
reset role;
select as_('06', 'de100000-0000-0000-0000-0000000000f6');
select ok(not can_receive('delivered:' || c('01'), 'broadcast'), 'fay''s replaced phone gets nothing');
reset role;
select as_('04');
select ok(not can_receive('delivered:' || c('01'), 'broadcast'), 'dan, delisted, gets nothing');
reset role;
select as_('bot');
select ok(not can_receive('delivered:' || c('05'), 'broadcast'), 'the bot, ON and a member, gets no Realtime');
reset role;
select as_('02');
select ok(can_receive('typing:' || c('01'), 'broadcast'), 'typing: is still open (regression)');
select ok(can_receive('reads:' || c('01'), 'broadcast'), 'reads: is still open to a sharer (regression)');
reset role;

select * from finish();
rollback;
