begin;
select plan(63);

-- Delete chat: public.chat_hides, hide_chat(conversation), and
-- delete_direct_chat(conversation) returns text[] (photo paths).
--
-- Written from the contract, not the function bodies:
--   chat_hides: RLS on, SELECT only to clients, own rows only; written only by
--   hide_chat. hide_chat: the caller must be or have been a member and have
--   app access; never the bot. It moves only the caller's history_from up, so
--   old messages are hidden from the caller alone; a later message shows; the
--   caller's pin and archive marks for that chat go. delete_direct_chat: a
--   current member of a real 1:1 (not a group, not the system chat, not one
--   with the bot) removes it for both and gets the photo paths back, each
--   recorded so the caller may remove the files -- and nothing else.
--
-- Each refusal fixture fails ONE gate; its positive control passes the others.
--   ann, bob  1:1 AB, both in group G (ann admin)     cat  in nothing of AB
--   dan       1:1 AD with ann; session revoked last   eve  left group G
--   fay       listed contact of the bot; 1:1 FB       gus, hal  1:1 GH (deleted)
--   hal       also 1:1 HA with ann (a photo NOT to be released)

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select case when n = 'bot' then '00000000-0000-0000-0000-000000b07b07'::uuid
              else ('00000000-0000-0000-0000-0000000dc0' || n)::uuid end
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '@dc.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','eve'),('06','fay'),
               ('07','gus'),('08','hal')) v(n, name);
insert into app_private.allowlist(email)
select name || '@dc.test'
  from unnest(array['ann','bob','cat','dan','eve','fay','gus','hal']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('dc000000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07','08']) n;
insert into app_private.tag_finds(finder, found_id) values
  (u('01'), u('02')), (u('01'), u('04')), (u('01'), u('05')), (u('07'), u('08')), (u('08'), u('01')), (u('08'), u('02'));

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (u('bot'), 'sis-destek-bot@example.com', now(), '{"full_name":"SIS Destek"}');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('b07b0000-0000-0000-0000-000000000001', u('bot'), now() - interval '1 hour', now());
insert into app_private.allowlist(email) values ('sis-destek-bot@example.com') on conflict do nothing;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', case when n = 'bot' then 'b07b0000-0000-0000-0000-000000000001'
                         else 'dc000000-0000-0000-0000-0000000000' || n end)::text, true);
  execute 'set local role authenticated';
end $$;
create function runbook() returns void language sql as $$
  select set_config('request.jwt.claims', '', true); select null::void
$$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function leave_c(c uuid) returns void language plpgsql as $$
begin perform public.leave_group(c); perform commit_check(); end $$;
create function group_c(t text, ms uuid[]) returns uuid language plpgsql as $$
declare r uuid;
begin r := public.start_group_conversation(t, ms); perform commit_check(); return r; end $$;
create function send(c uuid, body text default 'hi') returns void language plpgsql as $$
begin
  insert into public.messages(conversation_id, sender_id, body) values (c, auth.uid(), body);
end $$;
create function sees(c uuid) returns bigint language sql as $$
  select count(*) from public.messages where conversation_id = c
$$;
create temp table ids(name text primary key, id uuid);
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant select, insert on ids to authenticated;
grant execute on function as_(text), u(text), commit_check(), leave_c(uuid), group_c(text, uuid[]),
  send(uuid, text), sees(uuid), g(text) to authenticated;

-- The truth, whatever RLS says (postgres only).
create function hist(c uuid, n text) returns timestamptz language sql as $$
  select history_from from public.conversation_members where conversation_id = c and user_id = u(n)
$$;
create function msgs(c uuid) returns bigint language sql as $$
  select count(*) from public.messages where conversation_id = c
$$;
create function photo(c uuid, n text, file text) returns text language plpgsql as $$
declare p text := c::text || '/' || file;
begin
  insert into storage.objects(bucket_id, name, owner_id, metadata, created_at)
  values ('attachments', p, u(n), '{"size":3}', now() - interval '1 hour');
  insert into public.messages(conversation_id, sender_id, body, attachment_path)
  values (c, u(n), '', p);
  return p;
end $$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07','08'] loop
    perform as_(n); perform public.activate_session(); execute 'reset role';
  end loop;
end $$;

select as_('01');
insert into ids values
  ('AB', public.start_direct_conversation(u('02'))),
  ('AD', public.start_direct_conversation(u('04'))),
  ('G',  group_c('Trip', array[u('02'), u('05')])),
  ('DEBUG', group_c('Debug', array[u('02')]));
select send(g('AB'), 'old 1'); select send(g('AB'), 'old 2');
select send(g('G'), 'old group'); select send(g('AD'), 'to dan');
reset role;
select as_('05'); select send(g('G'), 'eve was here'); select leave_c(g('G')); reset role;
select as_('07'); insert into ids values ('GH', public.start_direct_conversation(u('08'))); reset role;
select as_('08'); insert into ids values ('HA', public.start_direct_conversation(u('01'))),
  ('HB', public.start_direct_conversation(u('02'))); reset role;
select as_('01'); select public.deliver_release_notes(179); reset role;
insert into ids select 'SYS', id from public.conversations
  where system and id in (select conversation_id from public.conversation_members where user_id = u('01'))
  limit 1;

-- the bot, ON, with fay listed; fay starts the 1:1
select runbook();
insert into app_private.bot_accounts(user_id, debug_conversation) values (u('bot'), g('DEBUG'));
update app_private.bot_accounts set enabled = true where user_id = u('bot');
insert into app_private.bot_contacts(bot_id, contact_id) values (u('bot'), u('06'));
select as_('bot'); select public.activate_session(); reset role;
select as_('06'); insert into ids values ('FB', public.start_direct_conversation(u('bot'))); reset role;

-- 1 chat_hides: the table and its grants ---------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.chat_hides'::regclass),
          'chat_hides has RLS on');
select ok(has_table_privilege('authenticated', 'public.chat_hides', 'select'),
          'authenticated may read chat_hides');
select ok(not has_table_privilege('authenticated', 'public.chat_hides', 'insert')
      and not has_table_privilege('authenticated', 'public.chat_hides', 'update')
      and not has_table_privilege('authenticated', 'public.chat_hides', 'delete'),
          'and may not write it');
select ok(not has_table_privilege('anon', 'public.chat_hides', 'select'), 'anon may not read it');
select ok(not has_function_privilege('anon', 'public.hide_chat(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.delete_direct_chat(uuid)', 'execute'),
          'anon may not call hide_chat or delete_direct_chat');
select as_('01');
select throws_ok(format($$insert into public.chat_hides(conversation_id) values (%L)$$, g('AB')),
                 '42501', null, 'a member cannot insert a hide of their own chat directly');
reset role;

-- 2 hide_chat: who is refused ---------------------------------------------------
select as_('03');
select throws_ok(format($$select public.hide_chat(%L)$$, g('AB')), '42501', null,
                 'a non-member (with app access) cannot hide a chat');
reset role;
select as_('bot');
select lives_ok($$select send(g('FB'), 'bot here')$$, 'control: the bot is a current member of FB, with access');
select throws_ok($$select public.hide_chat(g('FB'))$$, '42501', null, 'the bot cannot hide a chat');
reset role;
select ok(not exists (select 1 from public.chat_hides where user_id = u('bot')),
          'and nothing was recorded for the bot');

-- 3 hide_chat by ann on AB ----------------------------------------------------------
-- pins and archives the way the app writes them: as the member. Archiving
-- unpins (pins migration), so pins are checked on AB and archives on G.
select as_('01');
insert into public.chat_pins(conversation_id) values (g('AB')), (g('AD'));
insert into public.chat_archives(conversation_id) values (g('G'));
reset role;
select as_('02');
insert into public.chat_pins(conversation_id) values (g('AB'));
insert into public.chat_archives(conversation_id) values (g('G')), (g('HB'));
reset role;
create temp table before as
  select user_id, conversation_id, history_from from public.conversation_members;

select as_('01');
select is(sees(g('AB')), 2::bigint, 'control: ann reads the two old messages');
select lives_ok($$select public.hide_chat(g('AB'))$$, 'ann hides her 1:1 with bob');
select is(sees(g('AB')), 0::bigint, 'ann no longer reads the old messages');
select is((select count(*) from public.chat_hides where conversation_id = g('AB')), 1::bigint,
          'ann reads her own hide');
reset role;
select ok(hist(g('AB'), '01') > (select history_from from before where conversation_id = g('AB') and user_id = u('01')),
          'ann''s history_from moved up');
select is(hist(g('AB'), '02'), (select history_from from before where conversation_id = g('AB') and user_id = u('02')),
          'bob''s history_from did not move');
select is((select count(*) from public.conversation_members m join before b using (user_id, conversation_id)
            where m.history_from is distinct from b.history_from), 1::bigint,
          'exactly one membership row changed');
select is(msgs(g('AB')), 2::bigint, 'no message was deleted');
select as_('02');
select is(sees(g('AB')), 2::bigint, 'bob still reads everything');
select is((select count(*) from public.chat_hides), 0::bigint, 'bob does not see ann''s hide');
reset role;
select is((select count(*) from public.chat_pins where conversation_id = g('AB')), 1::bigint,
          'ann''s pin of AB is gone, bob''s stays');
select ok(not exists (select 1 from public.chat_pins where conversation_id = g('AB') and user_id = u('01')),
          'the pin removed is ann''s');
select ok(exists (select 1 from public.chat_pins where conversation_id = g('AD') and user_id = u('01')),
          'ann''s pin of another chat stays');

-- a message after the hide (a later transaction in real life: clock_timestamp)
insert into public.messages(conversation_id, sender_id, body, created_at)
values (g('AB'), u('02'), 'new', clock_timestamp() + interval '1 second');
select as_('01');
select is((select array_agg(body) from public.messages where conversation_id = g('AB')), array['new'],
          'ann reads a message sent after the hide, and only that');
reset role;

-- 4 hide_chat: the past member, the group, the system chat ------------------------
select as_('05');
select is(sees(g('G')), 2::bigint, 'control: eve, who left G, still reads its history');
select lives_ok($$select public.hide_chat(g('G'))$$, 'a past member can hide the group she left');
select is(sees(g('G')), 0::bigint, 'and no longer reads it');
reset role;
select as_('02');
select is(sees(g('G')), 2::bigint, 'bob still reads the group');
select lives_ok($$select public.hide_chat(g('G'))$$, 'bob hides the group');
select is((select array_agg(conversation_id) from public.chat_hides), array[g('G')],
          'bob reads exactly his own hide, not ann''s or eve''s');
reset role;
select is((select array_agg(user_id) from public.chat_archives where conversation_id = g('G')), array[u('01')],
          'bob''s archive of G is gone, ann''s stays');
select ok(exists (select 1 from public.chat_archives where conversation_id = g('HB') and user_id = u('02')),
          'bob''s archive of another chat stays');
select as_('01');
select is(sees(g('G')), 2::bigint, 'ann, the admin, still reads the group');
reset role;
select is((select count(*) from public.conversation_members where conversation_id = g('G') and left_at is null),
          2::bigint, 'hiding does not leave the group');

select ok(g('SYS') is not null, 'control: ann has a system chat');
create temp table sys_before as
  select (select count(*) from public.messages where conversation_id = g('SYS')) as n,
         (select count(*) from public.conversation_members where conversation_id = g('SYS')) as m;
select as_('01');
select ok(sees(g('SYS')) > 0, 'control: ann reads her system chat');
select lives_ok($$select public.hide_chat(g('SYS'))$$, 'ann hides her system chat');
select is(sees(g('SYS')), 0::bigint, 'and no longer reads its notes');
reset role;
select is(msgs(g('SYS')), (select n from sys_before), 'the system chat lost no message');
select is((select count(*) from public.conversation_members where conversation_id = g('SYS')),
          (select m from sys_before), 'nor any member');
select is((select count(*) from public.conversation_members m join before b using (user_id, conversation_id)
            where m.conversation_id = g('SYS') and m.user_id <> u('01')
              and m.history_from is distinct from b.history_from), 0::bigint,
          'no other member''s view of the system chat changed');

-- 5 delete_direct_chat: who is refused ------------------------------------------------
select as_('03');
select throws_ok($$select public.delete_direct_chat(g('AD'))$$, '42501', null,
                 'a non-member cannot delete a 1:1');
reset role;
select as_('01');
select throws_ok($$select public.delete_direct_chat(g('G'))$$, '42501', null,
                 'a group member cannot delete a group through it');
select throws_ok($$select public.delete_direct_chat(g('SYS'))$$, '42501', null,
                 'nor the system chat');
reset role;
-- shapes only a superuser can make: each fails one half of "a real 1:1"
select as_('01');
insert into ids values ('NT', group_c('untitled', array[u('02')])),
  ('AE', public.start_direct_conversation(u('05')));
reset role;
update public.conversations set title = null where id = g('NT');
update public.conversations set title = 'named' where id = g('AE');
select as_('01');
select throws_ok($$select public.delete_direct_chat(g('NT'))$$, '42501', null,
                 'a group without a title is still not a 1:1');
select throws_ok($$select public.delete_direct_chat(g('AE'))$$, '42501', null,
                 'nor is a direct chat that carries a title');
reset role;
select as_('06');
select ok(sees(g('FB')) > 0, 'control: fay is a member of her 1:1 with the bot, with access');
select throws_ok($$select public.delete_direct_chat(g('FB'))$$, '42501', null,
                 'a 1:1 with the bot cannot be deleted for both');
reset role;
select ok(exists (select 1 from public.conversations where id = g('FB'))
      and exists (select 1 from public.conversations where id = g('G'))
      and exists (select 1 from public.conversations where id = g('AD')),
          'every refused chat still exists');

-- 6 delete_direct_chat by gus on GH ---------------------------------------------------
create temp table paths as
  select photo(g('GH'), '07', 'gus.jpg') as p union all select photo(g('GH'), '08', 'hal.jpg');
select photo(g('HA'), '08', 'kept.jpg');
grant select on paths to authenticated;
select as_('07');
select send(g('GH'), 'text too');
select is((select array_agg(x order by x) from unnest(public.delete_direct_chat(g('GH'))) x),
          (select array_agg(p order by p) from paths),
          'gus deletes GH for both and gets both photo paths back');
reset role;
select ok(not exists (select 1 from public.conversations where id = g('GH')), 'the conversation is gone');
select is(msgs(g('GH')), 0::bigint, 'with its messages');
select as_('08');
select is((select count(*) from public.conversations where id = g('GH')), 0::bigint, 'hal no longer sees it');
reset role;
select as_('07'); reset role;  -- may_remove_attachment reads the claims as the storage policy would
select ok(app_private.may_remove_attachment(g('GH')::text || '/hal.jpg'),
          'gus may remove hal''s photo of the deleted chat');
select ok(app_private.may_remove_attachment(g('GH')::text || '/gus.jpg'), 'and his own');
select ok(not app_private.may_remove_attachment(g('HA')::text || '/kept.jpg'),
          'but not hal''s photo in another chat');
select as_('08'); reset role;
select ok(not app_private.may_remove_attachment(g('GH')::text || '/gus.jpg'),
          'and hal, who did not delete, gets no release');

-- 7 a revoked session (a member) is refused -------------------------------------------
select as_('04');
select is(sees(g('AD')), 1::bigint, 'control: dan reads AD while his session is live');
reset role;
delete from auth.sessions where user_id = u('04');
select as_('04');
select throws_ok($$select public.hide_chat(g('AD'))$$, '42501', null,
                 'a member whose session was revoked cannot hide');
select throws_ok($$select public.delete_direct_chat(g('AD'))$$, '42501', null,
                 'nor delete his 1:1 for both');
reset role;
select ok(exists (select 1 from public.conversations where id = g('AD')), 'AD still exists');
select as_('01');
select is((select count(*) from public.chat_hides), 2::bigint, 'control: ann reads her two hides (AB, SYS)');
reset role;
delete from auth.sessions where user_id = u('01');
select as_('01');
select is((select count(*) from public.chat_hides), 0::bigint, 'without app access she reads none');
reset role;

select * from finish();
rollback;
