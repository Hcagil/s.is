# Decisions

Dated record of design and product decisions. Newest last. Each entry states
the decision and the reason; superseded entries are marked, never deleted.

## 2026-09-21 — Project restart

**Reset the application code, tests, documentation and database schema; keep
the cloud assets.** Kept: Play app `com.esd.sis` (a package name cannot be
re-registered), Play App Signing and the upload key, the Supabase project and
its Google provider, the GitHub repository, the Docker toolchain images.
Reason: a clean, teachable codebase without losing assets that are expensive
or impossible to recreate.

**Single Google account for all cloud services.** Play Console, Google Cloud,
Supabase and GitHub all belong to the maintainer's existing account. Reason:
simplicity; no organisation registration.

**Users are a private, allowlisted group.** Only Google accounts on the
allowlist can sign in. Reason: smallest secure design; no moderation surface;
matches Play testing tracks.

**Sign-in is Google native only.** Reason: no password or email infrastructure;
the Supabase Google provider and Web client ID already exist. Email OTP was
rejected because Supabase's built-in mailer is rate-limited and production
use would require a separate SMTP provider.

**Pipeline-first delivery.** v0.1 ships the full automated path (merge → CI →
signed AAB → Play internal track → in-app update check) before any chat
feature. Reason: the ability to update phones remotely is a prerequisite for
everything after it.

**Updates are never forced** except below a server-side minimum supported
build, raised only by a recorded decision. In-app updates use Play's flexible
mode. Reason: minimise update prompts for users. The server stores only the
minimum supported build; the latest available build is not stored because
Google Play already reports it to the app.

**Architecture pattern: layered feature modules with Riverpod**, enforced by a
mechanical import check in CI; violations are rewritten, not exempted.
Reason: enforceable boundaries and testability; BLoC rejected for boilerplate,
hand-wired notifiers rejected for lack of boundaries.

**Platforms: Android first, then iOS.** Flutter code is cross-platform from
v0.1; the iOS pipeline (hosted macOS runner → TestFlight) is added after the
Android pipeline is proven.

**Repository content.** The repository holds code, tests, migrations and
engineering documentation only. Local maintainer notes are kept outside
version control (`.orchestra/`, `.private/`).

**Branching: trunk-based with `type/description` topic branches and
Conventional Commit squash titles.** Reason: one releasable trunk suits
continuous delivery to the internal track; typed names and commit titles make
history self-documenting and let release notes be generated. Git-flow style
`develop`/`release` branches were rejected as unnecessary ceremony for a small
team shipping every merge.

## 2026-09-21 — `main` is protected

**Branch protection is enabled on `main`**: the three CI contexts must pass,
branches must be up to date before merging, history stays linear, and force
pushes and deletions are refused. Reason: `main` publishes to Google Play on
every push, so the pull-request gate has to be enforced by the platform rather
than by convention — the first release merged while checks were still running,
which is exactly the gap this closes. Administrators are deliberately not
included, so the owner can still land an emergency fix.

## 2026-09-21 — Android OAuth clients are registered from the downloaded certificate

**The signing fingerprints used to register Android OAuth clients are taken
from the certificate archive downloaded from Play Console, hashed locally —
never read off the console page.** The App signing page renders SHA-1 and
SHA-256 side by side, and the first twenty bytes of a SHA-256 are
indistinguishable from a SHA-1 by shape, which produced two wrong
registrations and a sign-in failure (`[16] Account reauth failed`) before the
real deployment certificate (`deployment_cert.der`) was identified. Play App
Signing also ships hybrid classical and post-quantum certificates whose
fingerprints are *not* the app's signing identity.

## 2026-09-22 — Chat schema: membership is server-authored

**Conversations and membership have no client write policy.** The only way a
conversation comes into existence is the `public.start_direct_conversation()`
RPC, which writes both membership rows itself and refuses any counterpart that
is not a confirmed, allowlisted user. Reason: a client that could insert its
own `conversation_members` row could add itself to any conversation, so the
read policies would be guarding a door with the hinges exposed.

**A 1:1 pair is unique by construction.** `conversations.direct_key` holds the
two user ids in sorted order under a unique index, and the RPC inserts with
`on conflict do nothing`. Reason: two devices opening the same chat at the same
moment must converge on one conversation rather than forking the history; a
lookup-then-insert would race. v0.3 group conversations carry a null
`direct_key`, which the unique index ignores.

**Chat access is `has_app_access()` AND membership, on every policy.** Reason:
one gate, uniformly applied — losing the active session revokes chat at the
same instant it revokes everything else, and Realtime re-checks the same select
policy per subscriber rather than becoming a second, weaker authority.

**Messages cannot be edited or deleted in v0.2.** No update or delete policy
exists, and the grants are `select` and `insert` only. Reason: editing is not
in scope for the first stable version, and an absent policy is a stronger
guarantee than a permissive one nobody calls yet.

**The insert grant on `messages` is column-level.** Only `conversation_id`,
`sender_id` and `body` are grantable; `id` and `created_at` are left to their
defaults. *(Amended 2026-09-22: `attachment_path` was added to the grantable
columns when attachments shipped. `id` and `created_at` remain server-assigned,
which is the point of the decision.)* Reason: a table-wide grant lets a member choose `created_at`, and
because the history is ordered by it and messages can never be edited or
deleted, a back-dated row would pin itself to the top of the other party's
conversation permanently. RLS constrains which rows you may write, not which
columns — so the column list is the part that closes this.

**Realtime publishes inserts only.** `supabase_realtime` is set to
`publish = 'insert'` rather than the default insert/update/delete/truncate.
Reason: `realtime.apply_rls` evaluates row-level security for INSERT and
UPDATE but delivers DELETE to every subscriber of the table without consulting
RLS at all. Messages are insert-only, so the only deletes are cascades from
account or conversation removal — but those would still fan row ids out to
people who cannot read the conversation. Publishing inserts only closes the
path instead of recording it as an accepted exception. This is the one place
where Realtime would otherwise have been a weaker authority than RLS.

## 2026-09-22 — Riverpod's automatic retry is off for chat providers

**`conversationListProvider` and `messagesProvider` pass `retry` a function
that always returns null, disabling Riverpod 3's automatic retry of a failed
build.** Reason: with retry enabled, a provider whose build fails does not
settle on `AsyncError`. It stays `isLoading: true, hasError: true` while it
retries, so the screen shows a spinner forever and never the reason — which
`docs/ARCHITECTURE.md` explicitly forbids ("every failure state shows its
reason on screen; there are no silent returns"). An endless spinner is a
silent failure wearing a different hat.

It is also wrong on the merits for this app's most likely failure: a
`DeniedFailure` is the database refusing under RLS, and no number of retries
turns a refusal into data.

Recovery is explicit instead — `refresh()` on the list, and reopening a
conversation for messages. The controller tests assert `isLoading` is false on
a failed load, so a future change that re-enables retry fails the suite rather
than shipping a spinner.

This did not affect v0.1: `SessionController.build` maps every failure to a
`SessionState` and never throws, so no provider there was ever retried.

## 2026-09-22 — Repositories are covered by integration tests, not mocks

**`data/` repositories are tested against a real local Supabase stack
(`test/integration/`, tagged `integration` and skipped by the ordinary test
run), not against a mocked SDK.** Reason: a repository is almost entirely
query shaping — column names, RPC parameter names, row casts. A mock asserts
that the code calls the SDK the way it was written, which passes just as
happily when the query is wrong. The failure it is meant to catch would
otherwise appear only on a device.

The test signs in with a password, which exists only locally — the hosted
project has Google as its single provider — against allowlist rows seeded by
`supabase/seed.sql`, which runs on `db reset` and never on `db push`.

It earned its place immediately: it caught that Realtime delivers nothing that
happened before a subscription is established, so the original `incoming()`,
which returned as soon as `subscribe()` was called, had a window where a
message was missed by both the subscription and the initial read. `incoming()`
now returns a future that completes only once the server confirms the join,
and the controller awaits it before reading. No unit test could have found
that, because the fake was always ready.

The `database` CI filter was widened to `lib/features/**/data/**` and
`test/integration/**` so a Dart-only change to a repository still runs the job
that owns these tests.

## 2026-09-22 — Profiles are visible only for allowlisted accounts

**`profiles_read` now requires the profile's own account to be allowlisted, not
just the reader to have app access.** Reason: anyone who completes Google
sign-in gets an `auth.users` row and the signup trigger creates a profile,
even though the allowlist then denies them everything else. A production
database therefore accumulates profiles for people who are not members. Seven
appeared on 2026-09-21 from Google Play's automated pre-launch testing of the
internal-track build.

That was harmless until v0.2: the member picker reads `profiles` to offer
someone to chat with, so those names would have been listed to real members.
The same policy also let any active member enumerate every account that had
ever signed in.

`app_private.is_allowed(uuid)` answers the allowlist question for an arbitrary
row; `is_allowed_user()` becomes a thin wrapper over it for the caller, so the
sign-in gate is unchanged.

Note what this does **not** change: the allowlist was always the real gate and
it held throughout — none of those accounts ever had data access. The consent
screen did not gate anything. Android native sign-in requesting only
`openid email profile` does not go through it, which is why arbitrary Google
accounts could authenticate while the OAuth consent screen was in Testing with
zero test users. Do not rely on consent-screen publishing status as an access
control.

## 2026-09-22 — Groups, attachments and push: the decisions behind them

Recorded after the fact; three merges shipped without an entry, which this
corrects.

**A conversation is a group when it has a title.** A 1:1 keeps its unique
`direct_key` and a null title; a group has a null `direct_key`, which the
unique index ignores. Reason: one table, one membership model, and the same
people may hold several differently named groups without colliding with their
1:1. Nothing about an existing 1:1 changed, so builds from v0.2 kept working.

**`start_group_conversation` fails the whole call if any invitee is not a
member.** Reason: the alternative is silently creating a smaller group than
was asked for, which nobody notices until someone wonders why they never saw a
conversation. A refusal is visible; a missing person is not.

**Display names are editable through a column-level grant, not an RPC.** Only
`display_name` is grantable and the policy pins the row to `auth.uid()`.
Reason: the same shape as the `messages` insert grant — the column list, not
the policy, is what stops another column being rewritten.

**An attachment's storage key begins with its conversation id.** The storage
policies read that first segment back and ask the same membership question the
table policies ask. Reason: a separate storage rule would be a second access
control system that drifts out of step with the first, and the drift is only
discovered when they disagree.

**The upload happens before the message insert.** Reason: the pair cannot be
atomic. Failing this way leaves an orphaned object that nothing references and
nobody sees; the other order leaves a message pointing at an object that was
never stored, which is visible and broken.

**`messages_body_check` now requires text OR an attachment.** Reason: an image
needs no caption. A wholly empty message is still refused.

**One push token per member, replaced on registration.** Reason: the
single-active-device rule, extended to notifications — a replaced phone must
stop being notified at the moment it stops being able to read what it would be
notified about. Registration also drops the same token held by anyone else,
because a token identifies a handset rather than a person.

**`forget_device_token` does not require `has_app_access()`.** Reason: a member
whose device was just replaced has already lost access, and must still be able
to silence that device. Gating it would strand notifications on a phone that
can no longer open them.

**Anything that decides access must re-check `auth.sessions`.**
`app_private.active_sessions` cascades from `auth.users`, not from
`auth.sessions`, so a row there outlives the session it names. The push target
list trusted it alone and would have handed a revoked phone the message body
for a conversation it can no longer read. `has_app_access()` had this right
from v0.1; the defect was a new path not reusing it. New code paths re-derive
the gate, never approximate it.

## 2026-09-23 — Member tags and a first-run name screen

**Every member has a unique tag, generated at sign-up and editable.** Display
names are not unique, so two members called the same thing could not be told
apart in a picker. The tag is derived from the name (lower-case, Turkish and
Latin diacritics folded, `Hayrullah Çağıl` → `hayrullah_cagil`) so nobody is
ever without one, and the member may change it on the first-run screen or in
Settings. Format `^[a-z][a-z0-9_]{2,19}$`, enforced by a check constraint and a
unique index.

**The sign-up trigger still never aborts a sign-up.** Generating a unique value
inside it is exactly the kind of change that could: two same-name sign-ups at
once, or a generator bug producing an out-of-format tag. Both a
`unique_violation` and a `check_violation` fall back to a tag built from the
user id, which is unique because the id is. Tests caught the generator bug this
guards against — a 20-character name starting with a digit became 21
characters once prefixed — before it could fail a production migration.

**Availability is checked with definer rights, and is advisory.** The unique
index counts every account, including allowlist-denied ones whose profiles RLS
hides, so an RLS-scoped lookup would call a taken tag free. The index remains
the authority: a tag claimed between the check and the save is refused there,
with a reason.

**The first-run screen shows once, including to existing members.** Tags are
new, and there is no other prompt to see or choose one. Skipping keeps the
Google name and the generated tag.

**Renaming moved from the chat feature to a profile feature.** One owner of
profile writes; two paths to the same column would drift.
