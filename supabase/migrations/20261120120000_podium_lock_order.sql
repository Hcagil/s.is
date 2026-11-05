-- Both functions now lock in one order: podium_state row first, then job rows (fixes a possible deadlock).

create or replace function app_private.podium_handle(conv uuid, uid uuid, body text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    t text := btrim(body, E' \t\r\n');
    r record;
    cnt integer;
    st app_private.podium_state;
    ist timestamp;
    prev boolean;
    d date;
    inflight boolean;
  begin
    -- One ask per user at a time, so a parallel burst cannot pass the limit below.
    perform pg_advisory_xact_lock(hashtextextended('podium:' || uid::text, 0));
    -- Locks the one state row: concurrent asks run one after the other.
    select * into st from app_private.podium_state for update;
    -- No cron: each ask fails jobs that never got an answer.
    for r in select id, conversation_id from app_private.podium_jobs where state in ('pending','running','waiting') and created_at < now() - interval '2 minutes' loop
      update app_private.podium_jobs set state='failed' where id = r.id;
      perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
    end loop;

    -- Rate limit: 30 commands per 10 minutes
    select count(*) into cnt from app_private.podium_commands where user_id = uid and at > now() - interval '10 minutes';
    if cnt >= 30 then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podRate'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'unknown','rate');
      return;
    end if;

    if lower(t) <> '/podium' then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podUnk'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'unknown','unk');
      return;
    end if;

    if st.off then
      perform app_private.admin_reply(conv, jsonb_build_object('k','podOff'));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium','off');
      return;
    end if;

    -- The business day comes from the server clock in Istanbul, never from the phone.
    ist := now() at time zone 'Europe/Istanbul';
    d := app_private.podium_business_day(now());
    prev := d < ist::date;

    -- Shared 30 s gap between Vega calls: a fresh answer is reused.
    if st.fetched_at is not null and st.fetched_at > now() - interval '30 seconds' and st.day = d and st.amount is not null then
      perform app_private.admin_reply(conv, jsonb_build_object('k', case when prev then 'podPrev' else 'pod' end, 'amt', st.amount, 'day', d, 'at', st.fetched_at));
      insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium','cache');
      return;
    end if;

    inflight := exists (select 1 from app_private.podium_jobs where state in ('pending','running') and created_at > now() - interval '30 seconds');
    insert into app_private.podium_jobs(conversation_id, state, prev, day) values (conv, case when inflight then 'waiting' else 'pending' end, prev, d);
    insert into app_private.podium_commands(user_id, command, outcome) values (uid,'/podium', case when inflight then 'wait' else 'ask' end);
  end;
$$;
revoke all on function app_private.podium_handle(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.podium_job_finish(job uuid, amount text, reason text) returns void language plpgsql security definer set search_path = '' as $$
  declare
    j app_private.podium_jobs;
    r record;
    ok boolean;
  begin
    -- lock order: state row first, then job rows (same as podium_handle)
    perform 1 from app_private.podium_state where only_row for update;
    select * into j from app_private.podium_jobs where id = job and state = 'running' for update;
    if not found then return; end if;

    ok := amount is not null and length(amount) <= 25 and amount ~ '^[0-9]{1,3}([.,'' ][0-9]{3})*([.,][0-9]{1,2})?$|^[0-9]+([.,][0-9]{1,2})?$';

    if ok then
      update app_private.podium_state set amount = podium_job_finish.amount, day = j.day, fetched_at = now(), fail_count = 0 where only_row;
    else
      update app_private.podium_state set fail_count = case when reason is distinct from 'config' then fail_count + 1 else fail_count end, off = off or (reason is distinct from 'config' and fail_count + 1 >= 3) where only_row;
    end if;

    -- waiting asks get the same answer
    for r in select id, conversation_id from app_private.podium_jobs where id = job or state = 'waiting' loop
      if ok then
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k', case when j.prev then 'podPrev' else 'pod' end, 'amt', amount, 'day', j.day, 'at', now()));
      else
        perform app_private.admin_reply(r.conversation_id, jsonb_build_object('k','podFail'));
      end if;
      update app_private.podium_jobs set state = case when ok then 'done' else 'failed' end where id = r.id;
    end loop;
  end;
$$;
revoke all on function public.podium_job_finish(uuid, text, text) from public, anon, authenticated;
grant execute on function public.podium_job_finish(uuid, text, text) to service_role;
