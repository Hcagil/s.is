-- Expose debug_chat on public.conversations so the app can show an extra warning when closing the Debug group.
-- Previously the marker lived only in app_private.bot_accounts.debug_conversation.

alter table public.conversations add column debug_chat boolean not null default false;

-- Backfill existing debug conversations
update public.conversations c
set debug_chat = true
where exists (
  select 1
  from app_private.bot_accounts b
  where b.debug_conversation = c.id
);

-- Keep debug_chat true for future bots
create or replace function app_private.mark_debug_chat()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversations
  set debug_chat = true
  where id = new.debug_conversation;
  return new;
end;
$$;

revoke all on function app_private.mark_debug_chat() from public, anon, authenticated;

create trigger bot_accounts_mark_debug_chat
after insert on app_private.bot_accounts
for each row
execute function app_private.mark_debug_chat();
