-- Perf: conversation_members_read still called has_app_access() bare, so the
-- planner re-evaluates its several joins (auth.users, auth.sessions,
-- active_sessions, allowlist) once per candidate row instead of once per
-- query -- the same problem 20260926130000_query_indexes.sql already fixed
-- on messages_read. conversation_previews does a LATERAL over
-- conversation_members for every conversation the caller is in, so this
-- policy sits on the chat list's hot path.
--
-- Measured at 200 conversations, 400 memberships, one member's own 200
-- conversations each carrying 20 messages, EXPLAIN (ANALYZE, BUFFERS) as
-- `authenticated` with a member's JWT claims:
--
--   select conversation_id, user_id, joined_at   5613 buffer hits, ~50ms
--     from conversation_members                  before -> 1240 buffer hits,
--                                                 ~2.5ms after. has_app_
--                                                 access() moves from the
--                                                 per-row Filter to a single
--                                                 InitPlan.
--
--   select * from conversation_previews          6824 buffer hits, ~51ms
--                                                 before -> 2435 buffer hits,
--                                                 ~4.6ms after: its LATERAL
--                                                 scans conversation_members
--                                                 through this same policy,
--                                                 so it inherits the fix.
--                                                 Identical predicate, so
--                                                 identical rows are visible
--                                                 in both cases -- purely a
--                                                 planner hint.
--
-- Same fix, same reason, applied everywhere else it repeats: every policy
-- below has `app_private.has_app_access()` bare in USING or WITH CHECK, and
-- nothing else about the predicate changes. `(select app_private.has_app_
-- access())` lets the planner hoist it into a one-time InitPlan instead of
-- re-running it per row -- has_app_access() takes no row-dependent argument,
-- so it returns the same answer for the whole query regardless. Every other
-- function in these predicates (is_member(...), is_allowed(...),
-- is_member_of_path(...), owns_attachment(...), may_remove_attachment(...),
-- in_conversation(...), auth.uid(), realtime.topic(), typing_conversation(...),
-- reads_conversation(...), shares_presence()/shares_typing()) is left exactly
-- as it was: either row-dependent and therefore not hoistable the same way,
-- or unrelated to this fix, so touching it is out of scope here.
--
-- Policies left unchanged, and why:
--   messages_read (public.messages)                    already wrapped, in 20260926130000.
--   messages_send's v0.2 and delete_for_everyone's      dead: `drop policy` + `create policy` superseded each in
--     definitions of messages_send                      turn; the live definition is reply_and_forward's, wrapped below.
--   realtime_receive, presence_and_typing's definition  dead: superseded by read_status's `drop`+`create`, wrapped below.
--   "allowed active sessions can read profiles"         dead: its table, public.profiles, was dropped (cascade) and
--     (20260918120000_identity_authorization.sql)       recreated by 20260921120000_identity_and_access.sql, which
--                                                        drops the policy with it; profiles_read (scope_profiles_to_
--                                                        allowlist's later definition) is the live policy, wrapped below.
--   every `if not app_private.has_app_access() then       out of scope: this migration touches RLS policies only.
--     raise exception ...` inside a plpgsql function      A function body already calls has_app_access() once per
--     body (start_direct_conversation, delete_message,    invocation, not once per candidate row -- there is no
--     mark_read, push_targets_for_message, etc.)          per-row re-evaluation there to fix.
--   user_id = auth.uid() / sender_id = auth.uid() and     out of scope: auth.uid() is a different function; wrapping
--     other non-has_app_access() calls in every policy    it is a separate change this migration does not make, per
--     above                                               the brief -- left bare even where the repo already wraps
--                                                          it elsewhere (notification_settings.sql).

drop policy app_config_read on public.app_config;
create policy app_config_read on public.app_config for select to authenticated
  using ((select app_private.has_app_access()));

drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using ((select app_private.has_app_access()) and app_private.is_allowed(user_id));

drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select app_private.has_app_access()) and user_id = auth.uid())
  with check ((select app_private.has_app_access()) and user_id = auth.uid());

drop policy conversations_read on public.conversations;
create policy conversations_read on public.conversations for select to authenticated
  using ((select app_private.has_app_access()) and app_private.is_member(id));

drop policy conversation_members_read on public.conversation_members;
create policy conversation_members_read on public.conversation_members for select to authenticated
  using ((select app_private.has_app_access()) and app_private.is_member(conversation_id));

drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check ((select app_private.has_app_access())
              and sender_id = auth.uid()
              and app_private.is_member(conversation_id)
              and (attachment_path is null
                   or (split_part(attachment_path, '/', 1) = conversation_id::text
                       and app_private.owns_attachment(attachment_path)))
              and (reply_to is null
                   or app_private.in_conversation(reply_to, conversation_id)));

drop policy attachments_read on storage.objects;
create policy attachments_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and app_private.is_member_of_path(name));

drop policy attachments_write on storage.objects;
create policy attachments_write on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (select app_private.has_app_access())
              and app_private.is_member_of_path(name)
              and owner_id = auth.uid()::text);

drop policy attachments_remove_deleted on storage.objects;
create policy attachments_remove_deleted on storage.objects for delete to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and owner_id = auth.uid()::text
         and app_private.may_remove_attachment(name));

drop policy realtime_receive on realtime.messages;
create policy realtime_receive on realtime.messages for select to authenticated
  using (
    (select app_private.has_app_access())
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence')
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic())))
      or (extension = 'broadcast'
          and app_private.is_member(app_private.reads_conversation(realtime.topic()))
          and app_private.shares_read_status())
    )
  );

drop policy realtime_send on realtime.messages;
create policy realtime_send on realtime.messages for insert to authenticated
  with check (
    (select app_private.has_app_access())
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence'
       and app_private.shares_presence())
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic()))
          and app_private.shares_typing())
    )
  );

drop policy notification_settings_own on public.notification_settings;
create policy notification_settings_own on public.notification_settings
  for all to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check ((select app_private.has_app_access()) and user_id = (select auth.uid()));

drop policy notification_mutes_read on public.notification_mutes;
create policy notification_mutes_read on public.notification_mutes
  for select to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

drop policy notification_mutes_delete on public.notification_mutes;
create policy notification_mutes_delete on public.notification_mutes
  for delete to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()));

drop policy notification_mutes_write on public.notification_mutes;
create policy notification_mutes_write on public.notification_mutes
  for insert to authenticated
  with check ((select app_private.has_app_access())
              and user_id = (select auth.uid())
              and case kind
                    when 'conversation' then app_private.is_member(target)
                    when 'person' then target <> (select auth.uid())
                                       and app_private.is_allowed(target)
                  end);

drop policy notification_mutes_change on public.notification_mutes;
create policy notification_mutes_change on public.notification_mutes
  for update to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check ((select app_private.has_app_access())
              and user_id = (select auth.uid())
              and case kind
                    when 'conversation' then app_private.is_member(target)
                    when 'person' then target <> (select auth.uid())
                                       and app_private.is_allowed(target)
                  end);
