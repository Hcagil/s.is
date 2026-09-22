-- One preview per conversation, instead of a bounded scan across all of them.
--
-- The previous implementation read the caller's newest 200 messages across
-- every conversation and took the first row seen per conversation. A quiet
-- conversation therefore lost its preview as soon as 200 newer messages
-- existed elsewhere, and the list rendered "No messages yet" for a
-- conversation that plainly had messages. A busy group crosses 200 in ordinary
-- use, so this shipped as "my chats lost their previews".
--
-- distinct on gives exactly one row per conversation with no cap at all, which
-- is what the repository comment named as the remedy rather than a bigger
-- number.
--
-- security_invoker: the view is evaluated with the CALLER's privileges, so the
-- existing messages policy applies unchanged and this adds no new read path.
create view public.conversation_previews
with (security_invoker = true) as
select distinct on (m.conversation_id)
       m.conversation_id,
       m.body,
       m.attachment_path,
       m.created_at
  from public.messages m
 order by m.conversation_id, m.created_at desc;

revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;
