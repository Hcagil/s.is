-- Checks that every private: handler in app_private.staff_commands has a correct server function.
-- Run on the throwaway database and on the live database every release.
do $$
declare
  n integer;
  h oid;
  a oid;
  s oid;
  r oid;
begin
  -- Resolve oids
  h := to_regprocedure('app_private.private_handler(text,uuid,uuid,text,text)');
  a := to_regprocedure('app_private.private_answer(uuid,boolean,uuid)');
  s := to_regprocedure('app_private.private_selfcheck()');
  r := to_regprocedure('app_private.admin_handle(uuid,uuid,text)');

  -- 1. Check if private handlers exist and required functions are present
  select count(*) into n from app_private.staff_commands where handler like 'private:%';
  if n > 0 and (h is null or s is null) then
    raise exception 'missing private handler count %', n;
  end if;

  -- 2. Check if all private handlers are answered by private_selfcheck
  if s is not null then
    execute 'select count(*) from app_private.staff_commands c where c.handler like ''private:%'' and substr(c.handler, 9) <> all (coalesce(app_private.private_selfcheck(), array[]::text[]))' into n;
    if n > 0 then
      raise exception 'unanswered private row count %', n;
    end if;
  end if;

  -- 3. Check owner mismatch against admin_handle
  select count(*) into n from pg_proc p where p.oid in (h, a, s) and p.proowner != (select proowner from pg_proc where oid = r);
  if n > 0 then
    raise exception 'private function owner mismatch count %', n;
  end if;

  -- 4. Check if private functions are callable by clients
  select count(*) into n from pg_proc p where p.oid in (h, a, s) and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if n > 0 then
    raise exception 'private function callable by clients count %', n;
  end if;

  -- 5. Check if private functions are definer with empty search_path
  select count(*) into n from pg_proc p where p.oid in (h, a, s) and (p.prosecdef = false or not coalesce(p.proconfig, array[]::text[]) @> array['search_path=""']);
  if n > 0 then
    raise exception 'private function not definer with empty search_path count %', n;
  end if;
end $$;
