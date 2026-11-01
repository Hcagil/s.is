begin;
select plan(19);

-- Push texts follow the RECEIVER's language (20261108120000_push_text_by_language.sql).
--
-- Contract (written from the contract, not the function body):
--   app_private.push_targets_for_message(message_id) words its title/body/sender
--   per receiver by profiles.app_language: 'en' = English; 'tr', null or no
--   profile row = Turkish. The text of a plain message is passed through as is.
--   An encrypted row (ciphertext not null) says only "New message"/"Yeni mesaj".
--   A photo with a caption shows the caption alone; without one "Photo"/"Fotoğraf".
--   A sender with no profile row is "Someone"/"Biri". No push text carries an emoji.
--
-- Fixtures: ann sends; eli (app_language 'en'), tom ('tr') and nil (null) receive,
-- in one group (plain rows) and in a 1:1 each (ciphertext rows are 1:1 only).

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000b1a000' || case n
    when 'ann' then '01' when 'eli' then '02' when 'tom' then '03' when 'nil' then '04' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'b1a00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('b1a-msg-' || n)::uuid
$$;
create function k(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha256(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function sig(n text) returns text language sql immutable as $$
  select rtrim(replace(encode(sha512(convert_to(n, 'UTF8')), 'base64'), E'\n', ''), '=')
$$;
create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)), 'session_id', sid(n))::text, true);
  execute 'set local role authenticated';
end $$;
create table public.b1a_ids(name text primary key, id uuid);
grant select, insert on public.b1a_ids to authenticated, anon;
create function g(n text) returns uuid language sql stable as $$ select id from public.b1a_ids where name = n $$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), as_(text), g(text)
  to authenticated, anon;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'b1a-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','eli','tom','nil']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'b1a-%@mail.test';
insert into auth.sessions (id, user_id, created_at, updated_at)
  select sid(n)::uuid, u(n), now(), now() from unnest(array['ann','eli','tom','nil']) n;
insert into app_private.tag_finds(finder, found_id)
  select u('ann'), u(n) from unnest(array['eli','tom','nil']) n;

do $$
declare n text;
begin
  foreach n in array array['ann','eli','tom','nil'] loop
    perform as_(n);
    if not public.activate_session() then raise exception 'activate % failed', n; end if;
    perform public.publish_olm_keys(k(n || '-I'), k(n || '-S'), sig(n), array[k(n || '1'), k(n || '2')], k(n || '-F'));
    perform public.register_device_token('b1a-tok-' || n, 'android', true);
    execute 'reset role';
  end loop;
end $$;
update public.profiles set app_language = 'en' where user_id = u('eli');
update public.profiles set app_language = 'tr' where user_id = u('tom');
update public.profiles set app_language = null where user_id = u('nil');

select as_('ann');
insert into public.b1a_ids values
  ('G', public.start_group_conversation('Lang Group', array[u('eli'), u('tom'), u('nil')])),
  ('AE', public.start_direct_conversation(u('eli'))),
  ('AT', public.start_direct_conversation(u('tom'))),
  ('AN', public.start_direct_conversation(u('nil')));
reset role;
insert into storage.objects(bucket_id, name, owner_id, metadata)
  select 'attachments', g('G')::text || '/' || f, u('ann'), '{"size":3}'::jsonb
    from unnest(array['p1.jpg', 'p2.jpg']) f;
select as_('ann');
insert into public.messages(id, conversation_id, sender_id, body, attachment_path) values
  (mid('txt'), g('G'), u('ann'), 'hello there', null),
  (mid('cap'), g('G'), u('ann'), 'look', g('G')::text || '/p1.jpg'),
  (mid('pho'), g('G'), u('ann'), '', g('G')::text || '/p2.jpg');
insert into public.messages(id, conversation_id, sender_id, body, ciphertext, olm_type) values
  (mid('eE'), g('AE'), u('ann'), '🔒 Encrypted message', 'QkJCMA==', 0),
  (mid('eT'), g('AT'), u('ann'), '🔒 Encrypted message', 'QkJCMQ==', 0),
  (mid('eN'), g('AN'), u('ann'), '🔒 Encrypted message', 'QkJCMg==', 0);
reset role;
-- the sender-name fallback: ann's profile row is gone for the last message
delete from public.profiles where user_id = u('ann');
select as_('ann');
insert into public.messages(id, conversation_id, sender_id, body) values
  (mid('nop'), g('G'), u('ann'), 'sent with no profile row');
reset role;

-- each message is read once, into snap; the assertions read snap.
create temp table snap on commit drop as
  select m, t.user_id, t.title, t.body, t.sender
    from unnest(array['txt','cap','pho','eE','eT','eN','nop']) m,
         lateral app_private.push_targets_for_message(mid(m)) t;
create function b(m text, n text) returns text language sql stable as $$
  select body from snap s where s.m = b.m and user_id = u(n)
$$;

-- 1 plain text: the text itself, whatever the language -----------------------
select is((select count(*) from snap where m = 'txt'), 3::bigint, 'fixture: eli, tom and nil receive the group text');
select is(b('txt', 'eli'), 'hello there', 'en: a plain text is passed through');
select is(b('txt', 'tom') || '|' || b('txt', 'nil'), 'hello there|hello there', 'tr and null: the same text');

-- 2 photo ------------------------------------------------------------------------
select is(b('cap', 'eli'), 'look', 'en: a photo with a caption shows the caption alone');
select is(b('cap', 'tom') || '|' || b('cap', 'nil'), 'look|look', 'tr and null: the caption alone');
select is(b('pho', 'eli'), 'Photo', 'en: a photo without a caption says Photo');
select is(b('pho', 'tom'), 'Fotoğraf', 'tr: Fotoğraf');
select is(b('pho', 'nil'), 'Fotoğraf', 'null language: Fotoğraf');

-- 3 encrypted: only that a message exists ----------------------------------------
select is((select count(*) from snap where m in ('eE', 'eT', 'eN')), 3::bigint, 'fixture: each ciphertext row reaches its receiver');
select is(b('eE', 'eli'), 'New message', 'en: an encrypted row says New message');
select is(b('eT', 'tom'), 'Yeni mesaj', 'tr: an encrypted row says Yeni mesaj');
select is(b('eN', 'nil'), 'Yeni mesaj', 'null language: an encrypted row says Yeni mesaj');

-- 4 sender with no profile row ----------------------------------------------------
select is((select sender from snap where m = 'nop' and user_id = u('eli')), 'Someone', 'en: no profile sender is Someone');
select is((select title from snap where m = 'nop' and user_id = u('eli')), 'Someone @ Lang Group', 'en: the title agrees');
select is((select sender from snap where m = 'nop' and user_id = u('tom')), 'Biri', 'tr: no profile sender is Biri');
select is((select sender from snap where m = 'nop' and user_id = u('nil')), 'Biri', 'null language: Biri');
select is((select title from snap where m = 'nop' and user_id = u('nil')), 'Biri @ Lang Group', 'null language: the title agrees');

-- 5 no emoji in any push text -------------------------------------------------------
select is((select count(*) from snap), 15::bigint, 'fixture: 15 push rows were read');
select is((select count(*) from snap
            where coalesce(title, '') || coalesce(body, '') || coalesce(sender, '') ~ '[\U0001F000-\U0001FAFF☀-➿]'),
          0::bigint, 'no title, body or sender carries an emoji');

select * from finish();
rollback;
