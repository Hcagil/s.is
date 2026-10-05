-- v0.30.18: emoji reactions on messages, one per person per message.
--
--  * public.message_reactions holds one row per (message, user). emoji NULL
--    means "no reaction": removing a reaction is an UPDATE to NULL, never a
--    row DELETE. The Realtime publication publishes inserts and updates only
--    (20260924140000) and realtime.apply_rls does not evaluate RLS for a
--    DELETE, so a published delete would reach every subscriber of the table.
--    The only real deletes left are the cascades from a message, a
--    conversation or an account, and those are not published.
--  * Clients have no insert/update/delete grant. The only write path is
--    set_reaction(), which decides nothing the client did not ask for: the app
--    says "set this emoji" or "clear", the server never toggles, so a retried
--    request is harmless.
--  * The SIS Bot (20261005130000) reacts like any member, nowhere else: it is
--    a current member only of its Debug chat and listed 1:1s (the members
--    trigger), and has_app_access() is false for it while OFF, so both the
--    policy and set_reaction refuse it then. Each emoji it sets (a clear is free:
--    it needs a set first) counts as a 'send' in app_private.bot_actions
--    (RLMT2), so a loop cannot flood the chat's Realtime feed with updates.
--    Realtime: postgres_changes on this table is gated by the same read
--    policy (member of the conversation, app access), exactly like messages,
--    so the publication gives the bot nothing beyond chats it is already in;
--    the realtime.messages policies (broadcast, presence) still refuse it.
--  * Reads: a current member who can still read the (undeleted) message. A
--    member who left or was removed sees no reactions at all.
--  * Delivered live through postgres_changes on message_reactions filtered by
--    conversation_id (never broadcast: a broadcast skips RLS). No push.

create table public.message_reactions (
  message_id      uuid not null references public.messages(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  emoji           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (message_id, user_id),
  constraint message_reactions_emoji_check check (
    emoji is null
    or (octet_length(emoji) between 1 and 64
        and emoji !~ '[[:space:][:cntrl:]]')
  )
);
create index message_reactions_conversation_idx
  on public.message_reactions (conversation_id);

alter table public.message_reactions enable row level security;
revoke all on table public.message_reactions from anon, authenticated;
grant select (message_id, user_id, conversation_id, emoji, updated_at)
  on public.message_reactions to authenticated;

-- May the caller see reactions on [message]? It must exist, be undeleted, in a
-- conversation the caller is a CURRENT member of, and readable to them (history
-- window, "delete for me"). SECURITY DEFINER so the policy needs no access to
-- the tables it consults.
create or replace function app_private.reaction_readable(message uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
     where m.id = message
       and m.deleted is null
       and app_private.is_member(m.conversation_id)
       and app_private.message_readable(m)
  )
$$;
revoke all on function app_private.reaction_readable(uuid) from public, anon;
grant execute on function app_private.reaction_readable(uuid) to authenticated;

create policy message_reactions_read on public.message_reactions for select to authenticated
  using ((select app_private.has_app_access())
         and conversation_id = any (app_private.my_conversation_ids())
         and app_private.reaction_readable(message_id));

-- The SIS Bot's send budget (RLMT2), one place for every action that counts as
-- a 'send': messages_bot_rate (20261005130000) and set_reaction. Logs one 'send'
-- and refuses past 20 per 10 minutes or 200 per 24 hours. A refused call rolls
-- back with its log row, so only accepted sends count. The advisory lock
-- serialises one bot's charges so concurrent calls cannot slip past the limit.
create function app_private.bot_send_charge(bot uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  last10 int;
  last24 int;
begin
  perform pg_advisory_xact_lock(hashtextextended('bot_send:' || bot::text, 0));
  delete from app_private.bot_actions a
   where a.bot_id = bot and a.at < now() - interval '24 hours';
  insert into app_private.bot_actions(bot_id, kind) values (bot, 'send');
  select count(*) filter (where a.at >= now() - interval '10 minutes'), count(*)
    into last10, last24
    from app_private.bot_actions a
   where a.bot_id = bot and a.kind = 'send';
  if last10 > 20 or last24 > 200 then
    raise exception 'too many messages' using errcode = 'RLMT2';
  end if;
end $$;
revoke all on function app_private.bot_send_charge(uuid) from public, anon, authenticated;

create or replace function app_private.messages_bot_rate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.is_bot(new.sender_id) then
    return new;
  end if;
  if new.attachment_path is not null then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform app_private.bot_send_charge(new.sender_id);
  return new;
end $$;

-- Sets the caller's reaction on [message] to [emoji], or clears it when [emoji]
-- is null. 42501 for every refusal alike (no app access, message missing or
-- deleted, caller not a current member, message not readable to the caller, the
-- read-only system chat) so the answer reveals nothing; 22023 for an emoji that
-- is empty, longer than 64 bytes, or holds whitespace or control characters.
create function public.set_reaction(message uuid, emoji text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = message for update;
  if not found
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m)
     or app_private.is_system_conversation(m.conversation_id) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if emoji is null then
    update public.message_reactions r
       set emoji = null, updated_at = now()
     where r.message_id = message and r.user_id = auth.uid()
       and r.emoji is not null;
    return;
  end if;
  if octet_length(emoji) not between 1 and 64 or emoji ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid emoji' using errcode = '22023';
  end if;
  if app_private.is_bot(auth.uid()) then
    perform app_private.bot_send_charge(auth.uid());
  end if;
  insert into public.message_reactions(message_id, user_id, conversation_id, emoji)
  values (message, auth.uid(), m.conversation_id, emoji)
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, updated_at = now();
end $$;
revoke all on function public.set_reaction(uuid, text) from public, anon;
grant execute on function public.set_reaction(uuid, text) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'alter publication supabase_realtime add table public.message_reactions';
  end if;
end $$;
