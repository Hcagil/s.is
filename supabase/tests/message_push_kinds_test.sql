begin;
select plan(16);

-- Push text for poll, place and contact messages follows the RECEIVER's
-- language (20261116120000_push_text_poll_place_contact_reaction.sql).
-- Contract: full preview, not encrypted: poll = "Poll: {question}" / "Anket: ..."; place =
-- exactly "Location" / "Konum" (address never in the text); contact = "Contact: {name}" /
-- "Kişi: {name}"; the phone number never appears anywhere in the row.
-- 'en' = English; 'tr' or null = Turkish. Hidden previews (none) stay "New message"/"Yeni mesaj".
-- ann sends in one group; eli (en), tom (tr), nil (null) receive.

create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000b1b000' || case n
    when 'ann' then '01' when 'eli' then '02' when 'tom' then '03' when 'nil' then '04' end)::uuid
$$;
create function sid(n text) returns text language sql immutable as $$
  select 'b1b00000-0000-0000-0000-' || right(u(n)::text, 12)
$$;
create function mid(n text) returns uuid language sql immutable as $$
  select md5('b1b-msg-' || n)::uuid
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
create table public.b1b_ids(name text primary key, id uuid);
grant select, insert on public.b1b_ids to authenticated, anon;
create function g(n text) returns uuid language sql stable as $$ select id from public.b1b_ids where name = n $$;
grant execute on function u(text), sid(text), mid(text), k(text), sig(text), as_(text), g(text)
  to authenticated, anon;

insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  select u(n), 'b1b-' || n || '@mail.test', now(), json_build_object('full_name', initcap(n))::jsonb
    from unnest(array['ann','eli','tom','nil']) n;
insert into app_private.allowlist(email) select email from auth.users where email like 'b1b-%@mail.test';
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
    perform public.register_device_token('b1b-tok-' || n, 'android', true);
    execute 'reset role';
  end loop;
end $$;
update public.profiles set app_language = 'en' where user_id = u('eli');
update public.profiles set app_language = 'tr' where user_id = u('tom');
update public.profiles set app_language = null where user_id = u('nil');

select as_('ann');
insert into public.b1b_ids values
  ('G', public.start_group_conversation('Lang Group', array[u('eli'), u('tom'), u('nil')])),
  ('AE', public.start_direct_conversation(u('eli'))),
  ('AT', public.start_direct_conversation(u('tom'))),
  ('AN', public.start_direct_conversation(u('nil')));
reset role;
select as_('ann');
select public.create_poll(g('G'), mid('poll'), 'Pizza tonight?', array['yes','no'], false, false);
select public.send_location(g('G'), mid('loc'), 41.0::float8, 29.0::float8, 'Cafe Nero', '12 Baker Street');
select public.send_contact(g('G'), mid('con'), 'Zed Quill', '5551234567');
reset role;

create temp table snap on commit drop as
  select m, t.user_id, t.title, t.body, t.sender, to_jsonb(t)::text as j
    from unnest(array['poll','loc','con']) m,
         lateral app_private.push_targets_for_message(mid(m)) t;
create function b(m text, n text) returns text language sql stable as $$
  select body from snap s where s.m = b.m and user_id = u(n)
$$;

select is((select count(*) from snap), 9::bigint, 'fixture: 3 receivers x 3 messages');

select is(b('poll', 'eli'), 'Poll: Pizza tonight?', 'en poll');
select is(b('poll', 'tom'), 'Anket: Pizza tonight?', 'tr poll');
select is(b('poll', 'nil'), 'Anket: Pizza tonight?', 'null-language poll is Turkish');

select is(b('loc', 'eli'), 'Location', 'en place is exactly Location');
select is(b('loc', 'tom'), 'Konum', 'tr place is exactly Konum');
select is(b('loc', 'nil'), 'Konum', 'null-language place is Konum');
select is((select count(*) from snap where m = 'loc'
            and coalesce(title, '') || coalesce(body, '') || coalesce(sender, '') like '%Baker%'),
          0::bigint, 'the address is never in a place push text');

select is(b('con', 'eli'), 'Contact: Zed Quill', 'en contact');
select is(b('con', 'tom'), 'Kişi: Zed Quill', 'tr contact');
select is(b('con', 'nil'), 'Kişi: Zed Quill', 'null-language contact is Turkish');
select is((select count(*) from snap where j like '%5551234567%'), 0::bigint,
          'the phone number is nowhere in any push row');
select is((select count(*) from snap where j like '%1234567%'), 0::bigint,
          'not even a piece of the phone number');

-- hidden previews stay generic
insert into public.notification_settings(user_id, preview)
  select u(n), 'none' from unnest(array['eli', 'tom']) n;
create temp table hid on commit drop as
  select m, t.user_id, t.body, to_jsonb(t)::text as j
    from unnest(array['poll','loc','con']) m,
         lateral app_private.push_targets_for_message(mid(m)) t;
select is((select string_agg(distinct body, ',') from hid where user_id = u('eli')), 'New message', 'en, preview none: New message for all three kinds');
select is((select string_agg(distinct body, ',') from hid where user_id = u('tom')), 'Yeni mesaj', 'tr, preview none: Yeni mesaj for all three kinds');
select is((select count(*) from hid where user_id in (u('eli'), u('tom'))
              and (j like '%Pizza%' or j like '%Baker%' or j like '%Quill%' or j like '%5551234567%')),
          0::bigint, 'preview none leaks neither question, address, name nor number');

select * from finish();
rollback;
