-- Push receipts (0.25.1): what became of each push that reached a phone.
--
-- Pushes are data only and the app draws them itself in a background isolate
-- that nobody can watch. When one goes missing there was no way to tell
-- whether it never arrived, was dropped by a check, or crashed. The phone now
-- keeps one line per stage and uploads them the next time the app opens.
--
-- Privacy: a receipt holds the stage, the message id, a short error class and
-- the build number. Never a title, a body or a name.
create table app_private.push_receipts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  message_id  uuid,
  stage       text not null check (
                stage in ('received', 'shown', 'error')
                or stage ~ '^dropped:[a-z_]{1,40}$'),
  error       text check (char_length(error) <= 300),
  build       integer,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index push_receipts_user_idx on app_private.push_receipts (user_id, id desc);
alter table app_private.push_receipts enable row level security;  -- no policies: no access
revoke all on table app_private.push_receipts from anon, authenticated;

-- Stores a batch of receipts for the caller. Each element:
-- {message_id?, stage, error?, build?, occurred_at?}. An element that is not
-- valid is skipped, never an error: one bad line must not make the phone
-- resend the same batch for ever. At most 100 elements per call; only the
-- caller's newest 500 receipts are kept. Returns how many were stored.
create function public.report_push_receipts(receipts jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  i integer;
  n integer := 0;
  s text;
  mid uuid;
  at timestamptz;
begin
  if not app_private.has_app_access() then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  if receipts is null or jsonb_typeof(receipts) <> 'array' then
    raise exception 'invalid receipts' using errcode = '22023';
  end if;

  -- Only the first 100 are ever read: the rest of a large array is not
  -- expanded.
  for i in 0 .. least(jsonb_array_length(receipts), 100) - 1 loop
    r := receipts -> i;
    s := case when jsonb_typeof(r) = 'object' then r ->> 'stage' end;
    continue when s is null
      or not (s in ('received', 'shown', 'error') or s ~ '^dropped:[a-z_]{1,40}$');
    mid := null;
    at := null;
    begin
      mid := (r ->> 'message_id')::uuid;
    exception when others then mid := null;
    end;
    begin
      at := (r ->> 'occurred_at')::timestamptz;
    exception when others then at := null;
    end;
    insert into app_private.push_receipts
      (user_id, message_id, stage, error, build, occurred_at)
    values (
      auth.uid(), mid, s,
      left(r ->> 'error', 300),
      case when (r ->> 'build') ~ '^[0-9]{1,9}$' then (r ->> 'build')::integer end,
      least(now(), greatest(now() - interval '7 days', coalesce(at, now()))));
    n := n + 1;
  end loop;

  delete from app_private.push_receipts p
   where p.user_id = auth.uid()
     and p.id <= (select q.id from app_private.push_receipts q
                   where q.user_id = auth.uid()
                   order by q.id desc offset 500 limit 1);
  return n;
end $$;
revoke all on function public.report_push_receipts(jsonb) from public, anon;
grant execute on function public.report_push_receipts(jsonb) to authenticated;
