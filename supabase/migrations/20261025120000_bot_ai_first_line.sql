-- SIS Destek first message says it is an AI (t_30e6d5cf87). The first text the
-- bot sends to a user in a 1:1 chat starts with a one-line AI notice, once per
-- user, written in the same transaction as the send. The unique key makes two
-- parallel first sends race safely: the loser inserts 0 rows and adds no line.
-- The user's language is not known on the server, so the line is Turkish.

create table app_private.bot_intro_sent (
  bot_id  uuid not null references auth.users(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (bot_id, user_id)
);
alter table app_private.bot_intro_sent enable row level security;  -- no policies: no client access
revoke all on table app_private.bot_intro_sent from public, anon, authenticated;

create function app_private.messages_bot_intro() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  other uuid;
  n     integer;
begin
  if not app_private.is_bot(new.sender_id) or btrim(new.body) = '' then
    return new;
  end if;
  select m.user_id into other
    from public.conversation_members m
    join public.conversations c on c.id = m.conversation_id
   where m.conversation_id = new.conversation_id
     and m.user_id <> new.sender_id
     and not c.system
     and c.direct_key is not null
     and m.left_at is null
   limit 1;
  if other is null then
    return new;
  end if;
  insert into app_private.bot_intro_sent(bot_id, user_id)
  values (new.sender_id, other)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 1 then
    new.body := 'Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.'
                || E'\n\n' || new.body;
  end if;
  return new;
end $$;
revoke all on function app_private.messages_bot_intro() from public, anon, authenticated;
create trigger messages_bot_intro before insert on public.messages
  for each row execute function app_private.messages_bot_intro();
