-- Update 2: polls. A poll is a message (messages.poll = true, body = the
-- question, so notifications, search and the chat list keep working) plus one
-- polls row, its options and the members' votes.
--
--  * Additive only. An older build reads the poll message as plain text (the
--    question) and never touches these tables.
--  * Clients have no insert/update/delete grant on any of the three tables.
--    The only write paths are create_poll(), vote_poll() and close_poll();
--    each refuses the SIS Bot, a caller without app access, a non-member and
--    the read-only system chat with one answer (42501), so a refusal reveals
--    nothing.
--  * messages.poll is not client-insertable (no column grant) and a poll's
--    body is frozen while the message lives, so the text can never drift from
--    polls.question. Delete for everyone still works (it clears the body and
--    sets deleted); a deleted poll is unreadable (poll_readable).
--  * Counts are NOT computed by clients. poll_options.vote_count and
--    polls.voter_count are maintained by a trigger on poll_votes, recomputed
--    (idempotent) from the votes, so a multi-row vote, a retry or a cascade
--    cannot drift them. Everyone who can read the poll reads the counts.
--  * Anonymous polls: poll_votes is readable only by its own voter while
--    polls.anonymous. The raw table, the REST API and Realtime all go through
--    the same policy, so no other member can learn who voted -- the creator
--    included. A non-anonymous poll shows every vote to every reader.
--  * Realtime: postgres_changes on polls and poll_options (counts, closed),
--    gated by the same read policy as the tables (member of the conversation,
--    app access), exactly like message_reactions. poll_votes is deliberately
--    NOT published: a published vote would put voter ids on the wire, and
--    realtime.apply_rls does not evaluate RLS for a DELETE (a retracted
--    vote). Own votes are read by the client on open and set locally.
--  * A vote counts once per person per option (primary key); a single-answer
--    poll accepts at most one option per person; a closed poll accepts no
--    vote and no retraction.

alter table public.messages add column poll boolean not null default false;

create table public.polls (
  message_id      uuid primary key references public.messages(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  question        text not null check (char_length(question) between 1 and 255),
  multiple        boolean not null,
  anonymous       boolean not null,
  voter_count     integer not null default 0 check (voter_count >= 0),
  closed_at       timestamptz,
  created_at      timestamptz not null default now()
);
create index polls_conversation_idx on public.polls (conversation_id, created_at desc);

create table public.poll_options (
  id              uuid primary key default gen_random_uuid(),
  message_id      uuid not null references public.polls(message_id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  position        smallint not null check (position between 0 and 11),
  text            text not null check (char_length(text) between 1 and 100),
  vote_count      integer not null default 0 check (vote_count >= 0),
  unique (message_id, position)
);
create index poll_options_conversation_idx on public.poll_options (conversation_id);

create table public.poll_votes (
  option_id       uuid not null references public.poll_options(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  message_id      uuid not null references public.polls(message_id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (option_id, user_id)
);
create index poll_votes_message_idx on public.poll_votes (message_id, user_id);
create index poll_votes_user_conversation_idx on public.poll_votes (user_id, conversation_id);

alter table public.polls        enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes   enable row level security;
revoke all on table public.polls, public.poll_options, public.poll_votes
  from anon, authenticated;
grant select on public.polls, public.poll_options to authenticated;
grant select (option_id, user_id, message_id, conversation_id, created_at)
  on public.poll_votes to authenticated;

-- May the caller see the poll of [message]? It must exist, be undeleted, in a
-- conversation the caller is a CURRENT member of, and readable to them
-- (history window, "delete for me"). SECURITY DEFINER so the policies need no
-- access to the tables they consult.
create function app_private.poll_readable(message uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
     where m.id = message
       and m.poll
       and m.deleted is null
       and app_private.is_member(m.conversation_id)
       and app_private.message_readable(m)
  )
$$;
revoke all on function app_private.poll_readable(uuid) from public, anon;
grant execute on function app_private.poll_readable(uuid) to authenticated;

-- Whose vote may the caller see? Their own always; anyone's only when the poll
-- is not anonymous.
create function app_private.poll_vote_visible(message uuid, voter uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select voter = auth.uid()
      or exists (select 1 from public.polls p
                  where p.message_id = message and not p.anonymous)
$$;
revoke all on function app_private.poll_vote_visible(uuid, uuid) from public, anon;
grant execute on function app_private.poll_vote_visible(uuid, uuid) to authenticated;

create policy polls_read on public.polls for select to authenticated
  using ((select app_private.has_app_access())
         and conversation_id = any (app_private.my_conversation_ids())
         and app_private.poll_readable(message_id));

create policy poll_options_read on public.poll_options for select to authenticated
  using ((select app_private.has_app_access())
         and conversation_id = any (app_private.my_conversation_ids())
         and app_private.poll_readable(message_id));

create policy poll_votes_read on public.poll_votes for select to authenticated
  using ((select app_private.has_app_access())
         and conversation_id = any (app_private.my_conversation_ids())
         and app_private.poll_readable(message_id)
         and app_private.poll_vote_visible(message_id, user_id));

-- Counts: recomputed from the votes after every vote row change. Only rows
-- whose number actually changes are written, so a no-op publishes nothing.
create function app_private.poll_votes_count() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r public.poll_votes := case when tg_op = 'DELETE' then old else new end;
begin
  update public.poll_options o
     set vote_count = (select count(*) from public.poll_votes v where v.option_id = r.option_id)
   where o.id = r.option_id
     and o.vote_count is distinct from
         (select count(*) from public.poll_votes v where v.option_id = r.option_id);
  update public.polls p
     set voter_count = (select count(distinct v.user_id) from public.poll_votes v
                         where v.message_id = r.message_id)
   where p.message_id = r.message_id
     and p.voter_count is distinct from
         (select count(distinct v.user_id) from public.poll_votes v
           where v.message_id = r.message_id);
  return null;
end $$;
revoke all on function app_private.poll_votes_count() from public, anon, authenticated;
create trigger poll_votes_count after insert or delete on public.poll_votes
  for each row execute function app_private.poll_votes_count();

-- A poll's body is its question: frozen while the message lives. Delete for
-- everyone clears the body and sets deleted in one update, which is allowed.
create function app_private.messages_poll_body_frozen() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.poll and new.deleted is null and new.body is distinct from old.body then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function app_private.messages_poll_body_frozen() from public, anon, authenticated;
create trigger messages_poll_body_frozen before update of body on public.messages
  for each row execute function app_private.messages_poll_body_frozen();

-- Sends a poll. [p_id] is the new message's id, made on the phone, so a retry
-- after a lost answer is harmless: the same sender, conversation and id is
-- success, a different one is 23505. 2 to 12 options of 1 to 100 characters
-- and a question of 1 to 255 (after trimming), else 22023. 42501 for every
-- other refusal: no app access, the SIS Bot, not a current member, the
-- read-only system chat.
create function public.create_poll(
  p_conversation uuid,
  p_id           uuid,
  p_question     text,
  p_options      text[],
  p_multiple     boolean,
  p_anonymous    boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare
  q    text := btrim(p_question);
  opts text[];
begin
  if not app_private.has_app_access()
     or app_private.is_bot(auth.uid())
     or not app_private.is_member(p_conversation)
     or app_private.is_system_conversation(p_conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p_id is null or p_options is null or p_multiple is null or p_anonymous is null
     or q is null or char_length(q) not between 1 and 255 then
    raise exception 'invalid poll' using errcode = '22023';
  end if;
  select array_agg(btrim(o.t) order by o.n) into opts
    from unnest(p_options) with ordinality as o(t, n);
  if opts is null
     or cardinality(opts) not between 2 and 12
     or exists (select 1 from unnest(opts) o(t)
                 where o.t is null or char_length(o.t) not between 1 and 100) then
    raise exception 'invalid poll' using errcode = '22023';
  end if;

  insert into public.messages(id, conversation_id, sender_id, body, poll)
  values (p_id, p_conversation, auth.uid(), q, true)
  on conflict (id) do nothing;
  if not found then
    if not exists (select 1 from public.messages m
                    where m.id = p_id and m.poll and m.sender_id = auth.uid()
                      and m.conversation_id = p_conversation) then
      raise exception 'id in use' using errcode = '23505';
    end if;
    return;
  end if;

  insert into public.polls(message_id, conversation_id, question, multiple, anonymous)
  values (p_id, p_conversation, q, p_multiple, p_anonymous);
  insert into public.poll_options(message_id, conversation_id, position, text)
  select p_id, p_conversation, (o.n - 1)::smallint, btrim(o.t)
    from unnest(p_options) with ordinality as o(t, n);
end $$;
revoke all on function public.create_poll(uuid, uuid, text, text[], boolean, boolean)
  from public, anon;
grant execute on function public.create_poll(uuid, uuid, text, text[], boolean, boolean)
  to authenticated;

-- Sets the caller's vote on [p_message] to exactly [p_options] (option ids of
-- that poll); an empty array retracts it. The app says what the vote IS, never
-- "toggle", so a retried request is harmless. 42501 for every refusal alike
-- (no app access, the SIS Bot, no such poll, not a current member, message not
-- readable to the caller); 55000 'poll closed'; 22023 for a null array, an
-- option that is not the poll's, or several options on a single-answer poll.
create function public.vote_poll(p_message uuid, p_options uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m    public.messages;
  p    public.polls;
  opts uuid[];
begin
  if not app_private.has_app_access() or app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_message;
  if not found
     or not m.poll
     or m.deleted is not null
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  -- One voter at a time per poll: the lock also orders a vote against close.
  select * into p from public.polls where message_id = p_message for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if p.closed_at is not null then
    raise exception 'poll closed' using errcode = '55000';
  end if;
  if p_options is null then
    raise exception 'invalid vote' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct o), '{}'::uuid[]) into opts from unnest(p_options) o;
  if cardinality(opts) > 1 and not p.multiple then
    raise exception 'invalid vote' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(opts) o
              where not exists (select 1 from public.poll_options po
                                 where po.id = o and po.message_id = p_message)) then
    raise exception 'invalid vote' using errcode = '22023';
  end if;
  -- Insert first, delete after: a voter who only changes their answer is never
  -- momentarily a non-voter, so voter_count does not flicker.
  insert into public.poll_votes(option_id, user_id, message_id, conversation_id)
  select o, auth.uid(), p_message, p.conversation_id from unnest(opts) o
  on conflict do nothing;
  delete from public.poll_votes v
   where v.message_id = p_message and v.user_id = auth.uid()
     and not (v.option_id = any (opts));
end $$;
revoke all on function public.vote_poll(uuid, uuid[]) from public, anon;
grant execute on function public.vote_poll(uuid, uuid[]) to authenticated;

-- Closes the caller's own poll; nobody can vote or retract afterwards. Closing
-- twice is success. 42501 unless the caller sent the poll and is still a
-- current member (same blanket refusals as vote_poll).
create function public.close_poll(p_message uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.messages;
begin
  if not app_private.has_app_access() or app_private.is_bot(auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_message for update;
  if not found
     or not m.poll
     or m.deleted is not null
     or m.sender_id <> auth.uid()
     or not app_private.is_member(m.conversation_id)
     or not app_private.message_readable(m) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  update public.polls p set closed_at = now()
   where p.message_id = p_message and p.closed_at is null;
end $$;
revoke all on function public.close_poll(uuid) from public, anon;
grant execute on function public.close_poll(uuid) to authenticated;

-- The chat list marks a poll preview: one more column at the end (a view may
-- gain columns at the end only). Same definition as 20260929120000, plus poll.
create or replace view public.conversation_previews
with (security_invoker = true) as
select cm.conversation_id, m.body, m.attachment_path, m.created_at,
       m.sender_id, m.deleted, m.poll
  from (select distinct conversation_id from public.conversation_members
         where user_id = auth.uid()) cm
  cross join lateral (
    select mm.body, mm.attachment_path, mm.created_at, mm.sender_id, mm.deleted, mm.poll
      from public.messages mm
     where mm.conversation_id = cm.conversation_id
       and mm.deleted is distinct from 'vanished'
     order by mm.created_at desc
     limit 1
  ) m;
revoke all on public.conversation_previews from anon, authenticated;
grant select on public.conversation_previews to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'alter publication supabase_realtime add table public.polls, public.poll_options';
  end if;
end $$;
