begin;
select plan(93);

-- Staff registry and dispatch. Written from the contract, not the migrations:
-- 1. app_private.staff_chats / staff_commands: RLS on, no policy, no grant.
-- 2. public.staff_registry(): rows only for a caller with app access, not the
--    bot account, and a current member of a chat with that staff_key; anyone
--    else gets zero rows, never an error. Each negative subject below passes
--    every gate but one (its positive control runs first).
-- 3. app_private.staff_load(jsonb): no API role may run it; upserts; never
--    deletes chats; deletes commands only of the chat keys in the input;
--    aborts (and changes nothing) on empty / unknown / bad / too long input.
-- 4. dispatch: the typed word is looked up for that chat's staff_key; each
--    handler runs only in its own chat with its own role (tester_* and
--    sales_on/off: staff_a + owner; sales_total: staff_b + command admin);
--    an unknown word gets the unknown reply; the audit keeps the handler key
--    or 'unknown', never the typed text.
-- 5. sales_job_claim / sales_job_finish: service_role only.
-- 6. conversations.staff_key: not client-writable, set by trigger on new staff
--    chats, returned by chat_list().
-- 7. migration applied but rows not loaded yet: every word is unknown.

-- helpers ----------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000005f00' || case n
    when 'own' then '01' when 'adm' then '02' when 'rmv' then '03' when 'lft' then '04'
    when 'nax' then '05' when 'mal' then '06' when 'bot' then '07' end)::uuid $$;
create function s(n text) returns uuid language sql immutable as $$
  select ('5f000000-0000-0000-0000-0000000000' || right(u(n)::text, 2))::uuid $$;
grant execute on function u(text), s(text) to authenticated, anon;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', s(n))::text, true);
  execute 'set local role authenticated';
end $$;
grant execute on function as_(text) to authenticated;

-- staff_registry() rows as [n] sees them, 'chat_key:word:handler' sorted; error -> 'err:<state>'.
create function reg(n text) returns text language plpgsql as $$
declare r text;
begin
  perform as_(n);
  select coalesce(string_agg(chat_key || ':' || word || ':' || handler, ',' order by chat_key, word), '')
    into r from public.staff_registry();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return r;
exception when others then
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'err:' || sqlstate;
end $$;

-- A message [n] types into [conv], inserted as the server sees a client
-- insert (auth.uid() = sender) but past RLS, so only the dispatcher decides.
create function typed(n text, conv uuid, t text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u(n), 'role', 'authenticated')::text, true);
  insert into public.messages(conversation_id, sender_id, body) values (conv, u(n), t);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Server replies (from ...ad41) in [conv] since the last call: their k, in order.
create table seen(id uuid primary key);
create function ks(conv uuid) returns text language plpgsql as $$
declare r text;
begin
  select coalesce(string_agg(m.admin_msg->>'k', ',' order by m.created_at, m.id), '') into r
    from public.messages m
   where m.conversation_id = conv and m.sender_id = '00000000-0000-0000-0000-00000000ad41'
     and m.id not in (select id from seen);
  insert into seen select m.id from public.messages m
   where m.conversation_id = conv and m.id not in (select id from seen);
  return r;
end $$;

create function access_for(n text) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated', 'session_id', s(n))::text, true);
  r := app_private.has_app_access();
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

create function load(p jsonb) returns text language plpgsql as $$
begin
  perform app_private.staff_load(p);
  return 'ok';
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;

-- the canonical neutral rows
create function rows_std(extra jsonb default '[]') returns jsonb language sql as $$
  select jsonb_build_object(
    'chats', jsonb_build_array(
      jsonb_build_object('key','staff_a','title_en','Staff A','title_tr','Ekip A','sort',1),
      jsonb_build_object('key','staff_b','title_en','Staff B','title_tr','Ekip B','sort',2)),
    'commands', jsonb_build_array(
      jsonb_build_object('chat_key','staff_a','word','/addios','handler','tester_add_ios'),
      jsonb_build_object('chat_key','staff_a','word','/addandroid','handler','tester_add_android'),
      jsonb_build_object('chat_key','staff_a','word','/remove','handler','tester_remove'),
      jsonb_build_object('chat_key','staff_a','word','/list','handler','tester_list'),
      jsonb_build_object('chat_key','staff_a','word','/saleson','handler','sales_on'),
      jsonb_build_object('chat_key','staff_a','word','/salesoff','handler','sales_off'),
      jsonb_build_object('chat_key','staff_b','word','/sales','handler','sales_total')) || extra) $$;

create function ncmd() returns bigint language sql as $$ select count(*) from app_private.staff_commands $$;
create function sjobs() returns bigint language sql as $$ select count(*) from app_private.sales_jobs $$;
create function listed(e text) returns bigint language sql as $$ select count(*) from app_private.allowlist where email = e $$;

-- fixtures -------------------------------------------------------------------
-- own  owner (allowlisted, active): staff_a chat, and command admin -> staff_b chat
-- adm  command admin (allowlisted, active): own staff_b chat
-- rmv  command admin, later removed (fails only membership/flag)
-- lft  member of staff_a who leaves (fails only "current member")
-- nax  member of staff_a whose app access is taken away (fails only access)
-- mal  allowlisted, active, in no staff chat (fails only membership)
-- bot  the bot account, allowlisted, active, member of staff_a (fails only "not the bot")
insert into auth.users (id, email, email_confirmed_at)
  select u(n), n || '@sis.test', now() from unnest(array['own','adm','rmv','lft','nax','mal','bot']) n;
insert into app_private.allowlist(email)
  select n || '@sis.test' from unnest(array['own','adm','rmv','lft','nax','mal','bot']) n;
insert into auth.sessions (id, user_id, created_at, updated_at)
  select s(n), u(n), now(), now() from unnest(array['own','adm','rmv','lft','nax','mal','bot']) n;
create function act(n text) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform as_(n);
  r := public.activate_session();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;
select is((select count(*) from unnest(array['own','adm','rmv','lft','nax','mal','bot']) n where act(n)), 7::bigint,
          'fixture: all seven sessions are active');

-- section 7 first: migration applied, staff_load never run
delete from app_private.staff_commands;
insert into app_private.owners(user_id) values (u('own'));
insert into app_private.command_admins(user_id) values (u('adm')), (u('rmv'));
create table chat as
  select m.user_id as who, c.staff_key as k, c.id from public.conversations c
    join public.conversation_members m on m.conversation_id = c.id and m.left_at is null
   where c.staff_key is not null;
create function ca() returns uuid language sql stable as $$ select id from chat where who = u('own') and k = 'staff_a' $$;
create function cb(n text) returns uuid language sql stable as $$ select id from chat where who = u(n) and k = 'staff_b' $$;

-- 6 staff_key set by trigger --------------------------------------------------------
select is((select count(*) from chat where k = 'staff_a'), 1::bigint, 'the owner row makes one staff_a chat (trigger set staff_key)');
select isnt(cb('own'), null, 'the owner has a staff_b chat (trigger set staff_key)');
select isnt(cb('adm'), null, 'a command admin has a staff_b chat');
select ok((select bool_and(admin_chat) from public.conversations where staff_key is not null), 'every staff chat is admin_chat');

-- consume whatever the new chats were born with
select ks(ca()), ks(cb('own')), ks(cb('adm'));
select typed('own', ca(), t) from unnest(array['/addios gap1@mail.test', '/list', '/saleson', '/salesoff']) t;
select is(ks(ca()), 'unk,unk,unk,unk', 'unloaded registry: every staff_a word gets only the unknown reply');
select is(listed('gap1@mail.test'), 0::bigint, 'unloaded registry: nobody is added');
select is((select count(*) from app_private.admin_commands where owner_id = u('own') and command <> 'unknown'), 0::bigint,
          'unloaded registry: the audit only says unknown');
create table j0 as select sjobs() n;
select typed('own', cb('own'), '/sales');
select is(ks(cb('own')), 'podUnk', 'unloaded registry: the staff_b word gets only the unknown reply');
select is(sjobs(), (select n from j0), 'unloaded registry: no sales job');
select is(reg('own'), '', 'unloaded registry: staff_registry has no rows');

-- 3 staff_load -------------------------------------------------------------------
select ok(not has_function_privilege(r, 'app_private.staff_load(jsonb)', 'execute'), r || ' cannot execute staff_load')
  from unnest(array['public', 'anon', 'authenticated', 'service_role']) r;
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid = 'app_private.staff_load(jsonb)'::regprocedure and a.grantee = 0),
          'staff_load is not granted to public');
select as_('own');
select throws_ok($$select app_private.staff_load('{}'::jsonb)$$, '42501', null, 'an authenticated caller is refused');
reset role;

select is(load(rows_std()), 'ok', 'staff_load accepts the neutral rows');
select is(ncmd(), 7::bigint, 'seven commands loaded');
select is(load(rows_std()), 'ok', 'a rerun is accepted');
select is(ncmd(), 7::bigint, 'a rerun converges (no duplicates)');
select is((select title_en || '|' || title_tr from app_private.staff_chats where key = 'staff_b'), 'Staff B|Ekip B', 'titles are upserted');

-- only the chat keys in the input lose commands; chats are never deleted
select is(load(jsonb_build_object(
  'chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en','A2')),
  'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/list','handler','tester_list')))), 'ok',
  'a load naming only staff_a is accepted');
select is((select string_agg(chat_key || word, ',' order by chat_key, word) from app_private.staff_commands),
          'staff_a/list,staff_b/sales', 'staff_a commands not in the input are removed; staff_b commands are kept');
select is((select count(*) from app_private.staff_chats where key in ('staff_a', 'staff_b')), 2::bigint, 'no chat is deleted');
select is(load(rows_std()), 'ok', 'fixture: full rows back');

-- every bad input aborts with the fixed error and changes nothing
create table bad(name text, p jsonb);
insert into bad values
  ('null input', null),
  ('empty object', '{}'),
  ('no commands', jsonb_build_object('chats', rows_std()->'chats', 'commands', '[]'::jsonb)),
  ('no chats', jsonb_build_object('chats', '[]'::jsonb, 'commands', rows_std()->'commands')),
  ('chats not an array', jsonb_build_object('chats', '{}'::jsonb, 'commands', rows_std()->'commands')),
  ('unknown chat key', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_z')),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_z','word','/xx','handler','tester_list')))),
  ('command for a chat not in the input', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a')),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_b','word','/xx','handler','tester_list')))),
  ('command without chat key', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a')),
     'commands', jsonb_build_array(jsonb_build_object('word','/xx','handler','tester_list'))));
select is(load(p), 'P0001:staff_load: bad input', 'staff_load aborts with the fixed error: ' || name) from bad order by name;
-- bad or too long values: the table checks abort the load
create table bad2(name text, p jsonb);
insert into bad2 values
  ('handler outside the seven', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/xx','handler','drop_all')))),
  ('word without slash', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','xx','handler','tester_list')))),
  ('word too long', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/' || repeat('a', 33),'handler','tester_list')))),
  ('help too long', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/xx','handler','tester_list','help_en',repeat('h', 201))))),
  ('title too long', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en',repeat('t', 201))),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/list','handler','tester_list'))));
select matches(load(p), '^23514:', 'staff_load aborts (check violation): ' || name) from bad2 order by name;
select is((select string_agg(chat_key || ':' || word || ':' || handler, ',' order by chat_key, word) from app_private.staff_commands),
          'staff_a:/addandroid:tester_add_android,staff_a:/addios:tester_add_ios,staff_a:/list:tester_list,staff_a:/remove:tester_remove,'
          'staff_a:/salesoff:sales_off,staff_a:/saleson:sales_on,staff_b:/sales:sales_total',
          'after every refused load the commands are unchanged');
select is((select title_en from app_private.staff_chats where key = 'staff_a'), 'Staff A', 'after every refused load the titles are unchanged');

-- 1 tables closed ---------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('app_private.staff_chats'::regclass, 'app_private.staff_commands'::regclass)),
          'RLS is on for both registry tables');
select is((select count(*) from pg_policies where schemaname = 'app_private' and tablename in ('staff_chats', 'staff_commands')), 0::bigint,
          'no policy on the registry tables');
select ok(not has_table_privilege(r, 'app_private.' || t, 'select,insert,update,delete'), r || ' holds nothing on ' || t)
  from unnest(array['staff_chats', 'staff_commands']) t, unnest(array['anon', 'authenticated']) r;

-- 2 staff_registry --------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.staff_registry()', 'execute'), 'anon cannot execute staff_registry');
select is(reg('own'), 'staff_a:/addandroid:tester_add_android,staff_a:/addios:tester_add_ios,staff_a:/list:tester_list,'
  'staff_a:/remove:tester_remove,staff_a:/salesoff:sales_off,staff_a:/saleson:sales_on,staff_b:/sales:sales_total',
  'the owner sees both chats'' commands');
select is(reg('adm'), 'staff_b:/sales:sales_total', 'a command admin sees only staff_b');
select is(reg('mal'), '', 'a user in no staff chat gets zero rows, no error');

-- removed admin: control, then removal
select is(reg('rmv'), 'staff_b:/sales:sales_total', 'control: rmv sees staff_b while a command admin');
delete from app_private.command_admins where user_id = u('rmv');
select is(reg('rmv'), '', 'a removed command admin gets zero rows');

-- left member
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id, role) values (ca(), u('lft'), 'member'), (ca(), u('nax'), 'member'), (ca(), u('bot'), 'member');
select set_config('app_private.admin_write', '', true);
select matches(reg('lft'), '^staff_a:', 'control: a current member of staff_a gets its rows');
select set_config('app_private.admin_write', 'on', true);
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = ca() and user_id = u('lft');
select set_config('app_private.admin_write', '', true);
select is(reg('lft'), '', 'a member who left gets zero rows');

-- no app access
select matches(reg('nax'), '^staff_a:', 'control: nax with app access gets rows');
delete from app_private.allowlist where email = 'nax@sis.test';
select is(access_for('nax'), false, 'fixture: nax has no app access now');
select is(reg('nax'), '', 'a member without app access gets zero rows');

-- bot account
select matches(reg('bot'), '^staff_a:', 'control: the same user before being made the bot account gets rows');
insert into public.conversations(id, title) values ('5f0c0000-0000-0000-0000-000000000001', 'Debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), '5f0c0000-0000-0000-0000-000000000001', true);
select is(access_for('bot'), true, 'fixture: the bot still has app access');
select is(reg('bot'), '', 'the bot account gets zero rows');

-- 4 dispatch ---------------------------------------------------------------------
select is(ks(ca()), '', 'fixture: staff_a replies read');
select ks(cb('own')); select ks(cb('adm'));
delete from app_private.admin_commands; delete from app_private.sales_commands;
update app_private.sales_state set off = false, amount = null, day = null, fetched_at = null, fail_count = 0;

-- positive controls through the same insert path
select typed('own', ca(), '/addandroid ok1@mail.test');
select is(listed('ok1@mail.test'), 1::bigint, 'control: the owner''s staff_a word runs its handler');
select is((select string_agg(command, ',') from app_private.admin_commands), 'tester_add_android', 'the audit keeps the handler key');
select ok((select bool_and(position('/addandroid' in c::text) = 0 and position('ok1@' in c::text) = 0) from app_private.admin_commands c),
          'the audit holds neither the typed word nor the email');
create table j1 as select sjobs() n;
select typed('adm', cb('adm'), '/sales');
select is(sjobs(), (select n from j1) + 1, 'control: a command admin''s staff_b word makes a sales job');
select is((select string_agg(command, ',') from app_private.sales_commands), 'sales_total', 'the sales audit keeps the handler key');
select ks(ca()); select ks(cb('adm'));

-- unknown word
delete from app_private.admin_commands; delete from app_private.sales_commands;
select typed('own', ca(), '/nope zz@mail.test');
select is(ks(ca()), 'unk', 'an unknown staff_a word gets the unknown reply');
select is((select string_agg(command, ',') from app_private.admin_commands), 'unknown', 'its audit says unknown');
select ok((select bool_and(position('nope' in c::text) = 0 and position('zz@' in c::text) = 0) from app_private.admin_commands c),
          'the audit never holds the typed text');
select typed('adm', cb('adm'), '/nope');
select is(ks(cb('adm')), 'podUnk', 'an unknown staff_b word gets the unknown reply');
select ok((select bool_and(command = 'unknown' and position('nope' in c::text) = 0) from app_private.sales_commands c)
           and (select count(*) from app_private.sales_commands) = 1, 'the sales audit says unknown, not the text');

-- handler in the wrong chat: the words exist, but in the other chat
select is(load(rows_std(jsonb_build_array(
  jsonb_build_object('chat_key','staff_b','word','/addx','handler','tester_add_ios'),
  jsonb_build_object('chat_key','staff_b','word','/onx','handler','sales_on'),
  jsonb_build_object('chat_key','staff_a','word','/totalx','handler','sales_total')))), 'ok', 'fixture: cross-chat words loaded');
-- sales is switched on, so a job would be made if the handler ran
update app_private.sales_state set off = false, amount = null, day = null, fetched_at = null, fail_count = 0;
create table j2 as select sjobs() n;
select typed('own', ca(), '/totalx');
select is(sjobs(), (select n from j2), 'sales_total does not run in staff_a');
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id, role) values (ca(), u('mal'), 'member'), (cb('adm'), u('mal'), 'member');
select set_config('app_private.admin_write', '', true);
select typed('mal', cb('adm'), '/sales');
select is(sjobs(), (select n from j2), 'a staff_b member who is not a command admin cannot run sales_total');
select is((select count(*) from app_private.sales_commands where user_id = u('mal')), 0::bigint, 'and nothing is run or audited for them');

update app_private.sales_state set off = true;
select typed('own', cb('own'), '/addx wc1@mail.test');
select is(listed('wc1@mail.test'), 0::bigint, 'tester_add_ios does not run in staff_b, even for the owner');
select typed('own', cb('own'), '/onx');
select is((select off from app_private.sales_state), true, 'sales_on does not run in staff_b, even for the owner');

-- wrong role in the right chat
select typed('mal', ca(), '/addios wr1@mail.test');
select is(listed('wr1@mail.test'), 0::bigint, 'a staff_a member who is not the owner cannot run tester_add_ios');
select typed('mal', ca(), '/saleson');
select is((select off from app_private.sales_state), true, 'a staff_a member who is not the owner cannot run sales_on');
select typed('own', ca(), '/saleson');
select is((select off from app_private.sales_state), false, 'control: the owner runs sales_on in staff_a');

-- 5 sales job functions ------------------------------------------------------------
select ok(not has_function_privilege(r, f, 'execute'), r || ' cannot execute ' || f)
  from unnest(array['public.sales_job_claim(uuid)', 'public.sales_job_finish(uuid, text, text)']) f,
       unnest(array['public', 'anon', 'authenticated']) r;
select ok(has_function_privilege('service_role', f, 'execute'), 'service_role may execute ' || f)
  from unnest(array['public.sales_job_claim(uuid)', 'public.sales_job_finish(uuid, text, text)']) f;

-- 6 staff_key from a client and chat_list ---------------------------------------------
select ok(not has_column_privilege('authenticated', 'public.conversations', 'staff_key', 'INSERT')
          and not has_column_privilege('authenticated', 'public.conversations', 'staff_key', 'UPDATE'),
          'authenticated cannot write staff_key');
select as_('own');
select throws_ok(format($$update public.conversations set staff_key = 'staff_b' where id = %L$$, ca()), '42501', null,
                 'the owner cannot change the staff_key of their own staff chat');
select is((select e->>'staff_key' from jsonb_array_elements(public.chat_list()->'conversations') e where (e->>'id')::uuid = ca()),
          'staff_a', 'chat_list returns staff_key');
reset role;
select is((select staff_key from public.conversations where id = ca()), 'staff_a', 'staff_key unchanged');

select * from finish();
rollback;
