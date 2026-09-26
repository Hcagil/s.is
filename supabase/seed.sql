-- Local-only development data. Runs on `supabase db reset`, never on
-- `db push`, so none of this reaches the hosted project.

-- Fixtures for the integration tests, which sign these accounts in with a
-- password — that only works locally: the hosted project has Google as its
-- single provider.
--
-- One pair per test suite. Signing in again creates a newer session and
-- claims the active device, so two suites sharing a pair would knock each
-- other out whenever `flutter test` runs them in parallel.
--   ann/bob         test/integration/chat_repository_test.dart
--   carol/dan       test/integration/chat_controllers_integration_test.dart
--   erin/frank/grace test/integration/device_change_test.dart
--     (that suite signs erin in twice on purpose -- it is the device change --
--      and needs two counterparties to prove history spans every conversation)
--   hank/ivy/jack/kim test/integration/group_chat_integration_test.dart
--     (three of them form the group; kim is allowlisted and active but is
--      never invited, so she tests the membership half of the policies
--      rather than the app-access half a stranger would fail first)
--   olive/pete/quinn test/integration/chat_preview_and_paging_test.dart
--     (olive talks to pete and to quinn: the pete thread carries the previews,
--      the quinn thread is started and never written to, so a conversation
--      with no messages at all is a real row rather than an assumption)
--   liam/mia/noah   test/integration/attachment_integration_test.dart
--     (liam and mia exchange the image; noah is allowlisted and active but
--      not a member, so the storage policies can only stop him on the
--      conversation in the object key -- an outsider would fail
--      has_app_access() first and prove nothing about that clause)
--   rose/sam/tess   test/integration/live_list_integration_test.dart
--     (rose's list is kept live while sam writes; tess is allowlisted and
--      active and talks to sam, but is never in a conversation with rose, so
--      only row-level security can keep rose's messages from her stream)
--   yara/zane/abby test/integration/presence_integration_test.dart
--     (yara watches zane come online and type; abby is allowlisted and active
--      but never in their conversation, so the typing channel can only refuse
--      her on membership -- has_app_access() alone would let her through)
--   una/otto/pia   test/integration/unread_integration_test.dart
--     (una and otto count each other's messages; pia is allowlisted and
--      active but never in their conversations, so mark_read can only refuse
--      her on membership -- has_app_access() alone would let her through)
--   cleo           test/integration/realtime_channels_test.dart
--     (joins and leaves presence:members through lib/data/realtime_channels.dart)
--   lars/mona      test/integration/last_seen_integration_test.dart
--     (lars is seen, mona looks; the stranger in that suite is deliberately
--      NOT listed here, so only the allowlist can refuse him)
--   jude/kara/lena test/integration/account_switch_integration_test.dart
--     (jude signs out and kara signs in on the SAME client, as one phone
--      does; lena is in a conversation with each of them, so each has a
--      list the other must never be shown)
--   fern/gus/hugo/ines test/integration/profile_pages_integration_test.dart
--     (fern, gus and hugo share groups and a 1:1; ines is allowlisted and
--      active but in none of them, so only membership can hide their rows)
--   iris           test/integration/push_registry_integration_test.dart
--     (registers and forgets a device token; the refused path uses a plain
--      anon client, which needs no seeded account of its own)
--   walt/xena      test/integration/message_screen_seam_test.dart
--     (walt sends a photo with a preview; xena's screen, wired the way
--      main.dart wires it, is what shows it)
--   opal/russ      test/integration/message_delete_seam_test.dart
--     (opal deletes her own messages through the real long-press -> sheet ->
--      confirm flow; russ's screen, mounted at once and wired the way
--      main.dart wires it, is what must show the result arrive live)
--   reid/beth/cora test/integration/reply_forward_repository_test.dart,
--                  test/integration/reply_forward_seam_test.dart
--     (reid replies to and forwards messages between reid+beth, reid+cora,
--      and a group of all three; beth and cora prove a forwarded photo is
--      readable only in the conversation it was forwarded into)
--   priya/quinlan/remy test/integration/read_status_repository_test.dart
--     (priya and quinlan share read status; remy does not, so sharing --
--      not just membership -- decides what each sees of the others; a
--      stranger-reads account signs up there and is never allowlisted)
--   sana/theo/wren test/integration/read_status_seam_test.dart
--     (sana's controller and screens see theo and wren read her messages,
--      live; each test sets their sharing choices itself)
--   nell/oren      test/integration/push_display_integration_test.dart
--     (oren's phone registers as a 0.11 build, then as this build on its
--      next start; nell writes to him so the delivery list shows which)
--   edie/fitz/gale test/integration/edit_message_repository_test.dart
--     (edie edits her own messages to fitz; gale is allowlisted and active but
--      never in their conversation, so only row-level security can keep the
--      edit's UPDATE off her list-wide subscription)
--   hale/ivo       test/integration/message_edit_seam_test.dart
--     (hale edits through the real long-press -> Edit -> composer flow; ivo's
--      open chat and conversation list, wired as main.dart wires them, must
--      show it live)
--   tove/ugo       test/integration/quick_retry_integration_test.dart
--     (tove reads everything a repository reads, through a connection
--      that fails once, twice, or is not there at all; ugo is the other
--      member of her conversation)
insert into app_private.allowlist(email) values
  ('ann@integration.test'),
  ('bob@integration.test'),
  ('carol@integration.test'),
  ('dan@integration.test'),
  ('erin@integration.test'),
  ('frank@integration.test'),
  ('grace@integration.test'),
  ('hank@integration.test'),
  ('ivy@integration.test'),
  ('jack@integration.test'),
  ('kim@integration.test'),
  ('liam@integration.test'),
  ('mia@integration.test'),
  ('noah@integration.test'),
  ('olive@integration.test'),
  ('pete@integration.test'),
  ('quinn@integration.test'),
  ('rose@integration.test'),
  ('sam@integration.test'),
  ('tess@integration.test'),
  ('vera@integration.test'),
  ('walt@integration.test'),
  ('xena@integration.test'),
  ('yara@integration.test'),
  ('zane@integration.test'),
  ('abby@integration.test'),
  ('cleo@integration.test'),
  ('una@integration.test'),
  ('otto@integration.test'),
  ('pia@integration.test'),
  ('lars@integration.test'),
  ('mona@integration.test'),
  ('jude@integration.test'),
  ('kara@integration.test'),
  ('lena@integration.test'),
  ('fern@integration.test'),
  ('gus@integration.test'),
  ('hugo@integration.test'),
  ('ines@integration.test'),
  ('iris@integration.test'),
  ('opal@integration.test'),
  ('russ@integration.test'),
  ('reid@integration.test'),
  ('beth@integration.test'),
  ('cora@integration.test'),
  ('priya@integration.test'),
  ('quinlan@integration.test'),
  ('remy@integration.test'),
  ('sana@integration.test'),
  ('theo@integration.test'),
  ('wren@integration.test'),
  ('nell@integration.test'),
  ('oren@integration.test'),
  ('edie@integration.test'),
  ('fitz@integration.test'),
  ('gale@integration.test'),
  ('hale@integration.test'),
  ('ivo@integration.test'),
  ('tove@integration.test'),
  ('ugo@integration.test')
on conflict do nothing;
