# Architecture

The rules the code is held to. Source of truth: [DESIGN.md §3](DESIGN.md).

Pattern: **layered feature modules with Riverpod** for state and dependency
injection. Chosen over BLoC (double the boilerplate for this size) and over
hand-wired `ChangeNotifier`s (no enforceable boundaries).

```
lib/
  main.dart               bootstrap only: config → ProviderScope → App
  app/                    MaterialApp, theme, top-level routing
  core/                   RuntimeConfig, Failure types, Result — no widgets, no SDKs
  features/<feature>/
    domain/               immutable models + repository interfaces (pure Dart)
    data/                 repository implementations — the ONLY layer importing
                          an SDK. tool/check_pattern.sh holds the list and is
                          the authority: supabase_flutter, supabase,
                          google_sign_in, in_app_update, package_info_plus,
                          flutter_secure_storage, url_launcher, image_picker
    application/          Riverpod Notifiers: state machines; import domain only
    presentation/         widgets: watch state, call notifiers, render
```

Features in v0.1: `auth`, `update`, `home`. v0.2 adds `chat`; v0.3 adds groups
inside `chat`.

### Layer rules (mechanically checked)

1. `presentation/` never imports `supabase_flutter`, `google_sign_in`,
   `in_app_update`, or any `data/` file.
2. `application/` imports only `domain/` and `core/` (plus `riverpod`); no
   Flutter widgets, no SDKs.
3. Only `data/` imports SDKs. Every repository implements a `domain/`
   interface so controllers are tested with fakes.
4. Every Notifier has a unit test. Every RLS policy has a pgTAP test. Every
   repository that **queries our own database** has an integration test against
   a real local Supabase — such a repository is query shaping over an SDK, and
   a fake cannot check it: a wrong column name or a renamed RPC parameter
   passes every unit test and fails on a device.

   Repositories that wrap a *third party* — Google sign-in, the Play update
   API, the platform photo picker, the OS keystore — have no integration test,
   because there is nothing to run them against locally. `SupabaseChatRepository`
   is covered; `SupabaseAuthRepository`, `PlayUpdateRepository`,
   `ImagePickerAttachmentSource` and `SecureSessionStorage` are not, and are
   verified on a device instead. Keep those classes thin for that reason: logic
   that could be tested belongs in `domain/`.

`tool/check_pattern.sh` enforces rules 1–3 by import analysis; it runs in CI
and blocks the merge on any violation. Violations are fixed by rewriting the
offending code to the pattern, not by exempting it.

### Errors

Repositories return `Result<T>` with typed `Failure`s
(`network`, `denied`, `provider(reason)`), never raw exceptions. An
incomplete runtime configuration is not one of them: it is a screen state
(`SetupRequired`), reached before any repository exists. Notifiers map failures to explicit screen states. Every failure
state shows its reason on screen; there are no silent returns to a previous
screen.

### Runtime configuration

`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_WEB_CLIENT_ID` are
compile-time `--dart-define`s. They are public by design. An incomplete
configuration renders a "setup required" screen; it never falls back to
mock data.

## Runbook

- Run `tool/check_pattern.sh` before every commit; CI runs it on every pull request and blocks the merge on a violation.
- A violation is fixed by moving the code to the layer it belongs in, never by exempting the file.
- New feature: create `lib/features/<name>/{domain,data,application,presentation}/`; the repository interface goes in `domain/`, its Supabase implementation in `data/`, the Riverpod Notifier in `application/`.
