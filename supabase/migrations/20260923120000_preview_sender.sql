-- The conversation list shows "You: ..." when the last message is the
-- member's own, so the preview needs its sender. Appended as the last column:
-- create or replace view may add columns at the end but not reorder them.
-- security_invoker is restated because replacing a view without it would
-- silently turn it back into a definer-rights view that bypasses RLS.
create or replace view public.conversation_previews
with (security_invoker = true) as
select distinct on (m.conversation_id)
       m.conversation_id,
       m.body,
       m.attachment_path,
       m.created_at,
       m.sender_id
  from public.messages m
 order by m.conversation_id, m.created_at desc;

revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;
