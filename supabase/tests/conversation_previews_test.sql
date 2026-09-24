begin;
select plan(15);

-- public.conversation_previews is a read path of its own: a view with its own
-- grant. It is only safe because `security_invoker = true` makes it run with
-- the caller's privileges, so the messages policy still applies. Drop that
-- setting and the view runs as its owner, who is exempt from row-level
-- security, and every member's newest message becomes readable by anybody
-- holding the select grant. Nothing about the view's shape would look wrong.
--
-- Fixtures: pam and quincy talk; rex is allowlisted AND holds an active
-- session but is not a member, so has_app_access() is already true for him and
-- only the membership half of the policy can stop him. A stranger would fail
-- the first half and prove nothing about the second.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'pam@example.com', now(), '{"full_name":"Pam"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'quincy@example.com', now(), '{"full_name":"Quincy"}'),
  ('00000000-0000-0000-0000-0000000000f3', 'rex@example.com', now(), '{"full_name":"Rex"}');
insert into app_private.allowlist(email) values
  ('pam@example.com'), ('quincy@example.com'), ('rex@example.com');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('ffffffff-ffff-ffff-ffff-fffffffffff1', '00000000-0000-0000-0000-0000000000f1', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffffff2', '00000000-0000-0000-0000-0000000000f2', now(), now()),
  ('ffffffff-ffff-ffff-ffff-fffffffffff3', '00000000-0000-0000-0000-0000000000f3', now(), now());

create or replace function test_as(uid uuid, sid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated',
      'email', (select email from auth.users where id = uid), 'session_id', sid)::text, true);
  execute 'set local role authenticated';
end $$;

select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
select is(public.activate_session(), true, 'pam is active');
reset role;
select test_as('00000000-0000-0000-0000-0000000000f3', 'ffffffff-ffff-ffff-ffff-fffffffffff3');
select is(public.activate_session(), true, 'rex is active');
reset role;

select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
create temp table _c as select public.start_direct_conversation('00000000-0000-0000-0000-0000000000f2') as id;
reset role;

-- Written as the owner, because created_at is withheld from clients on purpose
-- and every row inserted inside one transaction would otherwise carry the same
-- now(). Distinct timestamps are the whole point here: "the newest" has to be
-- decidable.
insert into public.messages(conversation_id, sender_id, body, created_at) values
  ((select id from _c), '00000000-0000-0000-0000-0000000000f1', 'older', now() - interval '2 hours'),
  ((select id from _c), '00000000-0000-0000-0000-0000000000f2', 'newest text', now() - interval '1 hour');

-- 1 anonymous reaches nothing --------------------------------------------
set local role anon;
select throws_ok($$select count(*) from public.conversation_previews$$,
                 '42501', null, 'anon cannot read conversation_previews');
reset role;

-- 2 a member sees exactly one row, and it is the newest message -----------
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
select is((select count(*) from public.conversation_previews where conversation_id = (select id from _c)),
          1::bigint, 'one preview row per conversation, whatever its length');
select is((select body from public.conversation_previews where conversation_id = (select id from _c)),
          'newest text', 'the preview row is the newest message');
reset role;

-- 2b the view carries WHO sent the newest message ------------------------
-- The list says "You: ..." from this column. The newest row is quincy's while
-- pam reads, so a sender taken from anything but the newest row (or the
-- reader) is caught here.
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
select is((select sender_id from public.conversation_previews where conversation_id = (select id from _c)),
          '00000000-0000-0000-0000-0000000000f2'::uuid,
          'sender_id is the sender of the newest message');
reset role;

-- 3 an image with no caption still gives the client something to show ------
insert into public.messages(conversation_id, sender_id, body, attachment_path, created_at) values
  ((select id from _c), '00000000-0000-0000-0000-0000000000f2', '',
   (select id from _c)::text || '/photo.png', now());
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
select is((select body from public.conversation_previews where conversation_id = (select id from _c)),
          '', 'an image-only message is the newest preview row');
select isnt((select attachment_path from public.conversation_previews where conversation_id = (select id from _c)),
            null, 'attachment_path is exposed, so an empty body can be told from no message');
reset role;

-- 4 an allowlisted, ACTIVE non-member reads nothing through the view -------
-- This is the assertion that security_invoker holds. Running as the owner the
-- view would hand rex somebody else's newest message.
select test_as('00000000-0000-0000-0000-0000000000f3', 'ffffffff-ffff-ffff-ffff-fffffffffff3');
select is((select count(*) from public.conversation_previews where conversation_id = (select id from _c)),
          0::bigint, 'an active non-member reads no preview of a conversation he is not in');
reset role;

select test_as('00000000-0000-0000-0000-0000000000f3', 'ffffffff-ffff-ffff-ffff-fffffffffff3');
select is((select count(sender_id) from public.conversation_previews
            where sender_id in ('00000000-0000-0000-0000-0000000000f1',
                                '00000000-0000-0000-0000-0000000000f2')),
          0::bigint, 'an active non-member learns no sender through the view');
reset role;

-- 5 losing the active session closes the view too --------------------------
delete from auth.sessions where id = 'ffffffff-ffff-ffff-ffff-fffffffffff1';
select test_as('00000000-0000-0000-0000-0000000000f1', 'ffffffff-ffff-ffff-ffff-fffffffffff1');
select is((select count(*) from public.conversation_previews where conversation_id = (select id from _c)),
          0::bigint, 'a revoked session loses the preview it could read a moment ago');
reset role;

-- 6 the view's shape and its rights mode ----------------------------------
-- Replacing a view resets its options: a `create or replace` that forgets
-- security_invoker silently becomes a definer-rights view. Section 4 catches
-- the consequence; this names the cause.
select ok((select coalesce('security_invoker=true' = any(reloptions), false)
             from pg_class where oid = 'public.conversation_previews'::regclass),
          'conversation_previews is still security_invoker');
select has_column('public', 'conversation_previews', 'sender_id',
                  'conversation_previews exposes sender_id');
select has_column('public', 'conversation_previews', 'deleted',
                  'conversation_previews exposes deleted, for a placeholder row');
-- Appended, not inserted: `create or replace view` cannot reorder columns, so
-- a migration that put it anywhere else would not apply to an existing view.
select is((select attname::text from pg_attribute
            where attrelid = 'public.conversation_previews'::regclass
              and attnum > 0 and not attisdropped
            order by attnum desc limit 1),
          'deleted', 'deleted is now the last column, appended after sender_id');

select * from finish();
rollback;
