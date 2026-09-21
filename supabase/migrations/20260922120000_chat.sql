-- 1:1 text chat for SIS v0.2: conversations, membership and messages.
-- Purely additive: builds older than this migration simply never touch these
-- tables, so min_supported_build does not move.

-- Conversations -------------------------------------------------------------
-- direct_key makes a 1:1 pair unique, so two devices starting the same chat at
-- the same moment converge on one conversation instead of forking the history.
-- v0.3 group conversations will carry a null direct_key.
create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  direct_key text unique,
  created_at timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  joined_at       timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members(user_id);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references auth.users(id) on delete cascade,
  body            text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at      timestamptz not null default now()
);
-- The message screen reads one conversation newest-first, and pages backwards.
create index messages_conversation_idx on public.messages(conversation_id, created_at desc);

-- Membership ----------------------------------------------------------------
-- security definer: a membership policy that read conversation_members to
-- decide who may read conversation_members would recurse. This is the one
-- place that reads it without RLS.
create or replace function app_private.is_member(conversation uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversation_members m
                  where m.conversation_id = conversation and m.user_id = auth.uid())
$$;
revoke all on function app_private.is_member(uuid) from public, anon;
grant execute on function app_private.is_member(uuid) to authenticated;

-- Policies ------------------------------------------------------------------
-- Every policy is has_app_access() AND membership: losing the active session
-- revokes chat access at the same instant it revokes everything else.
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;
revoke all on public.conversations, public.conversation_members, public.messages
  from anon, authenticated;

create policy conversations_read on public.conversations for select to authenticated
  using (app_private.has_app_access() and app_private.is_member(id));

create policy conversation_members_read on public.conversation_members for select to authenticated
  using (app_private.has_app_access() and app_private.is_member(conversation_id));

create policy messages_read on public.messages for select to authenticated
  using (app_private.has_app_access() and app_private.is_member(conversation_id));

-- Sending is the only client write in v0.2. Editing and deleting are not in
-- scope, so no update or delete policy exists.
create policy messages_send on public.messages for insert to authenticated
  with check (app_private.has_app_access()
              and sender_id = auth.uid()
              and app_private.is_member(conversation_id));

grant select on public.conversations, public.conversation_members, public.messages to authenticated;
-- Column-level on purpose. A table-wide insert grant would let a member choose
-- id and created_at, and since messages can never be edited or deleted, a
-- back-dated created_at would pin a message to the top of the other party's
-- history permanently. Withholding the columns makes the defaults authoritative.
grant insert (conversation_id, sender_id, body) on public.messages to authenticated;

-- Starting a chat -----------------------------------------------------------
-- Conversations and membership have no client write policy at all: a client
-- that could insert its own membership rows could join any conversation. This
-- RPC is the only way in, and it only ever creates a pair the caller belongs to.
create or replace function public.start_direct_conversation(other_user uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me  uuid := auth.uid();
  key text;
  cid uuid;
begin
  if not app_private.has_app_access() or other_user is null or other_user = me then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- The other side must be an allowlisted, confirmed member too.
  if not exists (select 1
                   from auth.users u
                   join app_private.allowlist a on a.email = lower(btrim(u.email))
                  where u.id = other_user and u.email_confirmed_at is not null) then
    raise exception 'not permitted' using errcode = '42501';
  end if;

  key := least(me::text, other_user::text) || ':' || greatest(me::text, other_user::text);

  insert into public.conversations(direct_key) values (key)
    on conflict (direct_key) do nothing
    returning id into cid;
  if cid is null then
    select c.id into cid from public.conversations c where c.direct_key = key;
  else
    insert into public.conversation_members(conversation_id, user_id)
    values (cid, me), (cid, other_user);
  end if;
  return cid;
end $$;
revoke all on function public.start_direct_conversation(uuid) from public, anon;
grant execute on function public.start_direct_conversation(uuid) to authenticated;

-- Realtime ------------------------------------------------------------------
-- Realtime re-checks the select policy per subscriber for INSERT and UPDATE,
-- but realtime.apply_rls delivers DELETE to every subscriber of the table
-- without evaluating RLS at all. Messages are insert-only in v0.2, so the only
-- deletes are cascades from account or conversation removal -- but those would
-- still fan a row id out to people who cannot read the conversation. Publishing
-- inserts only closes that path rather than documenting it as an exception.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'alter publication supabase_realtime set (publish = ''insert'')';
    execute 'alter publication supabase_realtime add table public.messages';
  end if;
end $$;
