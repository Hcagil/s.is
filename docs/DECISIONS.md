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

## 2026-09-23 — Online status and typing over private, RLS-gated channels

**Presence and typing use private Realtime channels authorised by RLS on
`realtime.messages`.** A public channel would let anyone holding the public
anon key join `typing:<conversation>` or the presence channel. The policies
apply the same rule as every other read: `has_app_access()`, plus membership of
the conversation for typing. Before this, `realtime.messages` had RLS on and no
policies — private channels were deny-all — and only these two topics were
opened.

**The sharing switches are stored on the profile and enforced by the server.**
Stored on the profile so the choice follows the account to a new phone.
Enforced in the send policy, not only in the app, so a modified client cannot
announce someone who chose to stay hidden. Realtime evaluates policies when a
channel is joined, so the app rejoins when a switch flips and also stops
sending at once.

**Known limit: identities inside presence and typing are client-supplied.**
Realtime does not tell a receiver who sent a broadcast, and the presence key is
chosen by the client. A malicious *member* could therefore make another member
appear online or typing. Outsiders cannot — they cannot join the channel at
all. Accepted as cosmetic for a private allowlisted group; the fix, if ever
needed, is server-sent typing (a database function broadcasting on the
member's behalf) rather than client broadcasts.

## 2026-09-23 — One helper joins and leaves every Realtime channel

**`lib/data/realtime_channels.dart` is the only place a channel is joined or
torn down.** The same defect shipped twice: v0.2 chat and v0.4 presence each
awaited a teardown on the failed-join path (`removeChannel` over a dead socket,
`close()` on a stream nobody had listened to), so the path that exists to stop
a screen hanging hung. The fix was recorded as a lesson after the first time
and did not prevent the second. A shared helper makes the correct shape the
convenient one, and `tool/check_pattern.sh` rule 5 fails CI on an awaited
`close()` or `removeChannel` inside a `catch` under any `data/` directory.

Side effects of unifying: chat subscriptions now fail on `channelError` and
`timedOut` statuses immediately instead of waiting out the 15-second timeout,
and cancelling a chat stream no longer waits on the unsubscribe reply.

## 2026-09-23 — The name, the look and the logo

**SIS means "Stay In Sync"**, written "SIS". The owner required an English
meaning; the acronym says what the app does, and the capitals avoid "sis"
being read as slang for "sister". The launcher label is unchanged.

**The design is Nocturne** (DESIGN.md §10), chosen from four clickable
directions: sleek, ink violet, precise; Manrope for the interface, Sora for the
wordmark; your own messages on a gradient; live signals (online, typing) in
the brand violet rather than the conventional green. Corners were rounded up
from 4px after the owner's review. The three-stop "prism" gradient, borrowed
from another direction, is reserved for the logo and wordmark so it stays
special.

**The logo is the Sync S**: an S made of two arrows chasing each other. Six
typeset letterforms (a big S with a small s in front) were rejected before
ten drawn marks were shown; typeset marks depend on a font's licence and
metrics, and none read as ours.

**One painter draws the logo everywhere.** `SisLogoPainter` renders it in the
app and, through `tool/render_icons_test.dart`, the launcher icon layers that
`flutter_launcher_icons` turns into every Android density, the adaptive icon
and the Android 13 themed (monochrome) icon. No SVG dependency, no separate
artwork file to fall out of step.

**Fonts are bundled, not fetched.** A runtime font download would show a
fallback face first and leak a request to Google on every cold start. Manrope
and Sora are OFL; their licences ship with them and appear on the app's
licence page.

## 2026-09-23 — Unread counts, and why last_read_at is private

**A member's place in a conversation is one timestamp,
`conversation_members.last_read_at`.** Unread is everything newer that
someone else sent. Opening a conversation marks it read (owner's choice over
per-message tracking), as does leaving it, and so does a message that
arrives while it is open. Existing memberships were set to the migration's
time, so the feature starts at zero rather than with the whole history unread.

**Nobody can read another member's `last_read_at`.** There are no read
receipts (owner, 2026-09-23), and a readable column would be one by the back
door. `conversation_members` is therefore readable by column (who is in a
conversation, not where they are in it), `mark_read` is the only write and
only to the caller's own row, and counts come from `unread_counts()`, a
security-definer function scoped to the caller. A view was not enough: a
security-invoker view cannot read a column the caller is denied, and a
definer view would drop the row-level checks.

**Group conversations name the sender** above the first message of each run,
in that person's tint. A person's tint is now seeded by their user id
everywhere, so the same person has the same colour in the list, the picker
and a group.

## 2026-09-23 — Last seen is mutual, and stored where no client can read it

**Mutual, as the owner chose:** a member who hides their last seen cannot see
anyone else's. The rule lives in the server: `last_seen_of(person)` answers
only when the caller AND the person share, and gives the same null for every
refusal, so a refusal reveals nothing.

**The time is stored in `app_private.last_seen`,** a table no client role can
read. `touch_last_seen()` writes the caller's own time only while they share;
turning sharing off deletes the stored time (a trigger), so nothing is kept
that the member chose not to share.

**Recorded when the app opens, resumes and goes to the background.** Known
limit: a phone that kills the app without it ever reaching the background
keeps the time it was opened. A heartbeat would fix that at one write a
minute per open app; not worth it yet.

**Last seen and online stay separate switches** (owner, after the audit).
Hiding last seen hides the stored time both ways; it does not stop a member
watching the live "online" dot, which follows the online switch alone. The
stricter reading (hiding last seen also hides and blinds online) was offered
and declined.

**Shown in the 1:1 header** under the name, after "typing…" and "online":
"last seen just now", "N min ago", "today at 14:02", "yesterday at 21:40",
then a date.

## 2026-09-23 — Settings is a set of pages; sign out lives only there

Settings opens on the member's own card (tap to edit name and tag), then one
row per section: **Privacy** (online, typing, last seen), **Account** (the
Google address in use, and Sign out) and **About** (version, build, the
open-source licences, including the bundled fonts). The home header's menu,
whose only other entry was Settings, became a single settings icon; Sign out
moved into Account, where it cannot be tapped by accident from the chat list.
Signing out first returns to the root screen, so no settings page is left
standing above the sign-in screen.

## 2026-09-23 — The release waits for CI on `main`

**`release.yml` runs on CI completing, not on the push, and publishes only
when CI passed on that exact commit.** Administrators stay outside branch
protection (2026-09-21, for emergency fixes), so a merge could land past a red
check and, with the old push trigger, publish in parallel with the CI run
that would have failed. The emergency path is kept; it now has to be green to
ship. Cost: a release starts about ten minutes later.

**CI builds the release bundle, not a debug APK**, signed with a throwaway key
generated in the job. R8 shrinking and the signing configuration only run in
release mode; building debug in CI meant the first release build of any change
happened after merge, in the job that publishes.

**The `play-internal` environment deploys only from protected branches**, and
the repository allows squash merges only. The secrets are reachable from
`main` alone, and every change reaches `main` as one commit — which the
release's docs-only check relies on.

## 2026-09-24 — Per-account state follows the signed-in account

**Switching account must never show the previous account's data.** The owner
switched accounts on one phone and the new-chat picker still listed the
previous account's "everyone else" — the new account itself — until the app
was restarted. The member list and the conversation list were kept alive
across sign-out and nothing told them the account had changed.

The fix is structural, not a restart: `currentUserIdProvider` is the signed-in
member's id, and every provider that holds one account's data (the open
conversation, the conversation list, the member list, the own profile, online
status, and everything built on them) watches it. A change of account
rebuilds them for the new account. A new per-account provider must watch it
too; the account-switch tests fail if one is missed.

## 2026-09-23 — Links open plainly; photos open full-screen

**Web addresses in messages are tappable and open in the browser.** Only
`http`, `https` and `www.` addresses are recognised, and the opener checks the
scheme again, so a message cannot turn into a link to another app or a
custom scheme. Trailing sentence punctuation is not part of a link.

**No link previews** (owner's choice). A preview means fetching the page,
which tells that site when the chat was opened and from where; SIS makes no
request the member did not make.

**Opening a link is a platform capability**, so it sits behind a `LinkOpener`
interface with its `url_launcher` implementation in `data/`, like the photo
picker: `presentation/` never imports a platform SDK.

**A photo opens full-screen**, with pinch-zoom and swiping between the
conversation's photos. Photos load through the same short-lived signed URLs
as the bubbles; thumbnails and an on-device cache come with v0.9.

## 2026-09-23 — Profile pages for people and groups

**A person's page** opens from the title of your 1:1 chat with them or from
a group's member list (the owner chose not to make group sender names a
second entry point). It shows their name, @tag, online or last seen (under
the same server rules as the chat header), and Media and Links from your 1:1
chat only. It never creates a chat just to be looked at: with no 1:1 yet it
says so, and the Message button is what starts one.

**A group's page** opens from the group chat's title: name, member count,
and Members, Media and Links tabs. View only in v0.7; renaming, adding and
leaving need their own rules and come later.

**No new database access.** Members, photos and link messages are read under
the existing row-level security; each read is capped at the newest few
hundred, like the chat history.

**One open conversation at a time, restored on return.** Opening a chat from
another chat's member page (group, member, Message) puts the new chat on top;
leaving it hands the "open conversation" back to the one underneath instead
of clearing it, so the group chat below keeps its live messages.

## 2026-09-24 — Errors are written for the member

**Offline, the app showed the SDK's own words**, such as "ClientException
with SocketException: Failed host lookup". Every repository ended its error
mapping with the raw text of whatever was thrown.

**One mapper decides the words**: `readableFailure()` in
`lib/data/failures.dart`. No connection (socket, TLS, timeout, the HTTP
client's failure, Supabase's retryable auth failure, a refused Realtime
socket, a Realtime join that timed out) says "No connection. Check your internet and try again." An
answer from the server that is an error says "The server could not do
that. Try again." Anything else says "Something went wrong. Try again."
Errors that mean something keep their own words: a refusal is still "Not
allowed", a taken tag still says so, a missing photo is still "not
available".

**The raw error is logged, not shown.** It goes to the device log under
`sis.data`, so nothing is lost for debugging.

**Sign-in keeps its diagnostics.** Google's error code and Supabase's
rejection text stay on the sign-in screen: they are how a signing or client
registration fault was found before. Only an offline sign-in now says "No
connection" instead of blaming the token.

**A pattern rule keeps it that way.** `tool/check_pattern.sh` (rule 6)
fails CI when a feature's `data/` passes error text into a `NetworkFailure`.

## 2026-09-24 — Push notifications: settings, mutes, and a sender nobody can misuse

**Firebase lives in the existing Cloud project** (`sis-app-509303`), with
Google Analytics off: the app does not track its members. The sender uses a
service account that can only send notifications.

**Each member decides what the lock screen shows** (owner's choice):
*Full* (default) is who and what, "Ayşe @ Family: see you at 8"; *Sender
only* is the person alone, "Ayşe: New message", without the group's name,
which can say as much as the text; *No details* is "SIS: New message",
nothing about who or what. The wording is made in the database, per
recipient, so a phone is never sent more than its owner allowed.

**Mutes: 8 hours, 1 week or always**, for a conversation or for a person.
Muting a person silences them in every conversation, groups included:
someone muted in the 1:1 would otherwise still reach you through a shared
group. A global switch turns everything off. Settings and mutes are private
to their member, unlike the sharing switches, which others must read.

**The sender accepts calls without a JWT, and that is safe.** A database
trigger holds no user token, so the function is deployed with
`--no-verify-jwt`. It takes only a message id; `push_targets()` claims that
message once and only while it is under two minutes old. A forged call can
at most send a notification that was due anyway, once.

**Removed from the allowlist means no more notifications**, even while
the old session and device token still exist: the target list checks the
allowlist as `has_app_access()` does. **A broken sender never costs a
message**: the trigger swallows a failed request with a warning. **Every
call gets the same empty answer**, so the sender cannot be used to learn
whether someone muted you.

**No foreground notifications.** While the app is open, the chat list
already shows new messages and unread counts.

## 2026-09-24 — The app's half of push

**This phone registers for whoever is signed in**, and only while someone
is: the token is sent when an account settles and on every token refresh,
and Sign out removes it first, while the session can still reach the
server. If that fails, nothing leaks: the server sends nothing to a device
whose session has ended, and the next sign-in on the phone takes the token
over.

**Permission is asked once, on the home screen**, the first time an
allowed member reaches it (Android 13+). A refusal is respected; the
member can allow notifications later in system settings, and the phone is
already registered.

**Tapping a notification opens its conversation**, reading the chat list
again if the chat is new. An id the list still does not know is ignored.

**Firebase code stays thin and in `data/`** (`FirebasePushSource`),
verified on a device like the photo picker; the server calls
(`SupabasePushRegistry`) have integration tests.

## 2026-09-24 — Photos load once, and yours appear at once

**A photo is downloaded once per phone.** Photos come straight from the
private bucket (`storage.download`, under the same membership policy as a
signed URL) and are kept in the app's cache directory, one file per storage
path. A signed URL changed on every look, so the same photo was fetched
again every time. The cache has no size cap: Android clears the cache
directory when space runs low, and a missing photo is simply downloaded
again. **Sign-out clears it**, so the next account on the phone does not
inherit the last one's photos.

**Your own photo shows the moment you choose it**, from the phone, with a
spinner while it uploads; it becomes the stored message when the server has
it, or disappears with the reason if the upload fails. The sender's copy is
written to the cache, so it is never downloaded back.

**Receivers see a blurred preview first.** The sender's phone makes a tiny
PNG (about 24 px wide, a few hundred bytes) and sends it in the message
row, `messages.attachment_preview`. It is readable exactly where the
message is and never goes into a notification. Messages cannot be edited,
so the database accepts only well-formed base64 of a PNG there; the app
also drops a preview that will not decode rather than failing the
conversation.

**The media grid decodes thumbnails at thumbnail size**, not full photos.

## 2026-09-24 — The attachment sheet shows the phone's own photos

**Tapping attach opens a sheet with the phone's recent photos** (owner's
choice: WhatsApp-style), and "All photos" still opens Android's own picker.
The grid needs the photo permission, asked at runtime the first time the
sheet opens. On Android 14+ the member may share only selected photos; the
grid then shows those and a "Select more" tile. A refusal leaves the system
picker, which needs no permission.

**Photos only.** The manifest asks for `READ_MEDIA_IMAGES` and
`READ_MEDIA_VISUAL_USER_SELECTED` (and legacy storage up to Android 12) and
removes the video, audio, write and media-location permissions the plugin
would add; a test pins that list.

**If Google Play refuses the photo-permission declaration**, the owner's
rule applies: the grid waits for the owner, and the permission comes out
so releases keep flowing with the system picker alone.

## 2026-09-24 — Deleting a message for everyone

**A sender may delete their message for everyone for 6 hours** (owner's
rule). Within the first hour it vanishes, animated away on any screen that
shows it; between 1 and 6 hours it becomes "This message was deleted". The
server enforces the window (`delete_message`), wipes the content (text,
photo path, preview) and keeps the row as a tombstone, so the conversation
still reads in order. Screens learn of it through Realtime UPDATEs, which
respect the read policy; deletes stay unpublished because Realtime sends a
DELETE to every subscriber of the table.

**The photo file goes too.** Its sender may remove it only after
`delete_message` recorded it and while no live message shows it. Each photo
belongs to exactly one message, in that message's own conversation folder,
and only to the member who uploaded it: otherwise a member could claim or
re-post someone else's photo. Other phones drop it from their cache when
the deletion reaches them. A failed removal is not retried (a known
ceiling).

**Long press opens the message's actions**: delete for everyone here;
reply and forward join it in the next change. Nothing opens when there is
nothing to offer.

## 2026-09-24 — Replies and forwards

**Long press a message to reply or forward it** (owner's choice). A reply
shows a quote of the message it answers; the quote comes from the chat
already on screen, and a deleted original reads "This message was
deleted". The database accepts a reply only to a message of the same
conversation, so a quote can never carry a message across chats or probe
for one.

**Forward to several chats at once, marked "Forwarded".** A photo is
copied server-side into each target chat's folder (members of one chat
cannot read another's photos) and is owned by whoever forwarded it, so the
original sender's later delete does not reach those copies -- as with any
photo someone saved. The label is set by the sender's app, so it is a
courtesy, not proof.

## 2026-09-24 — Read status, mutual like last seen

**Your message has a thin yellow edge until it is read, then looks
normal** (owner's choice; changed 2026-09-25 from a dimmed grey bubble,
which the owner rejected — the edge keeps full brightness and never changes
the bubble's size). In a 1:1 chat "read" means the other person has read
it; in a group, that **any one** member who shares read status has read it
(owner, 2026-09-25; was "everyone"). Touching your message in a group shows
who has read it.

**Mutual, enforced by the server**, like last seen: a "Show when I have
read messages" switch. While it is off, your reads are not shown to anyone
and you see nobody's; a partner who hides it makes your messages simply
normal. Read times live in `conversation_members.last_read_at`, which no
client can select; they reach the app only through `read_marks()` and a
`reads:<conversation>` broadcast that the database sends from `mark_read`,
and only between members who both share. No client can send a read.

**2026-09-25: a read made while the switch was off stays hidden forever,
even after it is turned back on.** `read_marks()` originally returned
`last_read_at` whenever both members *currently* share, so a read made at
03:00 with sharing off became visible the moment sharing was switched back
on at noon -- exactly what "your reads are not shown to anyone" promised
against. The fix (`20260925090000_shared_read_at.sql`) adds
`conversation_members.shared_read_at`, which `mark_read` only advances when
the reader shares at that instant; `read_marks()` now returns
`shared_read_at`, not `last_read_at`, under the same mutual-sharing gate. A
read made while sharing, then hidden by turning sharing off, stays visible
(it was already shared); a read made while off never becomes visible, turning
sharing back on or not. `last_read_at` is untouched and still drives unread
counts, which were never about privacy.

**Known ceiling:** Realtime checks who may receive a channel when it is
joined (and at token refresh), not per message. A modified client that
joins while sharing and then turns sharing off keeps receiving reads until
its token refreshes; the app itself re-subscribes when the switch changes.
The same holds for typing and membership changes.

**In a 1:1 chat the header says just "typing…"**: the person is already
named above it.

## 2026-09-25 — Repo stays public; CI stays on GitHub-hosted runners

**The repository stays public and CI keeps running on GitHub-hosted
runners** (owner decision). Two alternatives were considered and rejected:

- **Self-hosted runner on the current public repo.** A public repo runs
  fork pull request workflows automatically; a self-hosted runner would
  execute a stranger's PR code on the owner's own PC. Not acceptable at any
  usage level.
- **Make the repository private.** Drops two things the free plan does not
  give a private repo: mandatory branch protection (required status checks
  on `main` cannot be enforced without a paid plan) and secret
  push-protection. It would also stop being free to build: CI used about
  1,600 Actions minutes in the 7 days to 2026-09-25 (≈6,800/month
  extrapolated), against the 2,000 free minutes a private repo gets; a
  public repo's Actions minutes are unmetered.

So the trade is paying in unmetered public-repo minutes, not in dropped
protection or a stranger's code on the owner's machine. CI speed (this
entry's sibling work: `.github/workflows/ci.yml`, `tool/ci_local.sh`) is
the lever that stays available: less wall-clock time on hosted runners,
same protection, same public repo.

**Tried and reverted: caching the flutter dev image with
`docker/build-push-action`'s GitHub Actions cache (`type=gha`).** Measured
on PR #36 (Android "Build development image"): 125 s baseline → 374 s on
the run that filled the cache → 141 s on a warm run (36097541294).
Reconstructing a multi-GB image from a remote layer cache with `load: true`
costs as much as building it from scratch; not worth the added workflow
complexity. Reverted; `docker compose build` stayed as it was. The
`supabase start -x ...` trim (this entry) is the change that stuck.

## 2026-09-24 — One SIS notification, grouped like Telegram

**Pushes carry data only, and the app shows them itself** (owner's choice):
one SIS summary in the shade that expands into a notification per chat,
each listing that chat's newest lines, instead of one notification per
message. The server still words each line by the recipient's own preview
setting (full, sender only, no details), so a phone is never sent more than
its owner allowed; the app only arranges them. With "no details" a chat's
entry says "SIS: New message", so the grouping shows how many chats have
news, never who or what.

**What is waiting is kept on the phone** (shared preferences), because a
push is shown by a short-lived background isolate while the app is closed.
Opening a chat clears its notification; signing out clears them all. While
the app is open nothing is shown: the chat list already says what is new.

**Older builds keep regular notifications.** A build from before 0.12 has
no code to show a data-only push, and updates are never forced, so each
device says when it registers whether it shows pushes itself
(`device_tokens.shows_itself`, false unless the app says so). Only those get
data only; every other device still gets a regular notification. An updated
app re-registers on its next start and switches over.

**Nothing of a previous member survives on the phone** (security review,
2026-09-25). The stored inbox is kept per member, and its owner follows the
*settled* session answer from the app's root (signed in / signed out / not
allowed), never the loading or error state: a cold start onto the sign-in or
"not allowed" screen clears the previous member's notifications and inbox,
while an offline start keeps the member's own. The server already stops
pushes to a device whose session ended; a push queued before that can still
draw until the app is next opened. App data is excluded from Android backup
and device-to-device transfer (`data_extraction_rules.xml` for Android 12+,
`backup_rules.xml` below it — `allowBackup="false"` alone does not stop
transfers on 12+).
