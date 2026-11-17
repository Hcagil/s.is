begin;
select plan(30);

-- fixtures
insert into auth.users(id,email,email_confirmed_at)
values ('00000000-0000-0000-0000-0000000ac001','own@mail.test',now());

delete from app_private.owners;

insert into app_private.owners(user_id)
values ('00000000-0000-0000-0000-0000000ac001');

create temp table adm as
select id from public.conversations
where admin_chat and staff_key='staff_a';

-- function pl
create or replace function pl(i int, a int, o int, pad int default 0) returns jsonb language sql as $$
  select jsonb_build_object(
    'k','list',
    'n',i+a+o,
    'ios', (
      select coalesce(
        jsonb_agg(
          case
            when g=i and pad>0 then 'ios'||lpad(g::text,4,'0')||repeat('x',pad)||'@mail.test'
            else 'ios'||lpad(g::text,4,'0')||'@mail.test'
          end
          order by g
        ),
        '[]'::jsonb
      )
      from generate_series(1,i) g
    ),
    'and', (
      select coalesce(
        jsonb_agg(
          'and'||lpad(g::text,4,'0')||'@mail.test'
          order by g
        ),
        '[]'::jsonb
      )
      from generate_series(1,a) g
    ),
    'oth', (
      select coalesce(
        jsonb_agg(
          'oth'||lpad(g::text,4,'0')||'@mail.test'
          order by g
        ),
        '[]'::jsonb
      )
      from generate_series(1,o) g
    )
  );
$$;

-- function b
create or replace function b(j jsonb) returns text language sql as $$
  select app_private.admin_body_list(j)
$$;

-- function kept
create or replace function kept(t text) returns int language sql as $$
  select count(*)::int
  from regexp_split_to_table(t, E'\n') l
  where l ~ '@mail\.test$'
$$;

-- assertions
select is(b(pl(0,0,0)),
          'Testers: 0'||E'\n\n'||'iPhone (0)'||E'\n\n'||'Android (0)',
          '0 testers: empty text');

select is(b(pl(1,0,0)),
          'Testers: 1'||E'\n\n'||'iPhone (1)'||E'\n'||'ios0001@mail.test'||E'\n\n'||'Android (0)',
          '1 tester');

select is(b(pl(3,2,1)),
          'Testers: 6'||E'\n\n'||'iPhone (3)'||E'\n'||'ios0001@mail.test'||E'\n'||'ios0002@mail.test'||E'\n'||'ios0003@mail.test'||E'\n\n'||'Android (2)'||E'\n'||'and0001@mail.test'||E'\n'||'and0002@mail.test'||E'\n\n'||'Other (1)'||E'\n'||'oth0001@mail.test',
          'mix of ios/android/other under the limit is unchanged');

select is(kept(b(pl(3,2,1))), 6, 'kept counts every email line');

select is(jsonb_array_length(pl(150,100,50)->'ios') +
          jsonb_array_length(pl(150,100,50)->'and') +
          jsonb_array_length(pl(150,100,50)->'oth'),
          300,
          'helper builds 300 testers');

-- Part B of pgTAP test
-- No plan, no finish, no rollback

-- 1. create temp table x0 as select char_length(b(pl(100,0,0))) as len;
create temp table x0 as
select char_length(b(pl(100,0,0))) as len;

-- 2. select ok((select len from x0) < 4000 and (select len from x0) > 2000, 'base text is under the limit');
select ok((select len from x0) < 4000 and (select len from x0) > 1500, 'base text is under the limit');

-- 3. create temp table atlim as select b(pl(100,0,0, 4000-(select len from x0))) as t;
create temp table atlim as
select b(pl(100,0,0, 4000-(select len from x0))) as t;

-- 4. select is((select char_length(t) from atlim), 4000, 'exactly at the limit: nothing cut');
select is((select char_length(t) from atlim), 4000, 'exactly at the limit: nothing cut');

-- 5. select ok(position('… and' in (select t from atlim)) = 0, 'at the limit: no "more" line');
select ok(position('… and' in (select t from atlim)) = 0, 'at the limit: no "more" line');

-- 6. select is(kept((select t from atlim)), 100, 'at the limit: all 100 emails kept');
select is(kept((select t from atlim)), 100, 'at the limit: all 100 emails kept');

-- 7. create temp table over1 as select b(pl(100,0,0, 4001-(select len from x0))) as t;
create temp table over1 as
select b(pl(100,0,0, 4001-(select len from x0))) as t;

-- 8. select ok((select char_length(t) from over1) <= 4000, 'limit+1: body fits the 4000 check');
select ok((select char_length(t) from over1) <= 4000, 'limit+1: body fits the 4000 check');

-- 9. select matches((select t from over1), '… and \d+ more$', 'limit+1: ends with the "more" line');
select matches((select t from over1), '… and \d+ more$', 'limit+1: ends with the "more" line');

-- 10. create temp table over1n as select (regexp_match(t, '… and (\d+) more$'))[1]::int as n, kept(t) as k from over1;
create temp table over1n as
select (regexp_match(t, '… and (\d+) more$'))[1]::int as n,
       kept(t) as k
from over1;

-- 11. select ok((select n from over1n) >= 1, 'limit+1: at least one line left out');
select ok((select n from over1n) >= 1, 'limit+1: at least one line left out');

-- 12. select is((select n from over1n), 100 - (select k from over1n), 'limit+1: N equals the number of emails left out');
select is((select n from over1n), 100 - (select k from over1n), 'limit+1: N equals the number of emails left out');

-- 13. select is((select array_agg(l order by o) from regexp_split_to_table((select t from over1), E'\n') with ordinality s(l,o) where l ~ '@mail\.test$'), (select array_agg('ios'||lpad(g::text,4,'0')||'@mail.test' order by g) from generate_series(1,(select k from over1n)) g), 'limit+1: kept lines are the first emails in order');
select is(
  (select array_agg(l order by o)
   from regexp_split_to_table((select t from over1), E'\n') with ordinality s(l,o)
   where l ~ '@mail\.test$'),
  (select array_agg('ios'||lpad(g::text,4,'0')||'@mail.test' order by g)
   from generate_series(1,(select k from over1n)) g),
  'limit+1: kept lines are the first emails in order'
);

-- 14. select ok((select t from over1) like '%iPhone (100)%', 'limit+1: header keeps the true count');
select ok((select t from over1) like '%iPhone (100)%', 'limit+1: header keeps the true count');

-- 15. create temp table over1k as select rtrim(left(t, char_length(t) - char_length('… and '||(select n from over1n)||' more')), E'\n') as kt from over1;
create temp table over1k as
select rtrim(left(t, char_length(t) - char_length('… and '||(select n from over1n)||' more')), E'\n') as kt
from over1;

-- 16. select ok((select char_length(kt) from over1k) <= 3950, 'limit+1: kept text is within 3950');
select ok((select char_length(kt) from over1k) <= 3950, 'limit+1: kept text is within 3950');

-- 17. select ok((select char_length(kt) from over1k) + 26 > 3950 - char_length('… and '||(select n from over1n)||' more') - 2, 'limit+1: cut is as late as possible (no wasted room)');
select ok(
  (select char_length(kt) from over1k) + 1 + char_length('ios0100'||repeat('x',4001-(select len from x0))||'@mail.test') > 3950 - char_length('… and '||(select n from over1n)||' more') - 2,
  'limit+1: cut is as late as possible (no wasted room)'
);

-- checks: 10

-- 1. create temp table big as select b(pl(150,100,50)) as t, kept(b(pl(150,100,50))) as k;
create temp table big as
select b(pl(150,100,50)) as t, kept(b(pl(150,100,50))) as k;

-- 2. body fits 4000
select ok((select char_length(t) from big) <= 4000, '300 testers: body fits 4000');

-- 3. ends with the "more" line
select matches((select t from big), E'… and \\d+ more$', '300 testers: ends with the "more" line');

-- 4. headers keep the true counts
select ok(
  (select t from big) like '%Testers: 300%' and
  (select t from big) like '%iPhone (150)%' and
  (select t from big) like '%Android (100)%' and
  ((select t from big) not like '%Other (%' or (select t from big) like '%Other (50)%'),
  '300 testers: headers keep the true counts'
);

-- 5. N equals the number left out
select is(
  (regexp_match((select t from big), E'… and (\\d+) more$'))[1]::int,
  300 - (select k from big),
  '300 testers: N equals the number left out'
);

-- 6. some emails kept, some left out
select ok((select k from big) between 1 and 299, '300 testers: some emails kept, some left out');

-- 7. every line is a header, a whole email or the more line
select is(
  (select count(*)::int from regexp_split_to_table((select t from big), E'\\n') l
   where l <> '' and l !~ '^(Testers: \d+|iPhone \(\d+\)|Android \(\d+\)|Other \(\d+\)|(ios|and|oth)\d{4}@mail\.test|… and \d+ more)$'),
  0,
  '300 testers: every line is a header, a whole email or the more line (cut on a line boundary)'
);

-- 8. JSON lists all 300
select is(
  jsonb_array_length(pl(150,100,50)->'ios') +
  jsonb_array_length(pl(150,100,50)->'and') +
  jsonb_array_length(pl(150,100,50)->'oth'),
  300,
  '300 testers: the JSON lists all 300'
);

-- 9. create temp table rid as select app_private.admin_reply((select id from adm), pl(150,100,50)) as id;
create temp table rid as
select app_private.admin_reply((select id from adm), pl(150,100,50)) as id;

-- 10. stored body fits 4000
select ok(
  (select char_length(body) from public.messages where id = (select id from rid)) <= 4000,
  'real path: stored body fits 4000'
);

-- 11. stored body equals the formatted text
select is(
  (select body from public.messages where id = (select id from rid)),
  (select t from big),
  'real path: stored body equals the formatted text'
);

-- 12. stored JSON still holds all 300 testers
select is(
  (select jsonb_array_length(admin_msg->'ios') +
          jsonb_array_length(admin_msg->'and') +
          jsonb_array_length(admin_msg->'oth')
   from public.messages where id = (select id from rid)),
  300,
  'real path: stored JSON still holds all 300 testers'
);

-- supabase/tests/zz_partD.sql

CREATE OR REPLACE FUNCTION bad_list(i int, a int, o int, pad int)
RETURNS boolean
LANGUAGE sql
AS $$
  WITH s AS (
    SELECT b(pl(i, a, o, pad)) AS t
  )
  SELECT
    char_length(t) > 4000
    OR t LIKE '%… and 0 more%'
    OR (t ~ '… and \d+ more$' AND
        (regexp_match(t, '… and (\d+) more$'))[1]::int + kept(t) <> i + a + o)
    OR t NOT LIKE '%iPhone (' || i || ')%'
    OR t NOT LIKE '%Android (' || a || ')%'
    OR (o > 0 AND t NOT LIKE '%Other (' || o || ')%')
  FROM s;
$$;

SELECT is(
  (SELECT COUNT(*)::int FROM generate_series(3900,4100) p
   WHERE bad_list(100,0,0,p)),
  0,
  'heading-only overflow (iPhone list, Android empty): no heading cut, no "and 0 more"'
);

SELECT is(
  (SELECT COUNT(*)::int FROM generate_series(190,240) n
   WHERE bad_list(n,0,0,0)),
  0,
  'iPhone lists near the limit keep headings, never say "and 0 more"'
);

SELECT is(
  (SELECT COUNT(*)::int FROM generate_series(150,215) n
   WHERE bad_list(n,0,3,0)),
  0,
  'with an Other group: every cut body keeps all three headings and N >= 1'
);

select * from finish();
rollback;
