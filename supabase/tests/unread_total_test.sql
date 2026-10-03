-- The app-icon badge (0.30.8): public.unread_total(), the count it shares
-- with unread_counts, and the badge push_targets_for_message carries.
--
-- rua is the subject. Every exclusion is ONE message she would otherwise
-- count, so dropping any single clause changes her total:
--   D1 rua<->sam   2 live unread from sam (count), 1 of her own, 1 deleted,
--                  1 she hid                                  -> 2
--   D2 rua<->tia   conversation muted by rua, 1 from tia      -> 0
--   D3 rua<->uli   uli muted as a person by rua, 1 from uli   -> 0
--   G1 sam,rua,vic rua LEFT; 1 from vic after she left        -> 0
--   G2 sam,rua,wyn rua's history starts late; 1 from sam before it,
--                  1 after it                                 -> 1
-- rua's total: 3.
begin;
select plan(22);

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000b0001', 'ut-rua@example.com', now(), '{"full_name":"Rua"}'),
  ('00000000-0000-0000-0000-0000000b0002', 'ut-sam@example.com', now(), '{"full_name":"Sam"}'),
  ('00000000-0000-0000-0000-0000000b0003', 'ut-tia@example.com', now(), '{"full_name":"Tia"}'),
  ('00000000-0000-0000-0000-0000000b0004', 'ut-uli@example.com', now(), '{"full_name":"Uli"}'),
  ('00000000-0000-0000-0000-0000000b0005', 'ut-vic@example.com', now(), '{"full_name":"Vic"}'),
  ('00000000-0000-0000-0000-0000000b0006', 'ut-wyn@example.com', now(), '{"full_name":"Wyn"}');
insert into app_private.allowlist(email) values
  ('ut-rua@example.com'), ('ut-sam@example.com'), ('ut-tia@example.com'),
  ('ut-uli@example.com'), ('ut-vic@example.com'), ('ut-wyn@example.com');
insert into app_private.tag_finds(finder, found_id) values
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000b0002'),
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000b0003'),
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000b0004'),
  ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0001'),
  ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0005'),
  ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0006');
insert into auth.sessions (id, user_id, created_at, updated_at)
  select ('b0000000-0000-0000-0000-0000000b000' || n)::uuid,
         ('00000000-0000-0000-0000-0000000b000' || n)::uuid, now(), now()
    from generate_series(1, 6) n;

create or replace function test_as(n int) returns void language plpgsql as $$
declare uid uuid := ('00000000-0000-0000-0000-0000000b000' || n)::uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid),
      'session_id', 'b0000000-0000-0000-0000-0000000b000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function u(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000b000' || n)::uuid $$;
grant execute on function u(int) to authenticated;

-- The caller's total, or null when the call is refused.
create function my_total() returns integer language plpgsql security invoker as $$
begin return public.unread_total();
exception when others then return null; end $$;
grant execute on function my_total() to authenticated;

select test_as(1); select is(public.activate_session(), true, 'rua is active'); reset role;
select test_as(2); select is(public.activate_session(), true, 'sam is active'); reset role;
select test_as(3); select ok(public.activate_session(), 'tia is active'); reset role;
select test_as(4); select ok(public.activate_session(), 'uli is active'); reset role;
select test_as(5); select ok(public.activate_session(), 'vic is active'); reset role;
select test_as(6); select ok(public.activate_session(), 'wyn is active'); reset role;

create temp table _c (k text, id uuid);
grant select, insert on _c to authenticated;
select test_as(1);
insert into _c select 'D1', public.start_direct_conversation(u(2));
insert into _c select 'D2', public.start_direct_conversation(u(3));
insert into _c select 'D3', public.start_direct_conversation(u(4));
reset role;
select test_as(2);
insert into _c select 'G1', public.start_group_conversation('ut one', array[u(1), u(5)]);
insert into _c select 'G2', public.start_group_conversation('ut two', array[u(1), u(6)]);
reset role;
create function c(k text) returns uuid language sql as $$ select id from _c where _c.k = $1 $$;
grant execute on function c(text) to authenticated;

-- Everybody last read a day ago, so only the fixtures below are unread.
update public.conversation_members set last_read_at = now() - interval '1 day'
 where conversation_id in (select id from _c);

insert into public.messages(conversation_id, sender_id, body, created_at) values
  (c('D1'), u(2), 'ut live one',  now() - interval '50 minutes'),
  (c('D1'), u(2), 'ut live two',  now() - interval '49 minutes'),
  (c('D1'), u(1), 'ut own',       now() - interval '48 minutes'),
  (c('D1'), u(2), 'ut to hide',   now() - interval '47 minutes'),
  (c('D2'), u(3), 'ut muted chat', now() - interval '46 minutes'),
  (c('D3'), u(4), 'ut muted person', now() - interval '45 minutes'),
  (c('G1'), u(5), 'ut after leaving', now() - interval '10 minutes'),
  (c('G2'), u(2), 'ut before history', now() - interval '2 hours'),
  (c('G2'), u(2), 'ut after history', now() - interval '20 minutes');
insert into public.messages(conversation_id, sender_id, body, created_at, deleted, deleted_at) values
  (c('D1'), u(2), '', now() - interval '44 minutes', 'placeholder', now());
insert into public.notification_mutes(user_id, kind, target) values
  (u(1), 'conversation', c('D2')),
  (u(1), 'person', u(4));
update public.conversation_members set left_at = now() - interval '30 minutes', left_reason = 'left'
 where conversation_id = c('G1') and user_id = u(1);
update public.conversation_members set history_from = now() - interval '90 minutes'
 where conversation_id = c('G2') and user_id = u(1);

create temp table _m as select
  (select id from public.messages where body = 'ut to hide') as hide,
  (select id from public.messages where body = 'ut live one') as live;
grant select on _m to authenticated;

-- 1 privileges: only the caller's own count is reachable ---------------------
select function_privs_are('public', 'unread_total', '{}'::text[], 'authenticated', array['EXECUTE'],
                          'authenticated may execute public.unread_total()');
select function_privs_are('app_private', 'unread_total', array['uuid'], 'authenticated', '{}'::text[],
                          'authenticated holds no execute on app_private.unread_total(uuid)');
select test_as(1);
select throws_ok(format('select app_private.unread_total(%L)', u(2)), '42501', null,
                 'rua cannot read sam''s count through app_private');
reset role;

-- 2 the count ----------------------------------------------------------------
select test_as(1);
select lives_ok(format('select public.hide_message(%L)', (select hide from _m)), 'rua hides one of sam''s');
select is(public.unread_total(), 3,
          'rua: 2 in D1 + 1 in G2; own, deleted, hidden, muted chat, muted person, left and pre-history excluded');
select is((select unread from public.unread_counts() where conversation_id = c('D1')), 2,
          'unread_counts agrees: the hidden message is not unread in D1');
reset role;
select is(app_private.unread_total(u(1)), 3, 'app_private agrees for rua');
select test_as(2);
select is(public.unread_total(), 2, 'sam gets his own count, not rua''s: rua''s one in D1, vic''s one in G1');
reset role;

-- 3 the push badge equals the recipient's unread_total -----------------------
select test_as(1);
select lives_ok($$select public.register_device_token('ut-rua-device', 'android')$$, 'rua registers a phone');
reset role;
select test_as(6);
select lives_ok($$select public.register_device_token('ut-wyn-device', 'android')$$, 'wyn registers a phone');
reset role;
insert into public.messages(conversation_id, sender_id, body) values (c('G2'), u(2), 'ut push me');
create temp table _p as
  select * from app_private.push_targets_for_message(
    (select id from public.messages where body = 'ut push me'));
select is((select badge from _p where user_id = u(1)), 4,
          'rua''s badge counts the new message: 3 + 1');
select is((select badge from _p where user_id = u(1)), app_private.unread_total(u(1)),
          'rua''s badge is her unread_total');
select is((select badge from _p where user_id = u(6)), app_private.unread_total(u(6)),
          'wyn''s badge is HIS unread_total, per recipient');

-- hiding lowers the badge the next push carries
select test_as(1);
select lives_ok(format('select public.hide_message(%L)', (select live from _m)), 'rua hides another');
reset role;
select is((select badge from app_private.push_targets_for_message(
             (select id from public.messages where body = 'ut push me')) where user_id = u(1)), 3,
          'the badge drops with what she hid');

-- 4 without app access: refused, or nothing ----------------------------------
delete from auth.sessions where id = 'b0000000-0000-0000-0000-0000000b0001';
select test_as(1);
select ok(coalesce(my_total(), 0) = 0, 'rua with a revoked session reads no count');
reset role;

select * from finish();
rollback;
