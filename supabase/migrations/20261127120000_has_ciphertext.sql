-- Computed field for PostgREST so the pinned bar reads a flag, not the ciphertext.
create function public.has_ciphertext(m public.messages)
returns boolean
language sql
stable
set search_path = ''
as $$ select m.ciphertext is not null $$;

revoke all on function public.has_ciphertext(public.messages) from public, anon;
grant execute on function public.has_ciphertext(public.messages) to authenticated;
