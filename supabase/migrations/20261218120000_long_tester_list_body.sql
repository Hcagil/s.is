create or replace function app_private.admin_body_list(msg jsonb) returns text
language sql immutable set search_path = '' as $$
  with g(ord, title, key, force) as (
    values (1,'iPhone','ios',true),(2,'Android','and',true),(3,'Other','oth',false)
  ),
  groups_with_arr as (
    select g.ord, g.title, g.force,
      array(select jsonb_array_elements_text(
        case when jsonb_typeof(msg->g.key) = 'array' then msg->g.key else '[]'::jsonb end)) as arr
    from g
  ),
  filtered_groups as (
    select * from groups_with_arr where force or cardinality(arr) > 0
  ),
  pieces as (
    select fg.ord, 0 as email_pos, false as is_email,
      (E'\n\n' || fg.title || ' (' || cardinality(fg.arr) || ')') as piece
    from filtered_groups fg
    union all
    select fg.ord, t.email_pos, true, E'\n' || t.email_val
    from filtered_groups fg,
    lateral unnest(fg.arr) with ordinality as t(email_val, email_pos)
  ),
  ordered_pieces as (
    select p.*, char_length(p.piece) as piece_len,
      sum(char_length(p.piece)) over (order by p.ord, p.email_pos) as running_len
    from pieces p
  ),
  head as (
    select 'Testers: ' || coalesce(msg->>'n','0') as h
  ),
  threshold_check as (
    select (char_length(h.h) + (select sum(piece_len) from ordered_pieces)) <= 4000 as fits
    from head h
  ),
  kept_pieces as (
    select op.* from ordered_pieces op cross join threshold_check tc
    where tc.fits or op.running_len <= 3950
  ),
  footer_data as (
    select (select count(*) from pieces where is_email)
         - (select count(*) from kept_pieces where is_email) as dropped
  )
  select h.h ||
    case when tc.fits
      then string_agg(kp.piece, '' order by kp.ord, kp.email_pos)
      else string_agg(kp.piece, '' order by kp.ord, kp.email_pos) ||
        E'\n… and ' || fd.dropped || ' more'
    end
  from head h
  cross join threshold_check tc
  cross join footer_data fd
  left join kept_pieces kp on true
  group by h.h, tc.fits, fd.dropped
$$;
revoke all on function app_private.admin_body_list(jsonb) from public, anon, authenticated;
