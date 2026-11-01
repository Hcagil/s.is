-- The English first line of the SIS bot names it SIS Support (owner 2026-11-01); the Turkish line
-- and the bot's stored display name are unchanged. The function is the one from
-- 20261029120000_app_language.sql with the two English strings replaced.
create or replace function app_private.messages_bot_intro()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  other uuid;
  n     integer;
  line text;
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
    -- group chat: once per (bot, conversation), not per member
    if exists (select 1 from public.conversations c
                where c.id = new.conversation_id and not c.system and c.direct_key is null) then
      line := case when not exists (select 1 from public.conversation_members m where m.conversation_id = new.conversation_id and m.user_id <> new.sender_id and m.left_at is null and not app_private.is_bot(m.user_id)) or exists (select 1 from public.conversation_members m left join public.profiles p on p.user_id = m.user_id where m.conversation_id = new.conversation_id and m.user_id <> new.sender_id and m.left_at is null and not app_private.is_bot(m.user_id) and p.app_language is distinct from 'en') then 'Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.' else 'Hi, I''m SIS Support, an AI assistant. My replies are written by AI.' end;
      insert into app_private.bot_group_intro_sent(bot_id, conversation_id)
      values (new.sender_id, new.conversation_id)
      on conflict do nothing;
      get diagnostics n = row_count;
      if n = 1 then
        new.body := line || E'\n\n' || new.body;
      end if;
    end if;
    return new;
  end if;
  line := case when (select p.app_language from public.profiles p where p.user_id = other) = 'en' then 'Hi, I''m SIS Support, an AI assistant. My replies are written by AI.' else 'Merhaba, ben SIS Destek, bir yapay zekâ asistanıyım. Mesajlarımı yapay zekâ yazar.' end;
  insert into app_private.bot_intro_sent(bot_id, user_id)
  values (new.sender_id, other)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 1 then
    new.body := line || E'\n\n' || new.body;
  end if;
  return new;
end $$;
revoke all on function app_private.messages_bot_intro() from public, anon, authenticated;
