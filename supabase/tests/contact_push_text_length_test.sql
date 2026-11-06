begin;
select plan(4);

-- A contact push text cuts the name (first body line) at 60 characters, like the reaction
-- push (20261118120000). send_contact caps names at 80, so the long body is inserted directly.
-- The text is 'Contact: ' / 'Kişi: ' + the name part; the name part must be <= 60 characters.


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
select public.send_contact(g('G'), mid('short'), 'Zed Quill', '5551234567');
reset role;
insert into public.messages(id, conversation_id, sender_id, body, contact)
  values (mid('long'), g('G'), u('ann'), repeat('Q', 500) || E'\n5551234567', true);

create temp table snap on commit drop as
  select m, t.user_id, t.body
    from unnest(array['short','long']) m,
         lateral app_private.push_targets_for_message(mid(m)) t;

select is((select body from snap where m = 'short' and user_id = u('eli')), 'Contact: Zed Quill',
          'a short contact name is unchanged');
select is((select body from snap where m = 'short' and user_id = u('tom')), 'Kişi: Zed Quill',
          'a short contact name is unchanged (tr)');
select cmp_ok((select char_length(substr(body, strpos(body, ': ') + 2)) from snap
                where m = 'long' and user_id = u('eli')), '<=', 60,
              'a 500-character contact name is cut to 60 characters');
select is((select substr(body, strpos(body, ': ') + 2) from snap where m = 'long' and user_id = u('eli')),
          repeat('Q', 60), 'the cut name is left(first line, 60)');

select * from finish();
rollback;
