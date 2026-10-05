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
--   gia/hol/ike/jun/kai/lux test/integration/group_membership_integration_test.dart
--     (gia runs the groups; hol leaves or is removed; ike and jun are the
--      two admins of the concurrency races; kai is added without history;
--      lux is allowlisted and active but reachable by nobody there)
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
--   sofi/tarik/umut test/integration/message_search_repository_test.dart
--     (sofi and tarik search their shared history; umut is allowlisted and
--      active but never in their conversations, so only membership can keep
--      their messages out of his search -- and his own second sign-in is
--      the replaced session that app access must refuse)
--   vedat/yesim    test/integration/message_search_seam_test.dart
--     (vedat's search controllers, wired the way main.dart wires them, search
--      what he and yesim wrote)
--   avi/bea/cem    test/integration/avatar_repository_test.dart
--     (avi and bea set, read, replace and remove pictures; cem is allowlisted
--      and active but in none of their groups, so only membership can keep a
--      group's picture from him)
--   deniz/ece      test/integration/avatar_seam_test.dart
--     (deniz's controllers, wired the way main.dart wires them, set his own
--      and his group's picture; ece is the other member)
--   bram/dora/eli/finn test/integration/fast_start_seam_test.dart
--     (bram's chat list read in two stages and the app opening over a slow
--      connection; dora and eli are in his chats, finn is in none)
--   selin/tuna/ulas/veli/yunus/zehra test/integration/contacts_integration_test.dart
--     (selin finds tuna by exact tag, saves him and chats; tuna shares
--      nothing with anyone until then, so only the find can open the way.
--      ulas and veli each spend one lookup budget in a 200-call burst, so
--      they must be fresh: the suite needs a freshly reset stack, as CI has.
--      yunus plays an older build; zehra hides her picture from selin)
--   pax            test/integration/push_receipts_seam_test.dart
--     (the phone's push receipts are uploaded on start as pax, through the
--      registration path main.dart mounts)
--   whit           test/integration/release_notes_delivery_test.dart
--   wynn           test/integration/release_notes_seam_test.dart
--     (What's new notes: each asks for notes at builds numbered from the
--      clock, so a rerun without a reset still moves forward)
--   ione/ilka/isak test/integration/push_registry_integration_test.dart
--     (ione writes to ilka and isak so the delivery list shows the platform
--      each phone registered; ilka moves from Android to an iPhone, isak's
--      iPhone takes over a token ilka's phone had)
--   mira/nico      test/integration/per_chat_seam_test.dart
--     (mira switches between What's new, a 1:1 and a group with nico; nico
--      writes into the chat she has just left)
--   gwen/hugh/iona test/integration/group_colors_seam_test.dart
--     (gwen's group with hugh and iona: each reads the others' colour slots
--      and names; gwen's 1:1 with hugh carries none)
--   kip/lyle       test/integration/parallel_open_seam_test.dart
--     (kip opens his chat with lyle while lyle writes, edits and deletes
--      around kip's history read and Realtime join)
--   pace/quill/rush test/speed/speed_baseline_test.dart
--     (timing harness, run by hand, never in CI: pace opens, reads and sends
--      in a short chat and a long one with photo previews; quill is the other
--      member and writes into them; rush has no chat. It prints numbers and
--      asserts no behaviour)
--   nami/odo/pim   test/integration/newest_page_integration_test.dart
--     (odo writes a 130-message chat with photos to nami; nami reads its
--      newest page, the batched previews, and pages older history; pim is a
--      stranger to their chat)
--   rho/sig        test/integration/catch_up_seam_test.dart
--     (rho's socket dies as a backgrounded phone's does; sig writes to her
--      meanwhile, and catch-up must bring it in)
--   csa/csb/csc/csd/cse/csz test/integration/cold_start_session_integration_test.dart
--     (each starts from its stored last session and is then revoked one way:
--      allowlist, a second phone, offline, a deleted auth session; csz is
--      the chat partner)
--   sda/sdb        test/integration/scroll_down_integration_test.dart
--     (sdb writes a 160-message chat to sda; sda pages up, jumps to an old
--      message and pages back down to the newest; sdb writes while sda is
--      scrolled up or her Realtime is gone)
--   gate-invited, sis-destek-bot@example.com
--                  test/integration/signup_gate_test.dart
--     (the sign-up hook admits gate-invited and refuses the bot address on
--      its reserved domain although it is allowlisted)
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
  ('ugo@integration.test'),
  ('sofi@integration.test'),
  ('tarik@integration.test'),
  ('umut@integration.test'),
  ('vedat@integration.test'),
  ('yesim@integration.test'),
  ('avi@integration.test'),
  ('bea@integration.test'),
  ('cem@integration.test'),
  ('deniz@integration.test'),
  ('ece@integration.test'),
  ('bram@integration.test'),
  ('dora@integration.test'),
  ('eli@integration.test'),
  ('finn@integration.test'),
  ('selin@integration.test'),
  ('tuna@integration.test'),
  ('ulas@integration.test'),
  ('veli@integration.test'),
  ('yunus@integration.test'),
  ('zehra@integration.test'),
  ('gia@integration.test'),
  ('hol@integration.test'),
  ('ike@integration.test'),
  ('jun@integration.test'),
  ('kai@integration.test'),
  ('lux@integration.test'),
  ('pax@integration.test'),
  ('rho@integration.test'),
  ('sig@integration.test'),
  ('whit@integration.test'),
  ('wynn@integration.test'),
  ('ione@integration.test'),
  ('ilka@integration.test'),
  ('isak@integration.test'),
  ('mira@integration.test'),
  ('nico@integration.test'),
  ('gwen@integration.test'),
  ('hugh@integration.test'),
  ('iona@integration.test'),
  ('pace@integration.test'),
  ('quill@integration.test'),
  ('rush@integration.test'),
  ('kip@integration.test'),
  ('lyle@integration.test'),
  ('nami@integration.test'),
  ('odo@integration.test'),
  ('pim@integration.test'),
  ('csa@integration.test'),
  ('csb@integration.test'),
  ('csc@integration.test'),
  ('csd@integration.test'),
  ('cse@integration.test'),
  ('csz@integration.test'),
  ('sda@integration.test'),
  ('sdb@integration.test'),
  ('gate-invited@integration.test'),
  ('sis-destek-bot@example.com')
on conflict do nothing;
