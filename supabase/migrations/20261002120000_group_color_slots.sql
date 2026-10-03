-- v0.30.7: a colour for every person in a group chat.
--
-- Each person in a conversation holds a colour SLOT (0..9), chosen by the
-- server when they first join and never changed afterwards, so every phone
-- agrees on who is which colour. The app maps a slot to a colour (a ten-colour
-- palette, light and dark); the server only hands out the number.
--
--   * Free slot first: a new joiner takes the lowest slot nobody in the
--     conversation holds -- departed members still hold theirs, so an old
--     message never changes colour and never shares one with a newcomer.
--   * Every slot taken (more than ten people, ever): the slot held by the
--     fewest people is reused (lowest number on a tie).
--   * Someone who leaves and is added again keeps their slot: the new
--     membership row copies the earlier one.
--
-- The slot lives on conversation_members, next to the membership it belongs
-- to. It is assigned by a trigger only: the app has no insert or update grant
-- on this table, and the new column is granted to `authenticated` for SELECT
-- alone, so nobody can set a slot -- their own or another member's -- from the
-- app. The existing read policy decides who sees a row, and so who sees its
-- slot (members and former members of that conversation, as for role).

-- DEFAULT 0 only so a row inserted with triggers off (bulk fixtures,
-- session_replication_role = replica) still satisfies NOT NULL; the trigger
-- below always overwrites it.
alter table public.conversation_members
  add column color_slot smallint not null default 0
  check (color_slot between 0 and 9);

-- Backfill by join order: the earliest person takes 0, the next 1, ...,
-- wrapping after ten. A person with several rows (left, then added again)
-- keeps one slot across all of them, ranked by their first row.
with first_join as (
  select conversation_id, user_id, min(joined_at) as first_at
    from public.conversation_members
   group by conversation_id, user_id
), ranked as (
  select conversation_id, user_id,
         ((row_number() over (partition by conversation_id
                              order by first_at, user_id) - 1) % 10)::smallint as slot
    from first_join
)
update public.conversation_members cm
   set color_slot = r.slot
  from ranked r
 where r.conversation_id = cm.conversation_id
   and r.user_id = cm.user_id;

-- Read-only to the app (see the header). History_from stays unlisted, as before.
grant select (color_slot) on public.conversation_members to authenticated;

create or replace function app_private.assign_color_slot() returns trigger
language plpgsql set search_path = '' as $$
declare
  slot smallint;
begin
  -- Two people joining at the same moment must not both read "slot 3 is free".
  perform pg_advisory_xact_lock(hashtextextended('color_slot:' || new.conversation_id::text, 0));

  -- Added again after leaving: the earlier slot comes back.
  select cm.color_slot into slot
    from public.conversation_members cm
   where cm.conversation_id = new.conversation_id
     and cm.user_id = new.user_id
   order by cm.joined_at desc
   limit 1;

  if slot is null then
    -- Free slot first, else the least used one; lowest number on a tie.
    select g.n::smallint into slot
      from generate_series(0, 9) as g(n)
     order by (select count(distinct cm.user_id)
                 from public.conversation_members cm
                where cm.conversation_id = new.conversation_id
                  and cm.color_slot = g.n),
              g.n
     limit 1;
  end if;

  -- Whatever the insert carried is ignored: only the server assigns slots.
  new.color_slot := slot;
  return new;
end $$;
revoke all on function app_private.assign_color_slot() from public, anon, authenticated;

create trigger conversation_members_color_slot
  before insert on public.conversation_members
  for each row execute function app_private.assign_color_slot();
