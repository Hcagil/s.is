-- Staff chats: a server registry of chats and their command words. Rows are loaded outside git by app_private.staff_load (below).

-- Staff chats registry.
create table if not exists app_private.staff_chats(
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,30}$'),
  title_en text check (length(title_en) <= 200),
  title_tr text check (length(title_tr) <= 200),
  sort int not null default 0
);

-- The server never reads an email flag: the handler decides if an email is needed. Who may run a handler is fixed in the dispatcher, not here.
create table if not exists app_private.staff_commands(
  chat_key text not null references app_private.staff_chats(key) on delete cascade,
  word text not null check (word ~ '^/[a-z0-9]{2,32}$'),
  handler text not null check (handler in ('tester_add_ios','tester_add_android','tester_remove','tester_list','sales_on','sales_off','sales_total')),
  help_en text check (length(help_en) <= 200),
  help_tr text check (length(help_tr) <= 200),
  sort int not null default 0,
  primary key (chat_key, word)
);

-- No policies and no grants: neither table is reachable from the API.
alter table app_private.staff_chats enable row level security;
alter table app_private.staff_commands enable row level security;
revoke all on table app_private.staff_chats, app_private.staff_commands from public, anon, authenticated;

-- Which staff chat a conversation is. Clients cannot write it (select-only grant).
alter table public.conversations add column if not exists staff_key text;
alter table public.conversations add constraint conversations_staff_key_chk check (staff_key is null or (admin_chat and staff_key ~ '^[a-z][a-z0-9_]{1,30}$'));

-- Two neutral chats; titles and commands arrive from staff_load. Never deleted.
insert into app_private.staff_chats(key, sort) values ('staff_a',1),('staff_b',2) on conflict do nothing;

-- Backfill existing conversations from the old flags.
update public.conversations set staff_key = 'staff_b' where bacanaks_chat and staff_key is null;
update public.conversations set staff_key = 'staff_a' where admin_chat and not bacanaks_chat and staff_key is null;

create index if not exists conversations_staff_key_idx on public.conversations(staff_key) where staff_key is not null;

-- Rows only for chats the caller is still a member of; anyone else gets zero rows, never an error.
create or replace function public.staff_registry()
returns table(
  chat_key text,
  title_en text,
  title_tr text,
  word text,
  handler text,
  help_en text,
  help_tr text,
  sort int
)
language sql stable security definer set search_path = ''
as $$
select c.key, c.title_en, c.title_tr, m.word, m.handler, m.help_en, m.help_tr, m.sort
from app_private.staff_chats c
left join app_private.staff_commands m on m.chat_key = c.key
where (select app_private.has_app_access())
  and not app_private.is_bot((select auth.uid()))
  and exists (
    select 1
    from public.conversations v
    join public.conversation_members cm on cm.conversation_id = v.id
    where v.staff_key = c.key
      and cm.user_id = (select auth.uid())
      and cm.left_at is null
  )
order by c.sort, m.sort;
$$;

revoke all on function public.staff_registry() from public, anon;
grant execute on function public.staff_registry() to authenticated;

-- Loads the registry rows from a private file. Reruns converge. Not callable by any API role.
create or replace function app_private.staff_load(p jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_chat_keys text[];
  v_cmd_keys text[];
begin
  if p is null
     or jsonb_typeof(p->'chats') is distinct from 'array'
     or jsonb_typeof(p->'commands') is distinct from 'array'
     or jsonb_array_length(p->'chats') = 0
     or jsonb_array_length(p->'commands') = 0
  then
    raise exception 'staff_load: bad input';
  end if;

  select array_agg(x.key) into v_chat_keys
    from jsonb_to_recordset(p->'chats') as x(key text);

  -- Only known chat keys; staff_chats rows are never created or deleted here.
  if exists (
    select 1 from unnest(v_chat_keys) as k
    where not exists (select 1 from app_private.staff_chats s where s.key = k)
  ) then
    raise exception 'staff_load: bad input';
  end if;

  select array_agg(y.chat_key) into v_cmd_keys
    from jsonb_to_recordset(p->'commands') as y(chat_key text);

  -- Every command belongs to a chat listed in the same input.
  if exists (select 1 from unnest(v_cmd_keys) as k where k is null or k <> all(v_chat_keys)) then
    raise exception 'staff_load: bad input';
  end if;

  -- Every value is checked here, with the table limits, so a bad value never reaches a constraint (its error would print the row).
  if exists (
    select 1 from jsonb_array_elements(p->'chats') e
    where jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e->'key') is distinct from 'string'
       or coalesce(jsonb_typeof(e->'title_en'), 'null') not in ('null', 'string')
       or coalesce(jsonb_typeof(e->'title_tr'), 'null') not in ('null', 'string')
       or length(e->>'title_en') > 200
       or length(e->>'title_tr') > 200
       or coalesce(jsonb_typeof(e->'sort'), 'null') not in ('null', 'number')
       or (jsonb_typeof(e->'sort') = 'number' and (e->>'sort') !~ '^-?[0-9]{1,9}$')
  ) or exists (
    select 1 from jsonb_array_elements(p->'commands') e
    where jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e->'chat_key') is distinct from 'string'
       or jsonb_typeof(e->'word') is distinct from 'string'
       or (e->>'word') !~ '^/[a-z0-9]{2,32}$'
       or jsonb_typeof(e->'handler') is distinct from 'string'
       or (e->>'handler') not in ('tester_add_ios','tester_add_android','tester_remove','tester_list','sales_on','sales_off','sales_total')
       or coalesce(jsonb_typeof(e->'help_en'), 'null') not in ('null', 'string')
       or coalesce(jsonb_typeof(e->'help_tr'), 'null') not in ('null', 'string')
       or length(e->>'help_en') > 200
       or length(e->>'help_tr') > 200
       or coalesce(jsonb_typeof(e->'sort'), 'null') not in ('null', 'number')
       or (jsonb_typeof(e->'sort') = 'number' and (e->>'sort') !~ '^-?[0-9]{1,9}$')
  ) or (
    select count(*) <> count(distinct (e->>'chat_key') || ' ' || (e->>'word'))
    from jsonb_array_elements(p->'commands') e
  ) then
    raise exception 'staff_load: bad input';
  end if;

  update app_private.staff_chats
  set title_en = x.title_en,
      title_tr = x.title_tr,
      sort = coalesce(x.sort, staff_chats.sort)
  from jsonb_to_recordset(p->'chats') as x(key text, title_en text, title_tr text, sort int)
  where staff_chats.key = x.key;

  -- Commands of the listed chats that are not in the input are removed.
  delete from app_private.staff_commands c
  where c.chat_key = any(v_chat_keys)
    and not exists (
      select 1 from jsonb_to_recordset(p->'commands') as y(chat_key text, word text)
      where y.chat_key = c.chat_key and y.word = c.word
    );

  insert into app_private.staff_commands(chat_key, word, handler, help_en, help_tr, sort)
  select y.chat_key, y.word, y.handler, y.help_en, y.help_tr, coalesce(y.sort, 0)
  from jsonb_to_recordset(p->'commands') as y(
    chat_key text, word text, handler text, help_en text, help_tr text, sort int)
  on conflict (chat_key, word) do update
    set handler = excluded.handler,
        help_en = excluded.help_en,
        help_tr = excluded.help_tr,
        sort = excluded.sort;

  return jsonb_array_length(p->'commands');
end;
$$;

revoke all on function app_private.staff_load(jsonb) from public, anon, authenticated, service_role;
