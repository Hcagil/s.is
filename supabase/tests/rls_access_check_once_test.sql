begin;
select plan(28);

-- Every RLS policy that gates on app_private.has_app_access() calls it as a
-- scalar subquery, (select app_private.has_app_access()), so the planner runs
-- it once per query as an InitPlan instead of once per row. Four things are
-- pinned here:
--
--  1. catalog: no policy anywhere calls has_app_access() bare -- a policy
--     added later without the wrapper fails this file;
--  2. the wrapper is the only change: each policy's predicate, with the
--     wrapper normalised back to the bare call, is exactly the text the
--     policy had before (captured from pg_policies at 20260926130000), and
--     its command, roles and permissiveness are the same;
--  3. plan text: a member reading conversation_members and
--     conversation_previews evaluates has_app_access() in an InitPlan, never
--     in a per-row Filter;
--  4. a member whose app access is gone reads no membership rows, although
--     the membership half of conversation_members_read would let her through.

-- 1 no bare has_app_access() in any policy ---------------------------------
create function pg_temp.unwrapped(expr text) returns text language sql immutable as $$
  select regexp_replace(coalesce(expr, ''),
           '\(\s*SELECT app_private\.has_app_access\(\) AS \w+\)', '', 'g')
$$;
select is_empty(
  $$select format('%s.%s.%s', schemaname, tablename, policyname)
      from pg_policies
     where pg_temp.unwrapped(qual) ~ 'has_app_access\('
        or pg_temp.unwrapped(with_check) ~ 'has_app_access\('$$,
  'no policy calls has_app_access() outside a scalar subquery');
-- Not vacuous: the pattern the check strips is the one the catalog holds.
select cmp_ok(
  (select count(*)::int from pg_policies
    where coalesce(qual, '') || coalesce(with_check, '')
          ~ '\( SELECT app_private\.has_app_access\(\) AS has_app_access\)'),
  '>=', 17, 'the 17 gated policies carry the wrapped call');

-- 2 each predicate is otherwise unchanged ------------------------------------
-- Expected: permissive|roles|cmd|qual|with_check as pg_policies deparsed them
-- before the wrapper (messages_read was already wrapped then). Both sides are
-- normalised back to the bare call, so only a change beyond the wrapper shows.
create function pg_temp.bare(expr text) returns text language sql immutable as $$
  select regexp_replace(expr,
           '\( SELECT app_private\.has_app_access\(\) AS has_app_access\)',
           'app_private.has_app_access()', 'g')
$$;
create temp table expected(schemaname name, tablename name, policyname name, def text);
insert into expected values
  ('public', 'app_config', 'app_config_read', $e$PERMISSIVE|{authenticated}|SELECT|app_private.has_app_access()|<null>$e$),
  ('public', 'conversation_members', 'conversation_members_read', $e$PERMISSIVE|{authenticated}|SELECT|(app_private.has_app_access() AND app_private.is_member(conversation_id))|<null>$e$),
  ('public', 'conversations', 'conversations_read', $e$PERMISSIVE|{authenticated}|SELECT|(app_private.has_app_access() AND app_private.is_member(id))|<null>$e$),
  ('public', 'messages', 'messages_read', $e$PERMISSIVE|{authenticated}|SELECT|(( SELECT app_private.has_app_access() AS has_app_access) AND app_private.is_member(conversation_id))|<null>$e$),
  ('public', 'messages', 'messages_send', $e$PERMISSIVE|{authenticated}|INSERT|<null>|(app_private.has_app_access() AND (sender_id = auth.uid()) AND app_private.is_member(conversation_id) AND ((attachment_path IS NULL) OR ((split_part(attachment_path, '/'::text, 1) = (conversation_id)::text) AND app_private.owns_attachment(attachment_path))) AND ((reply_to IS NULL) OR app_private.in_conversation(reply_to, conversation_id)))$e$),
  ('public', 'notification_mutes', 'notification_mutes_change', $e$PERMISSIVE|{authenticated}|UPDATE|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)))|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)) AND
CASE kind
    WHEN 'conversation'::text THEN app_private.is_member(target)
    WHEN 'person'::text THEN ((target <> ( SELECT auth.uid() AS uid)) AND app_private.is_allowed(target))
    ELSE NULL::boolean
END)$e$),
  ('public', 'notification_mutes', 'notification_mutes_delete', $e$PERMISSIVE|{authenticated}|DELETE|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)))|<null>$e$),
  ('public', 'notification_mutes', 'notification_mutes_read', $e$PERMISSIVE|{authenticated}|SELECT|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)))|<null>$e$),
  ('public', 'notification_mutes', 'notification_mutes_write', $e$PERMISSIVE|{authenticated}|INSERT|<null>|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)) AND
CASE kind
    WHEN 'conversation'::text THEN app_private.is_member(target)
    WHEN 'person'::text THEN ((target <> ( SELECT auth.uid() AS uid)) AND app_private.is_allowed(target))
    ELSE NULL::boolean
END)$e$),
  ('public', 'notification_settings', 'notification_settings_own', $e$PERMISSIVE|{authenticated}|ALL|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)))|(app_private.has_app_access() AND (user_id = ( SELECT auth.uid() AS uid)))$e$),
  ('public', 'profiles', 'profiles_read', $e$PERMISSIVE|{authenticated}|SELECT|(app_private.has_app_access() AND app_private.is_allowed(user_id))|<null>$e$),
  ('public', 'profiles', 'profiles_update_own', $e$PERMISSIVE|{authenticated}|UPDATE|(app_private.has_app_access() AND (user_id = auth.uid()))|(app_private.has_app_access() AND (user_id = auth.uid()))$e$),
  ('realtime', 'messages', 'realtime_receive', $e$PERMISSIVE|{authenticated}|SELECT|(app_private.has_app_access() AND (((realtime.topic() = 'presence:members'::text) AND (extension = 'presence'::text)) OR ((extension = 'broadcast'::text) AND app_private.is_member(app_private.typing_conversation(realtime.topic()))) OR ((extension = 'broadcast'::text) AND app_private.is_member(app_private.reads_conversation(realtime.topic())) AND app_private.shares_read_status())))|<null>$e$),
  ('realtime', 'messages', 'realtime_send', $e$PERMISSIVE|{authenticated}|INSERT|<null>|(app_private.has_app_access() AND (((realtime.topic() = 'presence:members'::text) AND (extension = 'presence'::text) AND app_private.shares_presence()) OR ((extension = 'broadcast'::text) AND app_private.is_member(app_private.typing_conversation(realtime.topic())) AND app_private.shares_typing())))$e$),
  ('storage', 'objects', 'attachments_read', $e$PERMISSIVE|{authenticated}|SELECT|((bucket_id = 'attachments'::text) AND app_private.has_app_access() AND app_private.is_member_of_path(name))|<null>$e$),
  ('storage', 'objects', 'attachments_remove_deleted', $e$PERMISSIVE|{authenticated}|DELETE|((bucket_id = 'attachments'::text) AND app_private.has_app_access() AND (owner_id = (auth.uid())::text) AND app_private.may_remove_attachment(name))|<null>$e$),
  ('storage', 'objects', 'attachments_write', $e$PERMISSIVE|{authenticated}|INSERT|<null>|((bucket_id = 'attachments'::text) AND app_private.has_app_access() AND app_private.is_member_of_path(name) AND (owner_id = (auth.uid())::text))$e$);

select is(
  (select pg_temp.bare(concat_ws('|', p.permissive, p.roles::text, p.cmd,
                                 coalesce(p.qual, '<null>'), coalesce(p.with_check, '<null>')))
     from pg_policies p
    where (p.schemaname, p.tablename, p.policyname) = (e.schemaname, e.tablename, e.policyname)),
  pg_temp.bare(e.def),
  format('%s.%s.%s: same predicate, command and roles', e.schemaname, e.tablename, e.policyname))
  from expected e
 order by e.schemaname, e.tablename, e.policyname;

-- Fixtures: ada and ben share a conversation; both allowlisted and active.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000a701', 'ada@once.test', now(), '{"full_name":"Ada"}'),
  ('00000000-0000-0000-0000-00000000a702', 'ben@once.test', now(), '{"full_name":"Ben"}');
insert into app_private.allowlist(email) values ('ada@once.test'), ('ben@once.test');
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('a7000000-0000-0000-0000-00000000a701', '00000000-0000-0000-0000-00000000a701', now(), now()),
  ('a7000000-0000-0000-0000-00000000a702', '00000000-0000-0000-0000-00000000a702', now(), now());

create function once_as(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000a70' || n, 'role', 'authenticated',
      'email', (select email from auth.users where id = ('00000000-0000-0000-0000-00000000a70' || n)::uuid),
      'session_id', 'a7000000-0000-0000-0000-00000000a70' || n)::text, true);
  execute 'set local role authenticated';
end $$;
-- EXPLAIN (verbose) of [q], as text; verbose names the InitPlan's output.
create function once_plan(q text) returns text language plpgsql as $$
declare r record; t text := '';
begin
  for r in execute 'explain (costs off, verbose) ' || q loop
    t := t || r."QUERY PLAN" || E'\n';
  end loop;
  return t;
end $$;
grant execute on function once_as(int), once_plan(text) to authenticated;

select once_as(1); select is(public.activate_session(), true, 'ada is active'); reset role;
select once_as(2); select is(public.activate_session(), true, 'ben is active'); reset role;

insert into public.conversations(id, title) values ('c7000000-0000-0000-0000-00000000c701', 'ada-ben');
insert into public.conversation_members(conversation_id, user_id) values
  ('c7000000-0000-0000-0000-00000000c701', '00000000-0000-0000-0000-00000000a701'),
  ('c7000000-0000-0000-0000-00000000c701', '00000000-0000-0000-0000-00000000a702');
insert into public.messages(conversation_id, sender_id, body) values
  ('c7000000-0000-0000-0000-00000000c701', '00000000-0000-0000-0000-00000000a702', 'hi ada');

-- 3 the hot path checks access once ------------------------------------------
select once_as(1);
create temp table plans as select
  once_plan('select conversation_id, user_id, joined_at from public.conversation_members') as members,
  once_plan('select conversation_id, body, sender_id, created_at from public.conversation_previews') as previews;
reset role;

select ok((select members ~ 'InitPlan \d+\n\s+->  Result\n\s+Output: app_private\.has_app_access\(\)' from plans),
          'conversation_members: has_app_access() is an InitPlan');
select ok((select members !~ 'Filter: [^\n]*has_app_access\(' from plans),
          'conversation_members: has_app_access() is not in the per-row filter');
select ok((select previews ~ 'InitPlan \d+\n\s+->  Result\n\s+Output: app_private\.has_app_access\(\)' from plans),
          'conversation_previews: has_app_access() is an InitPlan');
select ok((select previews !~ 'Filter: [^\n]*has_app_access\(' from plans),
          'conversation_previews: has_app_access() is not in any per-row filter');

-- 4 a member without app access reads no membership --------------------------
select once_as(1);
select is((select count(*) from public.conversation_members), 2::bigint,
          'control: ada, active and allowlisted, reads both members of her conversation');
reset role;
-- Delisted with her session still active and her membership intact, so only
-- the has_app_access() half of conversation_members_read can refuse her.
delete from app_private.allowlist where email = 'ada@once.test';
select is((select count(*) from public.conversation_members
            where user_id = '00000000-0000-0000-0000-00000000a701'), 1::bigint,
          'ada is still a member');
select once_as(1);
select is((select count(*) from public.conversation_members), 0::bigint,
          'delisted ada reads no membership rows');
reset role;

select * from finish();
rollback;
