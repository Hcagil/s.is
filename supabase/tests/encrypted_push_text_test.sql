begin;
select plan(25);

-- Encrypted push text (Private Chats 4b, 20261102120000_encrypted_push_text.sql).
--
-- Contract (written from the contract, not the function body):
--   public.push_targets(message_id) keeps its columns and adds
--   `ciphertext text, olm_type smallint` right before the last column
--   `encrypted boolean`. They carry the row's ciphertext and olm_type only for
--   an encrypted row to a recipient whose preview is 'full' (or who never set
--   one). Preview 'sender' or 'none', and every plain row: both null.
--   Callable by service_role only; anon, authenticated and PUBLIC refused.
--
-- Fixtures. Every recipient is ann's 1:1 partner (ciphertext rows are 1:1 only):
--   bob  preview unset (counts as full)   cat  preview 'full' set explicitly
--   gus  preview 'sender'                 hal  preview 'none'
-- The plain twin of each ciphertext row goes to the same chat before its first
-- ciphertext row, so the plain row differs only in having no ciphertext.

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000f4b000' || case n
    when 'ann' then '01' when 'bob' then '02' when 'cat' then '03'
    when 'gus' then '04' when 'hal' then '05' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'f4b00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('f4b-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function ph() returns text language sql immutable as $$ select '🔒 Encrypted message' $$;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
create table public.f4b_ids(name text primary key, id uuid);
grant select, insert on public.f4b_ids to authenticated, anon, service_role;
create function g(n text) returns uuid language sql stable as $$ select id from public.f4b_ids where name = n $$;
-- The client's insert: a plain row (x null) or a ciphertext row.
create function send(c text, m text, x text, t int) returns void language sql as $$
  insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type)
  values (mid(m), g(c), auth.uid(), case when x is null then 'plain ' || m else ph() end, x, t::smallint)
$$;
-- 'ok' or the sqlstate of [q], run in its own subtransaction.
create function try(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlstate; end $$;
-- push_targets claims a message: a second call returns nothing. So each
-- message is read ONCE, into snap, and the assertions read snap.
create table public.f4b_snap(m text, user_id uuid, ciphertext text, olm_type smallint, encrypted boolean);
grant select, insert on public.f4b_snap to service_role;
-- the row of [n] for message [m]: "ciphertext|olm_type", nulls as <null>.
create function pt(m text, n text) returns text language sql stable as $$
  select coalesce(ciphertext, '<null>') || '|' || coalesce(olm_type::text, '<null>')
    from public.f4b_snap s where s.m = pt.m and user_id = u(n)
$$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), ph(), as_(text), g(text),
  send(text, text, text, int), try(text), pt(text, text) to authenticated, anon, service_role;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'f4b-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','bob','cat','gus','hal']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'f4b-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now() from unnest(array['ann','bob','cat','gus','hal']) n;
insert into app_private.tag_finds(finder, found_id)
  select u('ann'), u(n) from unnest(array['bob','cat','gus','hal']) n;

do $$
declare n text;
begin
  foreach n in array array['ann','bob','cat','gus','hal'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n), array[k(n || '1'), k(n || '2')], k(n || '-F'));
    perform public.register_device_token('f4b-tok-' || n, 'android', true);
    if n = 'cat' then insert into public.notification_settings(preview) values ('full'); end if;
    if n = 'gus' then insert into public.notification_settings(preview) values ('sender'); end if;
    if n = 'hal' then insert into public.notification_settings(preview) values ('none'); end if;
    execute 'reset role';
  end loop;
end $$;

select as_('ann');
insert into public.f4b_ids values
  ('AB', public.start_direct_conversation(u('bob'))),
  ('AC', public.start_direct_conversation(u('cat'))),
  ('AG', public.start_direct_conversation(u('gus'))),
  ('AH', public.start_direct_conversation(u('hal')));
-- plain first: a 1:1 holding a ciphertext row takes no plain text afterwards
select send('AB', 'pB', null, null), send('AC', 'pC', null, null),
       send('AG', 'pG', null, null), send('AH', 'pH', null, null);
select send('AB', 'eB0', 'QkJCMA==', 0), send('AB', 'eB1', 'QkJCMQ==', 1),
       send('AC', 'eC1', 'Q0NDMQ==', 1), send('AC', 'eC0', 'Q0NDMA==', 0),
       send('AG', 'eG1', 'R0dHMQ==', 1), send('AH', 'eH0', 'SEhIMA==', 0);
reset role;

-- 1 the shape ----------------------------------------------------------------
select ok(pg_get_function_result('public.push_targets(uuid)'::regprocedure)
            like '%, ciphertext text, olm_type smallint, encrypted boolean)',
  'push_targets ends with ciphertext text, olm_type smallint, encrypted boolean');
select ok(pg_get_function_result('public.push_targets(uuid)'::regprocedure) like
  'TABLE(user_id uuid, token text, platform text, conversation_id uuid, title text, body text, shows_itself boolean, sender text, chat text, badge integer, thumb_path text, thumb_video boolean, %',
  'the earlier columns are unchanged and in order');

-- 2 the values, as service_role (the function's only caller) ---------------
set local role service_role;
insert into public.f4b_snap
  select m, t.user_id, t.ciphertext, t.olm_type, t.encrypted
    from unnest(array['pB','pC','pG','pH','eB0','eB1','eC1','eC0','eG1','eH0']) m,
         lateral public.push_targets(mid(m)) t;
select is((select count(*) from public.f4b_snap where m = 'eB0' and user_id = u('bob')), 1::bigint,
  'fixture: bob is on the delivery list of eB0');
select is(pt('eB0', 'bob'), 'QkJCMA==|0', 'preview unset + ciphertext row, olm_type 0: the row''s ciphertext and 0');
select is(pt('eB1', 'bob'), 'QkJCMQ==|1', 'preview unset + ciphertext row, olm_type 1: the row''s ciphertext and 1');
select is(pt('eC1', 'cat'), 'Q0NDMQ==|1', 'preview full + ciphertext row, olm_type 1: the row''s ciphertext and 1');
select is(pt('eC0', 'cat'), 'Q0NDMA==|0', 'preview full + ciphertext row, olm_type 0: the row''s ciphertext and 0');
select is(pt('eG1', 'gus'), '<null>|<null>', 'preview sender + ciphertext row: both null');
select is(pt('eH0', 'hal'), '<null>|<null>', 'preview none + ciphertext row: both null');
select is((select encrypted from public.f4b_snap where m = 'eG1' and user_id = u('gus')), true,
  'fixture: gus''s row is still marked encrypted (only the text is held back)');
select is((select encrypted from public.f4b_snap where m = 'eH0' and user_id = u('hal')), true,
  'fixture: hal''s row is still marked encrypted');
select is(pt('pB', 'bob'), '<null>|<null>', 'plain row, preview unset: both null');
select is(pt('pC', 'cat'), '<null>|<null>', 'plain row, preview full: both null');
select is(pt('pG', 'gus'), '<null>|<null>', 'plain row, preview sender: both null');
select is(pt('pH', 'hal'), '<null>|<null>', 'plain row, preview none: both null');
select is((select count(*) from public.f4b_snap where m like 'p%'), 4::bigint, 'fixture: every plain row reached its recipient');
select is((select count(*) from public.f4b_snap where m = 'eB0' and user_id = u('ann')), 0::bigint,
  'the sender is not on her own delivery list');
reset role;

-- 3 who may call it ----------------------------------------------------------
select ok(has_function_privilege('service_role', 'public.push_targets(uuid)', 'execute'), 'service_role may execute');
select ok(not has_function_privilege('anon', 'public.push_targets(uuid)', 'execute'), 'anon may not execute');
select ok(not has_function_privilege('authenticated', 'public.push_targets(uuid)', 'execute'), 'authenticated may not execute');
select ok(not exists(select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                      where p.oid = 'public.push_targets(uuid)'::regprocedure and a.grantee = 0),
  'PUBLIC holds no execute on push_targets');
select as_('bob');
select is(try($q$select * from public.push_targets(mid('eB0'))$q$), '42501', 'bob, the recipient, calling it: 42501');
reset role;
select as_('ann');
select is(try($q$select * from public.push_targets(mid('eB0'))$q$), '42501', 'ann, the sender, calling it: 42501');
reset role;
set local role anon;
select is(try($q$select * from public.push_targets(mid('eB0'))$q$), '42501', 'anon calling it: 42501');
reset role;
set local role service_role;
select is(try($q$select * from public.push_targets(mid('eB0'))$q$), 'ok', 'service_role calling it: ok');
reset role;

select * from finish();
rollback;
