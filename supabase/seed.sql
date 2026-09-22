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
  ('kim@integration.test')
on conflict do nothing;
