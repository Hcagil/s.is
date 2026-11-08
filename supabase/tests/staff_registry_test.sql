begin;
select plan(79);

-- Staff registry. Written from the contract, not the migrations:
-- 1. app_private.staff_chats / staff_commands: RLS on, no policy, no grant.
-- 2. public.staff_registry(): a thin wrapper over the private panel
--    app_private.private_panel() (faked here, in this transaction); rows only
--    for a caller with app access, not the bot account, and a current member
--    of a chat with that staff_key; anyone else gets zero rows, never an
--    error. Each negative subject passes every gate but one (its positive
--    control runs first). Columns arg and ui come through as the panel gives
--    them. Panel missing (no private pack) or raising: zero rows, no error.
-- 3. app_private.staff_load(jsonb): no API role may run it; upserts; never
--    deletes chats; deletes commands only of the chat keys in the input;
--    aborts (and changes nothing) on empty / unknown / bad / too long input.
--    (Stays until the loader is dropped; no longer feeds the registry.)
-- 5. sales_job_claim / sales_job_finish: service_role only.
-- 6. conversations.staff_key: not client-writable, set by trigger on new staff
--    chats, returned by chat_list().
-- (dispatch through the chat gates: private_hook_test.sql)

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

-- staff_registry() rows as [n] sees them, 'chat_key:word:handler:arg:ui' sorted; error -> 'err:<state>'.
create function reg(n text) returns text language plpgsql as $$
declare r text;
begin
  perform as_(n);
  select coalesce(string_agg(chat_key || ':' || word || ':' || handler || ':' || coalesce(arg, '-') || ':' || coalesce(ui, '-'),
                             ',' order by chat_key, word), '')
    into r from public.staff_registry();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return r;
exception when others then
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  return 'err:' || sqlstate;
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

-- the same, plus the error DETAIL and HINT (both must stay empty: no echo of the input)
create function loadx(p jsonb) returns text language plpgsql as $$
declare d text; h text;
begin
  perform app_private.staff_load(p);
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail, h = pg_exception_hint;
  return sqlstate || ':' || sqlerrm || '|' || coalesce(d, '') || '|' || coalesce(h, '');
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


-- the fake panel: what a private pack would return (neutral words)
create or replace function app_private.private_panel()
returns table(chat_key text, title_en text, title_tr text, word text, handler text, arg text, ui text, help_en text, help_tr text, sort int)
language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('qa.panel', true) = 'boom' then raise exception 'fake panel failure'; end if;
  return query values
    ('staff_a', 'Staff A', 'Ekip A', '/addx', 'private', 'email', null::text, 'add', 'ekle', 1),
    ('staff_a', 'Staff A', 'Ekip A', '/listx', 'private', null, null, 'list', 'liste', 2),
    ('staff_b', 'Staff B', 'Ekip B', '/totalx', 'private', null, 'total', 'total', 'toplam', 1);
end $$;
create table want as select
  'staff_a:/addx:private:email:-,staff_a:/listx:private:-:-,staff_b:/totalx:private:-:total'::text a_b,
  'staff_b:/totalx:private:-:total'::text b;

-- 7 panel missing or failing: zero rows, never an error ---------------------------------
select is(reg('own'), (select a_b from want), 'control: the owner sees the panel rows of both chats, arg and ui included');
select set_config('qa.panel', 'boom', true);
select is(reg('own'), '', 'a raising panel: zero rows, no error');
select set_config('qa.panel', '', true);
alter function app_private.private_panel() rename to private_panel_off;
select is(reg('own'), '', 'a missing panel (no private pack): zero rows, no error');
alter function app_private.private_panel_off() rename to private_panel;
select is(reg('own'), (select a_b from want), 'control: the panel back, the rows are back');

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
select ok((select bool_and(loadx(p) = 'P0001:staff_load: bad input||') from bad), 'bad-shape errors carry no detail and no hint');
-- bad or too long values: the loader's own checks abort with the same fixed error, no detail, no echo
create table bad2(name text, p jsonb);
insert into bad2 values
  ('handler outside the seven', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/xx','handler','drop_all')))),
  ('word without slash', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','xx','handler','tester_list')))),
  ('word too long', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/' || repeat('a', 33),'handler','tester_list')))),
  ('help too long', rows_std(jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/xx','handler','tester_list','help_en',repeat('h', 201))))),
  ('title too long', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en',repeat('t', 201))),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/list','handler','tester_list')))),
  ('a number among the commands', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en','Changed')),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/zz','handler','tester_list'), 5))),
  ('a string among the chats', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en','Changed'), 'staff_b'),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/zz','handler','tester_list')))),
  ('an array among the commands', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en','Changed')),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/zz','handler','tester_list'), '[1]'::jsonb))),
  ('a null among the chats', jsonb_build_object('chats', jsonb_build_array(jsonb_build_object('key','staff_a','title_en','Changed'), 'null'::jsonb),
     'commands', jsonb_build_array(jsonb_build_object('chat_key','staff_a','word','/zz','handler','tester_list'))));
-- (the non-object cases each carry one valid, changing element: a partial write shows in the unchanged checks below)
select is(loadx(p), 'P0001:staff_load: bad input||', 'staff_load aborts with the fixed error, no detail: ' || name) from bad2 order by name;
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
select ok(has_function_privilege('authenticated', 'public.staff_registry()', 'execute'), 'authenticated may execute staff_registry');
select is(reg('own'), (select a_b from want), 'the owner sees both chats'' rows');
select is(reg('adm'), (select b from want), 'a command admin sees only staff_b');
select is(reg('mal'), '', 'a user in no staff chat gets zero rows, no error');

-- removed admin: control, then removal
select is(reg('rmv'), (select b from want), 'control: rmv sees staff_b while a command admin');
delete from app_private.command_admins where user_id = u('rmv');
select is(reg('rmv'), '', 'a removed command admin gets zero rows');

-- left member
select set_config('app_private.admin_write', 'on', true);
insert into public.conversation_members(conversation_id, user_id, role) values (ca(), u('lft'), 'member'), (ca(), u('nax'), 'member'), (ca(), u('bot'), 'member');
select set_config('app_private.admin_write', '', true);
select matches(reg('lft'), '^staff_a:/addx:', 'control: a current member of staff_a gets its rows');
select set_config('app_private.admin_write', 'on', true);
update public.conversation_members set left_at = now(), left_reason = 'left' where conversation_id = ca() and user_id = u('lft');
select set_config('app_private.admin_write', '', true);
select is(reg('lft'), '', 'a member who left gets zero rows');

-- no app access
select matches(reg('nax'), '^staff_a:/addx:', 'control: nax with app access gets rows');
delete from app_private.allowlist where email = 'nax@sis.test';
select is(access_for('nax'), false, 'fixture: nax has no app access now');
select is(reg('nax'), '', 'a member without app access gets zero rows');

-- bot account
select matches(reg('bot'), '^staff_a:/addx:', 'control: the same user before being made the bot account gets rows');
insert into public.conversations(id, title) values ('5f0c0000-0000-0000-0000-000000000001', 'Debug');
insert into app_private.bot_accounts(user_id, debug_conversation, enabled) values (u('bot'), '5f0c0000-0000-0000-0000-000000000001', true);
select is(access_for('bot'), true, 'fixture: the bot still has app access');
select is(reg('bot'), '', 'the bot account gets zero rows');

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
-- the old per-chat flag (a *_chat column still on the table) is not sent; admin_chat and debug_chat are the only *_chat keys allowed
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations'
                   and column_name like '%\_chat' and column_name not in ('admin_chat', 'debug_chat')),
          'fixture: conversations still has a third *_chat column');
select is((select count(*) from jsonb_array_elements(public.chat_list()->'conversations') e, jsonb_object_keys(e) k
            where k like '%\_chat' and k not in ('admin_chat', 'debug_chat')), 0::bigint,
          'chat_list rows carry no *_chat key other than admin_chat and debug_chat');
reset role;
select is((select staff_key from public.conversations where id = ca()), 'staff_a', 'staff_key unchanged');

select * from finish();
rollback;
