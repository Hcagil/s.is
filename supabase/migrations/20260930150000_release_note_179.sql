-- The 0.27.0 note (build 179) that the release step failed to store.
insert into public.release_notes(build, note)
values (179, 'When SIS updates, a short "What''s new" note now arrives as a message from SIS in your chat list. You can mute it, but not reply to it.')
on conflict (build) do nothing;
