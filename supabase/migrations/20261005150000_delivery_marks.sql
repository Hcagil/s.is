-- Update 1, slice 5a: per-member message delivery, recorded on the server.
--
-- The tick rule: one tick = sent; two grey ticks = delivered to EVERY other
-- member; two blue ticks = read by EVERY other member. Reads were already
-- recorded (last_read_at / shared_read_at); delivery was not.
--
--  * conversation_members.delivered_at is the delivery position of one
--    membership: every message of the conversation created at or before it has
--    reached that member's device. Same idea as last_read_at, and like it only
--    ever moves forward, never readable through the column grant (the list in
--    20260929120000 does not name it), reachable only through the functions
--    below.
--  * Existing rows start at the newest message they had read (a message you
--    have read has been delivered), or joined_at if none; never the raw
--    last_read_at, which could be a read time that is not shared.
--    New memberships start at now(), "caught up", like last_read_at and shared_read_at: history before joining
--    is not something delivery is owed for.
--  * mark_delivered(conversation, up_to) is the way the app moves it. The
--    receiving device calls it when messages reach it (fetch, Realtime, push).
--    mark_read also moves it, since reading implies delivery. Both go through
--    app_private.advance_delivery, which snaps the position to a real
--    message's created_at (never a clock reading).
--  * Delivery does NOT depend on the "show when I have read" switch: a member
--    with receipts off still reports delivery, so the sender's grey ticks work.
--    read_marks() therefore returns delivered_at whatever `shares` says, and
--    also for someone no longer on the allowlist who is still in the
--    conversation (a stored position is a fact, and hiding it would leave the
--    sender's ticks stuck below two for everyone else).
--  * Live: when the position advances, advance_delivery sends one
--    Realtime broadcast, event 'delivered' on topic 'delivered:<conversation>',
--    payload {user_id, delivered_at}. It is a separate topic from 'reads:'
--    because that one is gated on the receiver sharing read status, which
--    delivery must not depend on. Receiving: a CURRENT member with app access,
--    never the SIS Bot (the bot has no Realtime at all). No client can send on
--    it (no send policy matches it).
--  * Volume (S-1 lesson): no table is added to the publication. A write and a
--    broadcast happen only when the position strictly advances; a repeat call,
--    or one clamped to where it already is, runs a single indexed UPDATE that
--    matches no row and sends nothing.

alter table public.conversation_members add column delivered_at timestamptz;
update public.conversation_members cm
   set delivered_at = coalesce(
     (select max(m.created_at) from public.messages m
       where m.conversation_id = cm.conversation_id
         and m.created_at <= cm.last_read_at),
     cm.joined_at);
alter table public.conversation_members
  alter column delivered_at set default now(),
  alter column delivered_at set not null;

-- The one place delivery moves, shared by mark_delivered and mark_read so the
-- two cannot drift. Acts on the caller's own CURRENT membership only (a
-- departed member is owed no delivery of later messages). The position is
-- SNAPPED to a real message: the newest message created at or before
-- least(up_to, now()). So it can only ever hold a message's own timestamp,
-- never the caller's clock or the moment of a read (delivery must not leak
-- when someone read or went online), and an `up_to` stepped forward by
-- microseconds changes nothing once it reaches the same message: no write, no
-- broadcast. It updates only where delivered_at < pos and broadcasts only when
-- a row actually changed, with that stored value. No messages: nothing to do.
create function app_private.advance_delivery(conversation uuid, up_to timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  pos timestamptz;
begin
  select max(m.created_at) into pos
    from public.messages m
   where m.conversation_id = conversation
     and m.created_at <= least(coalesce(up_to, now()), now());
  if pos is null then
    return;
  end if;
  update public.conversation_members cm
     set delivered_at = pos
   where cm.conversation_id = conversation
     and cm.user_id = auth.uid()
     and cm.left_at is null
     and cm.delivered_at < pos;
  if found then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'delivered_at', pos),
      'delivered',
      'delivered:' || conversation::text,
      true);
  end if;
end $$;
revoke all on function app_private.advance_delivery(uuid, timestamptz)
  from public, anon, authenticated;

-- 42501 for every refusal alike: no app access (this is also how the SIS Bot is
-- refused while it is OFF), or not a current member. [up_to] is what the device
-- claims to have received; null means "everything so far". Returns void.
create function public.mark_delivered(conversation uuid, up_to timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.has_app_access()
     or not app_private.is_member(conversation) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  perform app_private.advance_delivery(conversation, up_to);
end $$;
revoke all on function public.mark_delivered(uuid, timestamptz) from public, anon;
grant execute on function public.mark_delivered(uuid, timestamptz) to authenticated;

-- mark_read: unchanged (20260929120000) except that, for a current member, it
-- also calls the delivery helper (reading implies delivery). It does NOT write
-- delivered_at = now(): that would reveal the exact read time of a member who
-- shows no read receipts.
create or replace function public.mark_read(conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sharing boolean := app_private.shares_read_status();
  target  public.conversation_members;
  cap     timestamptz;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  select * into target from public.conversation_members m
   where m.conversation_id = conversation and m.user_id = auth.uid()
   order by (m.left_at is null) desc, m.left_at desc
   limit 1
   for update;
  if not found then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  cap := least(now(), coalesce(target.left_at, 'infinity'::timestamptz));
  update public.conversation_members m
     set last_read_at = cap,
         shared_read_at = case when sharing then cap else m.shared_read_at end
   where m.id = target.id;
  if target.left_at is null then
    perform app_private.advance_delivery(conversation, null);
  end if;
  if sharing and target.left_at is null then
    perform realtime.send(
      jsonb_build_object('user_id', auth.uid(), 'read_at', cap),
      'read',
      'reads:' || conversation::text,
      true);
  end if;
end $$;

-- read_marks gains a fourth column, delivered_at. Old builds read the three
-- columns they know by name and ignore the extra key, so they keep working.
-- A return type cannot change under create or replace, hence drop + create in
-- this one transaction; grants restated.
drop function public.read_marks(uuid);
create function public.read_marks(conversation uuid)
returns table (user_id uuid, shares boolean, read_at timestamptz, delivered_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select cm.user_id,
         both_share,
         case when both_share then cm.shared_read_at end,
         cm.delivered_at
    from public.conversation_members cm
    left join public.profiles p on p.user_id = cm.user_id
   cross join lateral (
     select coalesce(p.share_read_status, false)
            and app_private.is_allowed(cm.user_id)
            and app_private.shares_read_status() as both_share
   ) s
   where cm.conversation_id = conversation
     and cm.user_id <> auth.uid()
     and cm.left_at is null
     and app_private.has_app_access()
     and app_private.is_member(conversation)
$$;
revoke all on function public.read_marks(uuid) from public, anon;
grant execute on function public.read_marks(uuid) to authenticated;

-- Receiving 'delivered:<conversation>': 20261005130000's policy plus one
-- branch, NOT gated on shares. Bot confinement is kept as it was: the bot gets
-- no Realtime at all.
create function app_private.delivered_conversation(topic text)
returns uuid language plpgsql immutable set search_path = '' as $$
declare
  rest text;
begin
  if topic is null or left(topic, 10) <> 'delivered:' then
    return null;
  end if;
  rest := substr(topic, 11);
  if rest !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return null;
  end if;
  return rest::uuid;
end $$;
revoke all on function app_private.delivered_conversation(text) from public, anon;
grant execute on function app_private.delivered_conversation(text) to authenticated;

drop policy realtime_receive on realtime.messages;
create policy realtime_receive on realtime.messages for select to authenticated
  using (
    (select app_private.has_app_access())
    and not app_private.is_bot((select auth.uid()))
    and (
      (realtime.topic() = 'presence:members' and extension = 'presence')
      or (extension = 'broadcast'
          and app_private.is_member(app_private.typing_conversation(realtime.topic())))
      or (extension = 'broadcast'
          and app_private.is_member(app_private.reads_conversation(realtime.topic()))
          and app_private.shares_read_status())
      or (extension = 'broadcast'
          and app_private.is_member(app_private.delivered_conversation(realtime.topic())))
    )
  );
