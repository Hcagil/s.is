-- Checks the private pack against the public side: the owner anchor, untouched public function bodies, locked-down private functions, and (when expected) the required functions.
-- Run through tool/private_install.sh, which sets private.expected first.
do $$
declare
  ex text := current_setting('private.expected', true);
  anchor oid;
  n integer;
  rec record;
  v text;
begin
  if ex is null or ex not in ('', '1') then
    raise exception 'private.expected is missing or wrong';
  end if;

  select p.proowner into anchor from pg_proc p where p.oid = to_regprocedure('app_private.admin_on_message()');
  if anchor is null then
    raise exception 'owner anchor missing';
  end if;

  -- A migration that changes one of these functions must update its hash here.
  for rec in select * from (values
    ('app_private.admin_on_message()','d854e50164cb4022e6fbe43fcdb2a84b'),
    ('app_private.sales_on_message()','8982eee1fff414dc7f57cc746937f579'),
    ('app_private.admin_reply(uuid,jsonb,boolean)','b314ff78d6af821b1189bc19c0575fdc'),
    ('app_private.has_app_access()','d4a7d6af923e083f8e48ab6fa16eed81'),
    ('app_private.is_admin_chat(uuid)','93913ca8fe79a8e1b595a15d37d40b16'),
    ('app_private.is_bot(uuid)','6185d9a602ed43ad547e8ff0f4e4a546'),
    ('app_private.is_member(uuid)','d249f5b785ab8c5738f36b1efe43f230'),
    ('app_private.is_owner()','0e86cae9ef71c26f5f664970d74e3cad'),
    ('public.admin_answer(uuid,boolean)','406da7275ec5e86200ad34908d8c8c1a'),
    ('public.staff_registry()','8ead9d6fcac7e20137f29ba48ab4282c'),
    ('app_private.is_allowed_user()','eb1e3c6bbbd6639db0b157b6f8d41940'),
    ('app_private.jwt_session_id()','9b1cad55e5e3f5bf3070aba83460a5d4')
  ) as t(sig, h) loop
    select md5(p.prosrc) into v from pg_proc p where p.oid = to_regprocedure(rec.sig);
    if v is null or v <> rec.h then
      raise exception 'public function changed: %', rec.sig;
    end if;
  end loop;

  select count(*) into n from pg_proc p where p.pronamespace = 'app_private'::regnamespace and p.proname like 'private\_%' and p.proowner <> anchor;
  if n > 0 then
    raise exception 'private function owner mismatch count %', n;
  end if;

  select count(*) into n from pg_proc p where p.pronamespace = 'app_private'::regnamespace and p.proname like 'private\_%'
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute'));
  if n > 0 then
    raise exception 'private function callable by clients count %', n;
  end if;

  select count(*) into n from pg_proc p where p.pronamespace = 'app_private'::regnamespace and p.proname like 'private\_%'
    and (not p.prosecdef or not coalesce(p.proconfig, array[]::text[]) @> array['search_path=""']);
  if n > 0 then
    raise exception 'private function not definer with empty search_path count %', n;
  end if;

  if ex = '1' then
    for rec in select unnest(array[
      'app_private.private_dispatch(uuid,uuid,text)',
      'app_private.private_panel()',
      'app_private.private_answer(uuid,boolean,uuid)',
      'app_private.private_selfcheck()'
    ]) as sig loop
      if to_regprocedure(rec.sig) is null then
        raise exception 'private function missing: %', rec.sig;
      end if;
    end loop;
    execute 'select coalesce(cardinality(app_private.private_selfcheck()), 0)' into n;
    if n = 0 then
      raise exception 'private selfcheck list is empty';
    end if;
  end if;
end $$;
