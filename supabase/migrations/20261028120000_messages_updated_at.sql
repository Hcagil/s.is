-- Update 3: messages.updated_at, the change feed for the on-phone store.
--
--  * Additive only: one timestamptz column, one trigger, one function and one
--    index. RLS is untouched: messages_read already bounds the rows a member
--    can read, so a change feed read through it shows nothing new.
--  * The column has no insert or update grant, and the trigger overwrites any
--    value, so a client can never set it.
--  * clock_timestamp() (not now()) keeps the value close to commit time; the
--    phone also overlaps its cursor by a few seconds and dedupes by id.

alter table public.messages add column updated_at timestamptz not null default now();

create function app_private.messages_touch_updated_at() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;
revoke all on function app_private.messages_touch_updated_at() from public, anon, authenticated;
create trigger messages_touch_updated_at before insert or update on public.messages
  for each row execute function app_private.messages_touch_updated_at();

create index messages_updated_at_idx on public.messages (updated_at, id);
