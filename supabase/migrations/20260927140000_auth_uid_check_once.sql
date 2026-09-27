-- Perf: same fix as 20260926140000, for auth.uid() instead of has_app_access().
-- qa-lead (2026-09-26, after #45) found four live policies still call
-- auth.uid() bare, so the planner re-evaluates it per candidate row instead
-- of once per query: messages_send, profiles_update_own, attachments_write,
-- attachments_remove_deleted. notification_settings_own, notification_mutes_*
-- already wrap it as `(select auth.uid())` (20260924120000); this migration
-- brings the remaining four in line. Nothing else about any predicate
-- changes -- same table, command, roles and every other clause, verified
-- against `pg_policies` (see rls_access_check_once_test.sql's method).
--
-- Checked every other live policy in `pg_policies` for a bare `auth.uid()`
-- (as opposed to `(select auth.uid())`) and found none beyond these four:
-- app_config_read, profiles_read, conversations_read, conversation_members_
-- read and attachments_read call no auth.uid() at all; realtime_receive/send
-- call no auth.uid() either (realtime.topic() and the is_member/typing/reads
-- helpers only). search_messages() also calls auth.uid() bare, but it is a
-- function body (evaluated once per invocation already, not once per row of
-- some other relation) and out of scope for this migration, which -- like
-- 20260926140000 -- touches RLS policies only.
--
-- messages_send is the one write path here that scales: a member composing
-- into a busy conversation still only inserts one row, so auth.uid() bare
-- was never re-run per candidate row on this policy the way it was on a
-- SELECT scanning many rows -- WITH CHECK evaluates once per inserted row
-- regardless. The four are still worth wrapping for the same reason
-- 20260926140000 wrapped has_app_access() everywhere it appeared, bare or
-- not: a consistent, catalog-checkable rule ("no bare auth.uid() in a
-- policy") is cheaper to keep true than "only where it's proven to be a hot
-- path today" -- and profiles_update_own / attachments_write / attachments_
-- remove_deleted gate an UPDATE/INSERT/DELETE the same way, so the
-- consistency costs nothing.

drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select app_private.has_app_access()) and user_id = (select auth.uid()))
  with check ((select app_private.has_app_access()) and user_id = (select auth.uid()));

drop policy messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
  with check ((select app_private.has_app_access())
              and sender_id = (select auth.uid())
              and app_private.is_member(conversation_id)
              and (attachment_path is null
                   or (split_part(attachment_path, '/', 1) = conversation_id::text
                       and app_private.owns_attachment(attachment_path)))
              and (reply_to is null
                   or app_private.in_conversation(reply_to, conversation_id)));

drop policy attachments_write on storage.objects;
create policy attachments_write on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (select app_private.has_app_access())
              and app_private.is_member_of_path(name)
              and owner_id = (select auth.uid())::text);

drop policy attachments_remove_deleted on storage.objects;
create policy attachments_remove_deleted on storage.objects for delete to authenticated
  using (bucket_id = 'attachments'
         and (select app_private.has_app_access())
         and owner_id = (select auth.uid())::text
         and app_private.may_remove_attachment(name));
