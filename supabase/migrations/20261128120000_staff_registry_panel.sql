-- Staff registry: a thin wrapper; the rows come from the private panel function, zero rows when it is missing or fails.

drop function if exists public.staff_registry();

create function public.staff_registry()
returns table(
    chat_key text,
    title_en text,
    title_tr text,
    word text,
    handler text,
    arg text,
    ui text,
    help_en text,
    help_tr text,
    sort int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if not (select app_private.has_app_access()) or app_private.is_bot((select auth.uid())) then
        return;
    end if;

    if to_regprocedure('app_private.private_panel()') is null then
        return;
    end if;

    return query execute
        'select p.chat_key, p.title_en, p.title_tr, p.word, p.handler, p.arg, p.ui, p.help_en, p.help_tr, p.sort
         from app_private.private_panel() p
         where exists (
             select 1
             from public.conversations v
             join public.conversation_members cm on cm.conversation_id = v.id
             where v.staff_key = p.chat_key
               and cm.user_id = (select auth.uid())
               and cm.left_at is null
         )
         order by p.chat_key, p.sort';

exception when others then
    return;
end;
$$;

revoke all on function public.staff_registry() from public, anon;
grant execute on function public.staff_registry() to authenticated;
