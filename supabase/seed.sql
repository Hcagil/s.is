-- Local-only development data. Runs on `supabase db reset`, never on
-- `db push`, so none of this reaches the hosted project.

-- Fixtures for test/integration/chat_repository_test.dart. The integration
-- test signs these accounts in with a password, which only works locally:
-- the hosted project has Google as its single provider.
insert into app_private.allowlist(email) values
  ('ann@integration.test'),
  ('bob@integration.test')
on conflict do nothing;
