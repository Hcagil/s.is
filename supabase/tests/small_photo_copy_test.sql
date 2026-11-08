begin;
select plan(66);

-- The small photo copy '<path>.s' (and the '.t' notification/video thumb),
-- written from the contract, not the migration:
--   A member reads '<p>.s' / '<p>.t' only when the storage object's owner is the
--   message's sender and the member may read that message. '.s' only for a photo
--   (no attachment_name, no duration); '.t' for a photo or a video with a
--   duration, never for a file. A copy with no message, or with no owner, is
--   nobody's but its owner's. push_targets_for_message gives thumb_path '<p>.t'
--   only when the sender owns '<p>.t'. Removal (may_remove, delete_message,
--   sweeper_claim) treats '<p>.s' as part of '<p>'.
-- Each negative fixture fails ONE gate:
--   s1    B's photo, copies uploaded by A          (owner = sender only)
--   nul   B's photo, copies with no owner          (owner = sender only)
--   var   B deleted, A re-sent the same path       (owner = sender only)
--   vid   B's video with copies by B               (.s: duration only; .t readable)
--   pdf   B's file with copies by B                (attachment_name only)
--   orph  B's .s with no message                   (message exists only)
--   late  B's photo after lea left G               (message_readable only)
--   dan   never a member of G                      (membership only)
--   ann 01 bob 02 cat 03 dan 04 lea 05 sen 06 (preview sender) non 07 (preview none)

-- fixtures -------------------------------------------------------------------
create function u(n text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000f5c' || n)::uuid
$$;
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select u(n), name || '+smallcopy@mail.test', now(), json_build_object('full_name', initcap(name))::jsonb
  from (values ('01','ann'),('02','bob'),('03','cat'),('04','dan'),('05','lea'),('06','sen'),('07','non')) v(n, name);
insert into app_private.allowlist(email)
select name || '+smallcopy@mail.test' from unnest(array['ann','bob','cat','dan','lea','sen','non']) name;
insert into auth.sessions (id, user_id, created_at, updated_at)
select ('f5c00000-0000-0000-0000-0000000000' || n)::uuid, u(n), now(), now()
  from unnest(array['01','02','03','04','05','06','07']) n;
insert into app_private.tag_finds(finder, found_id)
select u('01'), u(n) from unnest(array['02','03','04','05','06','07']) n;

create function as_(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', u(n), 'role', 'authenticated',
      'email', (select email from auth.users where id = u(n)),
      'session_id', 'f5c00000-0000-0000-0000-0000000000' || n)::text, true);
  execute 'set local role authenticated';
end $$;
create function commit_check() returns void language plpgsql as $$
begin set constraints all immediate; set constraints all deferred; end $$;
create function try(q text) returns text language plpgsql as $$
begin execute q; perform commit_check(); return 'ok';
exception when others then return sqlstate || ' ' || sqlerrm; end $$;
grant execute on function u(text), as_(text), commit_check(), try(text) to authenticated, anon;

create temp table ids(name text primary key, id uuid);
grant select, insert on ids to authenticated, anon, service_role;
create function g(name text) returns uuid language sql stable as $$
  select id from ids where ids.name = g.name
$$;
grant execute on function g(text) to authenticated, anon, service_role;

-- the original of message [k]; 'fwd' lives in G2, the rest in G
create function p(k text) returns text language sql stable as $$
  select g(case k when 'fwd' then 'G2' else 'G' end) || '/' || g(k) || '/' ||
    case k when 'vid' then 'clip.mp4' when 'pdf' then 'doc.pdf' else 'pic.jpg' end
$$;
grant execute on function p(text) to authenticated, anon, service_role;

-- as the current user: upload one object
create function up(name text) returns text language sql as $$
  select try(format($q$insert into storage.objects(bucket_id, name, owner_id, metadata)
                       values ('attachments', %L, %L, '{"size":3}'::jsonb)$q$, name, auth.uid()))
$$;
-- as the current user: store message [k] at path p(k)
create function msg(k text, id uuid) returns text language sql as $$
  select try(case
    when k in ('vid', 'pdf') then format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                               attachment_name, attachment_mime, attachment_size, attachment_duration_ms)
                   values (%L, %L, %L, '', %L, %L, %L, 1000, %s)$q$,
                id, g('G'), auth.uid(), p(k),
                case k when 'pdf' then 'doc.pdf' else 'clip.mp4' end,
                case k when 'pdf' then 'application/pdf' else 'video/mp4' end,
                case k when 'vid' then '41000' else 'null' end)
    else format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path)
                   values (%L, %L, %L, '', %L)$q$, id, g(case k when 'fwd' then 'G2' else 'G' end), auth.uid(), p(k)) end)
$$;
grant execute on function up(text), msg(text, uuid) to authenticated;

-- the object's real owner, looked up past RLS
create function owner_of(name text) returns text language sql stable security definer set search_path = '' as $$
  select o.owner_id from storage.objects o where o.bucket_id = 'attachments' and o.name = owner_of.name
$$;
-- authenticated has no USAGE on app_private: call its functions as the current
-- user's claims (auth.uid() reads the JWT claims), past the schema gate
create function rd(name text) returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.attachment_readable(name, public.owner_of(name))
$$;
create function mr(name text) returns boolean language sql stable security definer set search_path = '' as $$
  select app_private.may_remove_attachment(name)
$$;
-- as the current user: '<attachment_readable>/<rows seen through RLS>'
create function can(name text) returns text language sql stable as $$
  -- 'not readable' = not true: RLS denies on false and on null alike
  select coalesce(rd(name), false)::text || '/' ||
         (select count(*) from storage.objects o where o.bucket_id = 'attachments' and o.name = can.name)
$$;
grant execute on function owner_of(text), rd(text), mr(text), can(text) to authenticated;

-- what recipient [n] is told about message [k]: '<path>|<video>', '<null>' or '<no row>'
create function thumb(k text, n text) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(thumb_path || '|' || thumb_video, '<null>'), ','), '<no row>')
    from app_private.push_targets_for_message(g(k)) where user_id = u(n)
$$;

do $$
declare n text;
begin
  foreach n in array array['01','02','03','04','05','06','07'] loop
    perform as_(n); perform public.activate_session();
    if n in ('03', '06', '07') then
      perform public.register_device_token('smallcopy-token-' || n, 'android', true);
    end if;
    execute 'reset role';
  end loop;
end $$;

insert into ids values
  ('s1',   'f5c00000-0000-0000-0000-00000000a001'),
  ('ok',   'f5c00000-0000-0000-0000-00000000a002'),
  ('vid',  'f5c00000-0000-0000-0000-00000000a003'),
  ('pdf',  'f5c00000-0000-0000-0000-00000000a004'),
  ('orph', 'f5c00000-0000-0000-0000-00000000a005'),
  ('nul',  'f5c00000-0000-0000-0000-00000000a006'),
  ('late', 'f5c00000-0000-0000-0000-00000000a007'),
  ('var',  'f5c00000-0000-0000-0000-00000000a008'),
  ('del',  'f5c00000-0000-0000-0000-00000000a009'),
  ('none', 'f5c00000-0000-0000-0000-00000000a00a'),
  ('fwd',  'f5c00000-0000-0000-0000-00000000a00b'),
  ('var2', 'f5c00000-0000-0000-0000-00000000a00c'),
  ('dur',  'f5c00000-0000-0000-0000-00000000a00d');

select as_('01');
insert into ids values ('G', public.start_group_conversation('Small copies',
  array[u('02'), u('03'), u('05'), u('06'), u('07')]));
insert into ids values ('G2', public.start_group_conversation('Forwarded', array[u('04')]));
select commit_check();
reset role;
select as_('06'); insert into public.notification_settings(preview) values ('sender'); reset role;
select as_('07'); insert into public.notification_settings(preview) values ('none'); reset role;

-- bob sends; each fixture uploads exactly what its case needs
select as_('02');
select is(up(p('s1')) || msg('s1', g('s1')), 'okok', 'fixture s1: bob sends a photo with no copies of his own');
select is(up(p('ok')) || up(p('ok') || '.s') || up(p('ok') || '.t') || msg('ok', g('ok')), 'okokokok',
          'fixture ok: bob sends a photo with his own .s and .t');
select is(up(p('vid')) || up(p('vid') || '.s') || up(p('vid') || '.t') || msg('vid', g('vid')), 'okokokok',
          'fixture vid: bob sends a video with a duration, .s and .t');
select is(up(p('pdf')) || up(p('pdf') || '.s') || up(p('pdf') || '.t') || msg('pdf', g('pdf')), 'okokokok',
          'fixture pdf: bob sends a file, .s and .t');
-- dur: a duration but no attachment_name cannot exist, so the .s duration gate has
-- nothing of its own to stop (mutating it alone is an equivalent mutant)
select is(up(p('dur')) || up(p('dur') || '.s'), 'okok', 'fixture dur: bob uploads a clip and its .s');
select is(left(try(format($q$insert into public.messages(id, conversation_id, sender_id, body, attachment_path,
                                                         attachment_mime, attachment_duration_ms)
                             values (%L, %L, %L, '', %L, 'video/mp4', 41000)$q$, g('dur'), g('G'), auth.uid(), p('dur'))), 5),
          '23514', 'a message with a duration and no attachment_name is refused (messages_duration_check)');
select is(up(p('orph') || '.s'), 'ok', 'fixture orph: bob uploads a .s with no message');
select is(up(p('nul')) || msg('nul', g('nul')), 'okok', 'fixture nul: bob sends a photo');
select is(up(p('none')) || msg('none', g('none')), 'okok', 'fixture none: bob sends a photo with no .t at all');
select is(up(p('del')) || up(p('del') || '.s') || up(p('del') || '.t') || msg('del', g('del')), 'okokokok',
          'fixture del: bob sends a photo he will delete');
select is(up(p('var')) || up(p('var') || '.s') || up(p('var') || '.t') || msg('var', g('var')), 'okokokok',
          'fixture var: bob sends a photo he will delete');
reset role;

-- s1: ann (a member) plants copies of bob's photo
select as_('01');
select is(up(p('s1') || '.s') || up(p('s1') || '.t'), 'okok', 'fixture s1: ann may upload .s/.t under bob''s photo');
reset role;
-- nul: copies with no owner
insert into storage.objects(bucket_id, name, owner_id, metadata)
values ('attachments', p('nul') || '.s', null, '{"size":3}'), ('attachments', p('nul') || '.t', null, '{"size":3}');

-- lea leaves; then bob sends one more
select as_('05'); select public.leave_group(g('G')); select commit_check(); reset role;
select as_('02');
select is(up(p('late')) || up(p('late') || '.s') || up(p('late') || '.t') || msg('late', g('late')), 'okokokok',
          'fixture late: bob sends after lea left');
reset role;
-- one transaction has one now(): place 'late' after lea's left_at
update public.messages set created_at = now() + interval '1 minute' where id = g('late');
select as_('02');
-- var: bob deletes it; the sweeper removes the original only
select is(try(format('select public.delete_message(%L)', g('var'))), 'ok', 'fixture var: bob deletes his photo');
select is(try(format('select public.delete_message(%L)', g('del'))), 'ok', 'fixture del: bob deletes his photo');
reset role;
set local storage.allow_delete_query = 'true';
delete from storage.objects where bucket_id = 'attachments' and name = p('var');
-- ann re-uses the freed path for her own photo
select as_('01');
select is(up(p('var')) || msg('var', g('var2')), 'okok', 'fixture var: ann sends her own photo at the same path');
-- fwd: ann forwards to G2 and makes her own copies there
select is(up(p('fwd')) || up(p('fwd') || '.s') || up(p('fwd') || '.t') || msg('fwd', g('fwd')), 'okokokok',
          'fixture fwd: ann forwards a photo to G2 with her own copies');
reset role;

-- 1 S1: copies planted by another member are nobody else's -----------------------
select as_('03');
select is(can(p('s1') || '.s'), 'false/0', 'S1: cat cannot read ann''s .s of bob''s photo');
select is(can(p('s1') || '.t'), 'false/0', 'S1: cat cannot read ann''s .t of bob''s photo');
reset role;
select as_('02');
select is(can(p('s1') || '.s'), 'false/0', 'S1: nor can bob, the sender');
select is(can(p('s1') || '.t'), 'false/0', 'S1: nor his .t');
reset role;
select as_('01');
select is(can(p('s1') || '.s'), 'true/1', 'S1: ann reads her own upload');
select is(can(p('s1') || '.t'), 'true/1', 'S1: and her own .t');
reset role;

-- 2 the sender's copies --------------------------------------------------------
select as_('01');
select is(can(p('ok') || '.s'), 'true/1', 'ann reads bob''s .s');
select is(can(p('ok') || '.t'), 'true/1', 'ann reads bob''s .t');
reset role;
select as_('03');
select is(can(p('ok') || '.s'), 'true/1', 'cat reads bob''s .s');
select is(can(p('ok') || '.t'), 'true/1', 'cat reads bob''s .t');
reset role;
select as_('04');
select is(can(p('ok') || '.s'), 'false/0', 'dan, never a member, cannot read .s');
select is(can(p('ok') || '.t'), 'false/0', 'nor .t');
reset role;
select as_('05');
select is(can(p('ok') || '.s'), 'true/1', 'lea reads the .s sent while she was a member');
select is(can(p('late') || '.s'), 'false/0', 'lea cannot read the .s sent after she left');
select is(can(p('late') || '.t'), 'false/0', 'nor its .t');
reset role;
do $$ begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); end $$;
set local role anon;
select is((select count(*) from storage.objects where bucket_id = 'attachments'), 0::bigint, 'anon sees no attachment object');
reset role;

-- 3 video, file, no message ----------------------------------------------------
select as_('03');
select is(can(p('vid') || '.t'), 'true/1', 'a video''s .t from its sender is readable');
select is(can(p('vid') || '.s'), 'false/0', 'a video has no readable .s');
select is(can(p('pdf') || '.s'), 'false/0', 'a file has no readable .s');
select is(can(p('pdf') || '.t'), 'false/0', 'a file has no readable .t');
select is(can(p('orph') || '.s'), 'false/0', 'a .s with no message is not readable');
-- 4 variant: bob's old copies do not follow ann's new photo at his old path
select is(can(p('var')), 'true/1', 'var: cat reads ann''s new photo at the path');
select is(can(p('var') || '.s'), 'false/0', 'var: bob''s old .s is not readable through ann''s message');
select is(can(p('var') || '.t'), 'false/0', 'var: nor his old .t');
-- 5 no owner
select is(can(p('nul') || '.s'), 'false/0', 'a .s with no owner is not readable');
select is(can(p('nul') || '.t'), 'false/0', 'a .t with no owner is not readable');
reset role;

-- 6 forward: the forwarder's copies are readable in the new chat ----------------
select as_('04');
select is(can(p('fwd') || '.s'), 'true/1', 'fwd: dan reads ann''s .s in G2');
select is(can(p('fwd') || '.t'), 'true/1', 'fwd: dan reads ann''s .t in G2');
reset role;
select as_('02');
select is(can(p('fwd') || '.s'), 'false/0', 'fwd: bob, not in G2, cannot');
reset role;

-- 7 push_targets_for_message thumb_path ---------------------------------------
select is(thumb('ok', '03'), p('ok') || '.t|false', 'push: the sender''s .t is the picture');
select is(thumb('s1', '03'), '<null>', 'push: a .t uploaded by someone else is never the picture');
select is(thumb('none', '03'), '<null>', 'push: no .t, no picture');
select is(thumb('ok', '06'), '<null>', 'push: preview sender, no picture');
select is(thumb('ok', '07'), '<null>', 'push: preview none, no picture');
select is(thumb('vid', '03'), p('vid') || '.t|true', 'push: a video keeps its .t and is marked video');
select is(pg_get_function_result('app_private.push_targets_for_message(uuid)'::regprocedure),
          'TABLE(user_id uuid, token text, platform text, conversation_id uuid, title text, body text, shows_itself boolean, '
          'sender text, chat text, badge integer, thumb_path text, thumb_video boolean, ciphertext text, olm_type smallint, '
          'sender_key text, sender_id uuid, encrypted boolean)',
          'push: the same 17 columns in the same order');

-- 8 grants ---------------------------------------------------------------------
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'authenticated', '{}'::text[],
                          'authenticated cannot run push_targets_for_message');
select function_privs_are('app_private', 'push_targets_for_message', array['uuid'], 'anon', '{}'::text[], 'nor anon');
select function_privs_are('app_private', 'attachment_readable', array['text', 'text'], 'authenticated', array['EXECUTE'],
                          'authenticated runs attachment_readable');
select function_privs_are('app_private', 'attachment_readable', array['text', 'text'], 'anon', '{}'::text[],
                          'anon cannot run attachment_readable');
select is((select array_agg(p.proname || ':' || p.prosecdef || ':' || coalesce(array_to_string(p.proconfig, ','), '') order by p.proname)
             from pg_proc p where p.oid in ('app_private.push_targets_for_message(uuid)'::regprocedure,
                                            'app_private.attachment_readable(text,text)'::regprocedure)),
          array['attachment_readable:true:search_path=""', 'push_targets_for_message:true:search_path=""'],
          'both are security definer with an empty search_path');

-- 9 removal ----------------------------------------------------------------------
select is((select array_agg(path order by path) from app_private.storage_removal_queue
            where bucket = 'attachments' and path like p('del') || '%'),
          array[p('del'), p('del') || '.s', p('del') || '.t'], 'delete_message queues the photo, its .s and its .t');
select as_('02');
select ok(mr(p('del') || '.s'), 'may_remove: bob, who deleted the photo, may remove its .s');
reset role;
select as_('01');
select ok(not mr(p('del') || '.s'), 'may_remove: ann may not');
reset role;
-- a deletion record for a path a live message still uses (only the live-message gate fails)
insert into app_private.deleted_attachments(path, user_id) values (p('ok'), u('02'));
select as_('02');
select ok(not mr(p('ok') || '.s'), 'may_remove: not while a live message still has the photo');
reset role;

delete from app_private.storage_removal_queue where path like g('G') || '/%';
insert into app_private.storage_removal_queue(bucket, path)
values ('attachments', p('ok') || '.s'), ('attachments', p('orph') || '.s');
set local role service_role;
select is((select array_agg(c.path order by c.path) from public.sweeper_claim(1000) c where c.path like g('G') || '/%'),
          array[p('orph') || '.s'], 'sweeper_claim claims a .s with no live message, not one whose photo is live');
reset role;
select is((select count(*) from app_private.storage_removal_queue where path = p('ok') || '.s'), 0::bigint,
          'sweeper_claim drops the live photo''s .s from the queue');
select function_privs_are('public', 'sweeper_claim', array['integer'], 'authenticated', '{}'::text[], 'sweeper_claim: not authenticated');
select function_privs_are('public', 'sweeper_claim', array['integer'], 'anon', '{}'::text[], 'sweeper_claim: not anon');

select * from finish();
rollback;
