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
  ('quinn@integration.test')
on conflict do nothing;
