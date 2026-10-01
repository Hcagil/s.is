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

**Sign-in keeps no raw text.** Originally Google's error code and Supabase's
rejection text stayed on the sign-in screen; since 0.30.1 (2026-10-01) they
do not, see the entry of that date. Only an offline sign-in says "No
connection".

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
while an offline start keeps the member's own. The server stops pushes to a
session it knows has ended; it cannot know about one that only ended locally
(an offline sign-out, where `forget()` never reaches it), so the phone itself
never draws without knowing whose inbox it is: a push arriving with no stored
owner is dropped before anything is shown or saved, and a push computed for
someone other than the stored owner (delivered after a handover on the same
phone) is dropped too, even though the server addressed it correctly when it
was sent. App data is excluded from Android backup and device-to-device
transfer (`data_extraction_rules.xml` for Android 12+, `backup_rules.xml`
below it — `allowBackup="false"` alone does not stop transfers on 12+).

## 2026-09-25 — Editing a message

**You can edit your own text messages and photo captions for 6 hours**
(owner's choice; the same window as delete for everyone). Forwarded and
deleted messages can't be edited. The bubble then shows a small "edited"
next to its time; **no history is kept** — the old text is replaced, not
stored (owner). An edit sends no notification.

Enforced by the server: `edit_message(message, body)` is the only write path
(sender only, still a member, window, body rules as for a send: a photo
caption may become empty, a text may not). Edits reach open chats the way
deletions do (a Realtime update, re-checked per reader); the chat list
preview follows only when the edited message is the newest. Deleting a
message for everyone also clears its edited mark.

Each bubble now shows its time (HH:MM, local). The date of older messages is
left to day separators, not repeated in every bubble.

## 2026-09-25 — Everything visible is SIS's own design

**No Android-drawn UI inside the app** (owner): notices are an SIS pill under
the header (errors in red, success in brand purple), waits show the Sync S
logo pulsing (static when the phone asks for reduced motion) or a thin brand
gradient line, switches and choices are SIS controls, licences are an SIS
page. Android's photo picker is removed: photos come only from SIS's own
gallery. A guard test fails the build if a stock SnackBar, spinner, switch,
radio, licence page or image_picker comes back.

**Permission prompts are Android's and cannot be replaced or moved to the
store** (the owner asked for consent at download; Android 6+ grants sensitive
permissions only at runtime, and the store's permission list grants nothing).
So each is asked once, behind an SIS screen that explains it: photos the
first time the member attaches one ("Allow photos"; "Open settings" once the
member has refused twice), notifications once after first sign-in — skipped
when the phone has already allowed them.


## 2026-09-26 — Previews and reads stay fast as history grows; offline is said at once

The chat list's preview view read every message ever sent (6.9 s at 50k
messages, measured). It now takes the newest message per conversation the
member belongs to, through the (conversation_id, created_at) index (5.5 ms).
`messages_read` evaluates `has_app_access()` once per query, not per row.
Same rows for every caller; a pgTAP plan guard fails if a sequential scan on
messages comes back.

A read retries at most once (`retriedOnce`), so a dead server is reported in
about a second instead of ~7 s, while one network blip is still ridden out.
Message bubbles hug their text again (a v0.13 time row had stretched every
bubble to full width).

`conversation_members_read` got the same `has_app_access()` InitPlan wrap as
`messages_read` above (5613 buffer hits/~50ms → 1240/~2.5ms at 400
memberships), since `conversation_previews`'s LATERAL scans it per
conversation. Every other live RLS policy with the same bare call in its
USING/WITH CHECK got the identical wrap, predicate otherwise unchanged.

## 2026-09-26 — The time sits on the last line when it fits

Supersedes the time-on-its-own-row layout recorded above. When the body's
last line, a 6 px gap and the time fit inside the bubble's content column,
the time sits on that line at the bottom-right, as in WhatsApp; otherwise it
keeps its own row. The column is the real one: 320 minus padding, and minus
the 1.5 px unread edge on your own messages. The sender name, "Forwarded"
label and reply quote still widen the bubble, and the time stays at the
right edge. Body and time remain separate widgets, so each is found by its
own text and key; one span holding both was rejected for that reason.
Right-to-left text always uses the own row until an RTL locale ships.

## 2026-09-27 — Message search over all history, on the server

The owner asked for search in the chat list (every chat) and inside a chat
(highlight, ↑↓ between hits), over every message ever sent, not only the
newest 500 the phone holds. Searching happens on the server: a folded copy of
each message (`İ`, `I` and `ı` fold to `i`, then lower case) is a generated
column, with a trigram index on it. `search_messages` returns up to 50 hits,
newest first. `messagesAround` loads a window around a hit older than the
loaded page.

The search function is `security definer` and repeats `messages_read`
explicitly (docs/SECURITY.md). Running it under RLS would have scanned every
message on every search. Security review failed it twice on a timing side
channel (how often a word appears in other people's chats). The fix ladder
went to escalation. The pattern is now built once per search and the index
has no pending list (`fastupdate = off`), which leaves a documented residual
of about 0.2 µs per foreign match.

## 2026-09-27 — A search needs three letters or digits; search screens

security-lead's manual attack tests on the local stack, run for v0.16
instead of Strix (the owner declined Strix: host install, Docker socket
access, an outside LLM key), found that a query with no trigram (1–2
characters, or symbols and emoji only) made `search_messages` read the whole
shared index, every conversation's messages, on every call. The owner chose
"search starts at 3 letters". The fix ladder went to escalation twice. The
rule is now three letters or digits, checked on the server before any scan
and in the app (`isSearchable`) before any request. Whatever remains is
documented in docs/SECURITY.md.

The screens: a search field above the chat list, with results showing the
chat, a highlighted snippet and the time; tapping one opens the chat at that
message. Inside a chat, a 🔍 button turns the header into a search bar with
n/m and ↑ older / ↓ newer. Matches are highlighted and the current one gets
a purple edge, distinct from the yellow unread edge. A hit older than the
newest 500 loads the messages around it. Closing returns to the newest
messages.

## 2026-09-27 — Profile pictures for people and groups

The owner asked for a changeable profile picture, and for groups to have
one too. The owner left the details to the manager, who chose them
WhatsApp-like:
- You set or remove your own picture in Settings; any member sets or removes
  a group's, like group names.
- The picked photo is centre-cropped to 512 px JPEG by the platform, with no
  crop screen.
- It shows wherever the initials circle did, and the initials remain the
  placeholder.
- Who sees it: a person's picture follows the profile rule; a group's,
  members only.
- Storage and its rules are in docs/SECURITY.md. The phone's picture cache is
  emptied whenever the session ends.

## 2026-09-27 — Instant search inside a chat (phone first, then server)

The owner asked for search to run on the phone, to reduce database load, and
said "if needed we will change it to instant-local-then-server". The design
review (feature-lead) found that a full on-phone index would download every
member's whole history, which costs the server more than on-demand search.
So the owner's fallback was taken.
- Inside a chat, hits come instantly from the messages already on the phone
  (the newest 500 of that chat).
- The server is asked only when there is no local hit, or when the member
  steps ↑ past the oldest local hit. The counter shows "+" until the server
  has answered.
- A new query after a jump first returns the chat to its newest messages.
- Chat-list search stays on the server.

Accepted limitation: `foldSearch` (Dart) and `fold_search` (Postgres ICU)
differ for 410 rare code points (Cherokee, Georgian Mtavruli, some
Cyrillic/Latin extensions and similar) and Greek final sigma. Turkish letters
and every dotted/dotless i sequence match. The instant hits can differ from
the server's only for those scripts; a pinned test fails on any new drift.

## 2026-09-28 — Pick photos through a gallery app of your choice

The owner asked for a way to pick photos in the gallery app they prefer,
for attachments and for profile and group pictures. This is a deliberate,
owner-requested exception to "Everything visible is SIS's own design"
(2026-09-25): SIS's own grid stays the default, and one extra entry hands
the choice to another app.
- The attachment sheet and the picture picker each get a "From an app"
  entry. Tapping it shows Android's app chooser listing the gallery apps on
  the phone (Google Photos, the maker's gallery, Files...); the member picks
  one, selects there, and the photos come back into SIS.
- Attachments accept up to 10 photos per pick, where the chosen app allows
  several; beyond 10, the first 10 are sent and an SIS notice says so. A
  picture takes one. What comes back goes through
  the same path as a photo from the grid: the send preview and caption for
  attachments, the 512 px centre crop for pictures.
- It needs no photo permission, so it is also offered when the member has
  refused photo access.
- Android's own photo picker stays out: the entry lists apps, it does not
  open the system photo picker. The guard test keeps refusing image_picker.
- Photos only: anything that is not an image is refused with an SIS notice.
- The photos are copied, scaled down while decoding, turned upright and
  re-encoded as JPEG in the background, so a large photo cannot exhaust
  memory or freeze the screen, and no location or camera data is uploaded.

## 2026-09-28 — Pictures like WhatsApp: a crop screen and a larger square

The owner asked to see a profile or group picture full size when tapping
it, and chose to do it the way WhatsApp does, all the way: one stored file.
This replaces two points of "Profile pictures for people and groups"
(2026-09-27): the automatic centre crop and the 512 px size.
- Setting a picture opens an SIS crop screen: the photo under a square
  frame, moved and zoomed with the fingers; "Use" confirms, back cancels.
  The first framing is the centre, as before.
- Still one stored file per picture, now a 640 px square JPEG (typically
  60–120 KB, far under the bucket's 1 MB limit), cropped, scaled and
  re-encoded on the phone, so no location or camera data leaves it.
- Lists, headers and pages draw that same file at their own small size.
- Tapping the picture on a person's page, a group's page or Settings >
  Profile opens it full screen in SIS's photo viewer.
- Pictures set before this version stay 512 px until they are set again.
- The bucket, object keys and access rules are unchanged.
## 2026-09-28 — Swipe a message to act on it

The owner asked for message actions to open by swiping, WhatsApp-like, and
decided the details. This replaces the long press of "Message actions by
long press" (v0.10).
- Every message bubble swipes right and follows the finger. Past a
  threshold it snaps to a resting offset with a light haptic tick, and a row
  of separate SIS boxes appears above it, side by side: only the actions
  allowed for that message (reply, forward, edit and delete for everyone
  only on your own messages within 6 hours, and so on).
- The row opens once the bubble has travelled 64 px, about 1.3 cm of finger
  after Flutter's touch slop; one number to tune after trying it on a phone.
- On release the bubble always springs back to its place (owner, after
  trying 0.21.0 on a phone: the bubble must not stay shifted); the row stays
  open above it.
- The row stays open until an action is chosen, the member taps elsewhere,
  scrolls, or opens another message's row. One row is open at a time.
- Long press on a message no longer does anything.
- Photo messages swipe like text. "This message was deleted" bubbles and
  SIS notices do not swipe.
- A screen reader offers the same actions on each bubble as its own
  actions, so nobody depends on the gesture.

## 2026-09-28 — Your text message appears the moment you send it

The owner reported that sending feels slow "when I click send". Measured:
the server's work for one message (access rules, the notification queue,
the insert) is 5–10 ms; the rest is the phone-to-server round trip, which
the app showed as nothing at all, because a text message was added to the
chat only after the server answered (since v0.2). Photos already appear at
once (2026-09-24); text now does too, WhatsApp-like.
- Tapping send shows your message at once with a small clock mark and
  empties the composer; the clock goes when the server has it.
- Messages sent in quick succession go out one at a time, in the order they
  were typed, so the chat order never changes.
- The server's copy replaces the pending one; the message is never shown
  twice, whichever arrives first (the answer or the live update).
- If a send fails, the pending message disappears, its text (and the message
  it replied to) come back to the composer, and an SIS notice says why.

## 2026-09-28 — Unsent text stays in each chat

The owner: messages you tapped send on are sent, even if you leave the chat;
text you typed but did not send stays in that chat's write box and is there
when you come back.
- Each chat keeps its own draft: the typed text and the message being
  replied to. Leaving the chat keeps it; opening the chat puts it back.
  Sending or clearing the box ends it.
- Offline, or when the connection drops, messages keep queueing in the chat
  with the clock, as many as the member sends; when the connection returns
  they send by themselves, in order (owner). Each carries an id made on the
  phone, so a retry whose first try did reach the server is never stored
  twice.
- A message the server refuses (for example, no longer a member) goes back
  into that chat's draft (before anything typed since), with the notice.
- Each chat sends through its own queue, in typed order, so a slow send in
  one chat never holds up another, and a failure in one chat never stops
  another's messages.
- Reopening a chat while its messages are still sending shows them with the
  clock until the server has them.
- Drafts and queued messages live while the app runs; they are not kept
  after the phone closes the app (storing them on the phone comes with the
  stored chat list, v0.23).

## 2026-09-28 — The app opens faster: start-up requests run side by side

The owner reported that opening SIS after it was closed takes more than 5
seconds. Measured: the server's queries are fast; the time went to about nine
requests made strictly one after another before the chat list could show,
each paying a phone-to-server round trip, plus waiting for the live-update
connection to be fully joined before the list was even asked for.
- Requests that do not need each other's answers run at the same time: your
  own profile and the chat list once you are known to be signed in, and the
  other members' names, the last-message previews and the unread counts once
  the chats are known.
- The chat list is fetched while the live-update connection is still being
  set up; anything that arrives meanwhile is held and applied after, so no
  message is lost.
- The next step, showing the last chat list instantly from the phone, comes
  after leaving a group exists (owner, v0.23).
- The chat list no longer shows "Draft: …" for a chat with unsent text
  (owner); the draft stays in that chat's write box.

## 2026-09-28 — The licences page shows each licence as written

The owner reported the licences page content was wrong. The page (SIS's own,
2026-09-25) dropped each paragraph's layout: centred lines (copyright
headers) were left-aligned and indented clauses lost their indent, so
licences read as one flattened block. Now centred paragraphs are centred and
each indent level is 16 px; a package with several licences shows how many.
Checked against the app's real bundled list (209 packages): none missing,
none shown twice.
## 2026-09-28 — Contacts, exact-tag search, and who sees your picture

The owner decided that New chat must stop listing every member, and that a
member chooses who sees their profile picture.
- **Contacts.** A member can add someone to their contacts (on the person's
  page, or after finding them) and remove them. Only the member sees their
  own contacts list.
- **New chat** shows "your people": your contacts and the people you share
  a chat or group with, by name. Anyone else is found only by typing their
  exact tag; that returns one person or nothing, never suggestions, and the
  lookup is rate-limited so the member list cannot be guessed. The group
  composer and the forward picker use the same people.
- **Who can see a profile** (name, tag, picture path): yourself, people you
  share a chat or group with, your contacts, and the one person an exact-tag
  lookup returned. Everyone else is hidden by the server, not only by the app.
- **Profile picture privacy** (Settings > Privacy): Everyone / My contacts /
  Nobody, default Everyone. One-way, like WhatsApp (hiding yours does not
  hide others' from you). "My contacts" means people you saved; sharing a
  group does not count. Those excluded see the initials circle; the server
  refuses them the picture's path and the stored picture itself. Group
  pictures are unchanged.
- Phone contacts (matching the phone's address book) are a later, separate
  decision.
- "Share a chat" means current membership; when leaving a group arrives
  (v0.23), a member who left stops counting.
- "Everyone" for a picture means any active member who can reach the
  profile, including someone who just found you by exact tag (a narrower
  rule would break the tag result itself); a picture's path is only ever
  handed out through a checked read.
- Contacts are one-way: saving someone lets you see them; their "My
  contacts" picture setting means people *they* saved. The tag lookup allows
  20 searches per 10 minutes per member.
- **Reach** (after the security probes): one rule decides whom a member can
  reach — themselves, someone they share a chat or group with, a contact, or
  someone they found by exact tag (the server remembers the find). Adding a
  contact, starting a chat, inviting to a group, seeing an "Everyone" picture
  and last seen all require it, so harvested account ids unlock nothing.
- The real picture path is kept where clients cannot read it; the old
  `avatar_path` column carries it only for "Everyone" pictures, so older app
  builds keep working and see initials otherwise. Older builds can no longer
  start chats with people they have not reached; existing chats work.
- Accepted leftovers: who is online stays visible to every member (v0.4),
  and a picture link someone generated before the owner narrowed the
  setting works until it expires (the app does not create such links).
- A tag find is forgotten when the found member changes their tag, so a
  member can shed people who only ever found them by tag. "Everyone" always
  includes what "My contacts" allows. Older builds can still set and remove
  their own picture (their write is mapped to the new column).

## 2026-09-29 — Leaving a group, removing members, and admins

The owner decided how people leave groups and who manages them, WhatsApp-like.
- **Admins.** A group's creator is its admin. An admin can make other
  members admins. Only admins add or remove members. If the last admin
  leaves, the longest-standing remaining member becomes admin, so a group is
  never left unmanaged.
- **Leaving and removal.** Any member can leave; an admin can remove anyone
  but themselves (they leave instead). The person who left or was removed
  keeps the group in their chat list, read-only, with the messages up to the
  moment they left; they receive nothing newer, and their write box is
  disabled. Unsent messages still queued for that group are dropped with one
  notice, and its draft is cleared.
- **What others see.** The departed person's past messages stay visible to
  everyone, with their name shown greyed. A line "Ayla left" or "Ayla was
  removed" appears in the chat for admins only.
- **Adding people.** An admin adds someone (new, or someone who left before)
  and chooses whether they see the old messages or only messages from now on.
  An admin can add only people they can reach (contacts rule, 2026-09-28).
- **Reach.** Someone who left no longer counts as sharing that chat.
- 1:1 chats have no admins and no leaving.

## 2026-09-29 — The chat list shows instantly from the phone

The owner asked for the chat list to appear at once when SIS opens, with the
last-message previews, the way WhatsApp does. This is the first time message
content is kept on the phone, which is why leaving a group came first.
- The last chat list the member saw (names, pictures' paths, order, unread
  counts, last-message previews and times) is saved on the phone after each
  successful load and shown the instant the app opens; the server's answer
  then replaces it quietly.
- It lives in the app's private storage, which Android keeps to SIS alone
  and encrypts with the phone; no new library is added.
- It is erased when the member signs out or another account signs in, and
  never shown to a different account. A group the member left keeps only
  its read-only entry, as on the server.
- Nothing else is stored yet: drafts and unsent messages still live only
  while the app runs.

## 2026-09-29 — Update prompt on iOS

- `in_app_update` is Play-only, so iOS never calls it: `main.dart` picks an
  iOS update repository instead of the Play one.
- iOS builds come through TestFlight, which already tells testers about new
  builds, so iOS shows no update banner.
- The minimum supported build still applies on iOS. The CI build number is the
  same as Android's versionCode, so one server value serves both.
- Below the minimum, the required screen opens the TestFlight app
  (`itms-beta://`) instead of the Play page. At App Store release this link
  becomes the App Store URL.
- Nothing is ever forced beyond the minimum.

## 2026-09-29 — Push receipts, and the release-only notification fix

Notifications never appeared on the owner's Android phone although the server
sent every push. Pushes are data only and the app draws them in a background
isolate nobody can watch, so there was no way to see where one stopped.
- Likely cause, fixed in 0.25.1: in release builds R8 strips the generic type
  flutter_local_notifications needs to cancel notifications. Signing in
  cleared the shade before storing the owner, so the call threw, no owner was
  ever stored, and every push was dropped as "no owner". Rules for it are
  added and the owner is now stored first.
- Also: POST_NOTIFICATIONS is declared explicitly, and the handler checks
  the permission before drawing.
- Receipts: the handler keeps one line per stage (received, then shown,
  dropped:<reason> or error) on the phone: stage, message id, error type and
  message cut to 300 characters, build number, time. Never a title, body or
  name. The app uploads them on its next open through
  `report_push_receipts`, into `app_private.push_receipts`.
- The background isolate does not sign in to Supabase: two isolates
  refreshing one rotating refresh token could sign the member out, so the
  phone keeps a 50-line buffer and the main app uploads it.
- Retention: the newest 500 receipts per member, 100 per upload; nothing else
  reads them. Not a feature: a diagnostic that can be dropped once pushes are
  proven on devices.


## 2026-09-29 — Notifications the Telegram way (0.25.2)

On 0.25.1 (notifications arriving again) two things were wrong: six messages
showed two notifications, and tapping one opened a chat without the new
messages until it was closed and reopened.
- Why messages vanished: every push drew its chat notification AND the group
  summary, so a 13-push backlog was 26 posts in about 100 ms. Android sheds an
  app's notifications past roughly five enqueues a second, silently. The push
  receipts confirmed every push was `shown`; the phone dropped them.
  Concurrent pushes also each read, changed and wrote the stored inbox, so one
  could overwrite another's line.
- Now: one MessagingStyle notification per chat (stable id per conversation,
  the newest seven lines, sender name and time on each, the unread count), one
  silent group summary ("N new messages from M chats"). Tapping a chat opens
  that chat; tapping the summary opens the chat list. Opening a chat, or
  coming back to it, clears its notification and stored lines; the summary
  goes with the last one.
- Coalescing: a push only STORES its line (serialised in its isolate), waits
  out 600 ms since the last flush, then one flush posts every chat with unread
  lines plus the summary, 250 ms between posts. A push whose line an earlier
  flush already covered posts nothing. Each post renders the whole stored
  state, so a later post can never lose an earlier message. Alerts (sound)
  only when the shade was quiet for eight seconds, then for one chat; every
  other post is silent. Worst case: pushes handled one at a time (the plugin
  runs queued handlers serially) each wait one interval, so a burst of N
  finishes in about 0.6 s x N, at under four posts a second and never losing
  a line. A process killed mid-wait leaves its lines stored; the next push or
  opened chat shows them.
- `shown` receipt: recorded once the push's line is inside a posted
  notification, whichever push posted it.
- The tapped-chat bug: a chat's Realtime subscription lives only while the app
  is in the foreground and nothing re-read it on return; a tap on the chat
  already open also matched the open id, so nothing rebuilt it (and a second
  copy was pushed). Now the app re-reads the open chat and the chat list, and
  joins Realtime again, whenever it becomes visible, and a tap on the open
  chat does the same instead of stacking a copy.
- No server change: the group name and sender come from the push title the
  server already words ("Sender @ Group"); the time is when the push arrived.

## 2026-09-30 — "What's new" messages from SIS (0.27.0)

- Owner's decisions: plain-language notes appear as messages from "SIS" in a
  read-only system chat in the chat list; they are delivered when the
  member's app updates (the first start of a newer build), with no push; the
  text is automatic and editable by the owner in the Supabase table editor
  until it is delivered; English only (the app has no l10n); the member can
  mute the chat but not leave, delete or write into it; a build whose note is
  empty produces no message.
- Reuse over a parallel local chat: one conversation per member
  (`conversations.system = true`, `direct_key = 'system:<uid>'`) whose
  messages are authored by a fixed system account in `auth.users` (no email,
  so on no allowlist and never able to sign in; its profile is removed). List,
  unread counts, read marks, mute and Realtime work unchanged. A shared
  conversation was rejected: a member would see a note before their own app
  has the build.
- Read-only is enforced by the server: `messages_send` refuses a system
  conversation; leave, add and remove are group-only RPCs (titled
  conversations) and refuse it; there is no delete policy; `notify_new_message`
  returns early for it, so no push is queued. The app hides the composer and
  the forward target, and its profile page offers mute only.
- Source: `public.release_notes(build integer pk, note text, created_at)`,
  RLS on with no policy and no grant: only the dashboard (postgres) and
  `release.yml` write it, clients never read it. `release.yml` joins the
  non-empty `For users:` lines of the PRs merged since the previous GitHub
  release (commit subjects `(#N)` between its tag and the released sha) into
  one row for the published versionCode; no line, no row. `on conflict do
  nothing` keeps a dashboard edit through a re-run. The text travels
  base64-encoded because PR bodies are untrusted input.
- Delivery: `public.deliver_release_notes(installed_build integer) returns
  integer` (SECURITY DEFINER, keyed on `auth.uid()`, needs app access). State
  per member in `app_private.release_note_delivery(user_id, last_build)`; a
  per-member advisory lock makes repeats and two devices deliver each note
  once. The first call ever delivers only the latest non-empty note with
  build <= installed (no backlog); later calls deliver every non-empty note in
  (last served, installed], oldest first. The served build is recorded even
  when nothing was due; an older build than the served one does nothing.
- The app calls it once per start after sign-in (`releaseNotesProvider`) and
  skips the call when shared_preferences says this build was already served
  for that member on this device. A failure is silent and retried at the next
  start.
- Seeded notes: build 177 (0.25.2) and 178 (0.26.0), checked against the
  release tags `v0.25.2+177` and `v0.26.0+178`.
- Ownership: `features/update/` owns delivery (it is keyed on the installed
  build, like the update check); `features/chat/` only displays the result.
- Hardening from review: only PRs whose author is the owner or a
  collaborator count (a PR body can be edited after merge); the note step is
  `continue-on-error` and cut to 4000 characters, so it can never block a
  release; any PR lookup error skips the note for that build rather than
  storing a partial one. Blank means whitespace (space, tab, CR, LF). The
  system account is banned until 2999-12-31 (GoTrue cannot read
  `'infinity'`) and must never be deleted: `messages.sender_id` cascades.
- Accepted risk: a client that reports an absurd build records it and stops
  getting notes. It only affects that member, and clamping it would break
  the rule that a note added later for an older build is never delivered.

## 2026-09-30 — Push notifications on iOS (0.28.0)

- Why a different payload: iOS throttles or drops data-only (silent) pushes,
  and the app cannot reliably wake to draw its own. An iPhone therefore
  always gets a regular FCM notification (title and body worded per the
  member's preview setting, exactly as Android's) with
  `apns.payload.aps.thread-id` = the conversation id, so the system groups
  per chat, and the default sound. There is no `content-available`, so the
  background handler never runs on iOS and the app keeps no inbox or
  receipts there.
- Android is unchanged: `notify-on-message` decides by
  `device_tokens.platform`; an `android` row gets the same JSON as before
  (data only when `shows_itself`, else notification plus data, plus
  `android.priority: high`).
- Where the platform lives: `register_device_token(device_token,
  device_platform, shows_itself)` already stored `platform` (`android` or
  `ios`). The app now sends its real platform
  (`SupabasePushRegistry(client, platform:)`, set in `platformOverrides`);
  iOS registers with `shows_itself = false`. No migration for the platform;
  the session binding above added one.
- Access: *amended 2026-09-30.* The first version of this note said access
  was "unchanged and needs no iOS code". That was wrong. `push_targets`
  checked that the recipient had an active session, not that the token
  belonged to it, so a token from a displaced device stayed a target. On
  Android the phone's owner check dropped such a push; on iOS the system
  draws the alert, so a displaced iPhone would have shown the message on its
  lock screen. Fix (migration `20260930160000_push_token_session`):
  `device_tokens.session_id` records the registering session from the JWT,
  and `push_targets_for_message` requires it to be the member's active session
  and to exist in `auth.sessions`. Existing rows were backfilled with the
  member's current active session; a row with none stays unbound and is never
  a target. Accepted risk: an iPhone signed out while offline keeps its
  server session, and the system keeps drawing its pushes until that session
  ends; the full fix is a Notification Service Extension owner check
  (follow-up). This replaces the "no migration" claim above too.
- Foreground: the app pins the system alert off
  (`setForegroundNotificationPresentationOptions()`, all false), so nothing
  shows on top of the open app, as on Android. A tap arrives through
  `onMessageOpenedApp` / `getInitialMessage`, the same taps stream Android
  uses, so the chat opens with the same catch-up.
- The FCM token on iOS needs the APNs token first: `token()` waits up to
  about ten seconds for it; a later token refresh registers it otherwise.
- iOS project: `Runner.entitlements` (`aps-environment`; Xcode swaps in the
  provisioning profile's production value when signing for TestFlight), and
  `GoogleService-Info.plist` is now a bundle resource (until now
  `Firebase.initializeApp()` had nothing to read on iOS). The
  remote-notification background mode is not added: only silent pushes need
  it.
- Known gaps: the member's per-chat sound and vibration choices live on the
  device, so the server cannot honour them; an iPhone always rings with the
  default sound (a muted chat is still muted, on the server). Opening a chat
  does not remove its delivered notification on iOS (system-drawn ones
  cannot be cancelled by id from the app); signing out removes all of them.

## 2026-09-30 — Photo picking and the square crop on iOS (0.29.0)

- Already working on iOS without a line of native code: the gallery grid
  (`photo_manager`, including limited access and `presentLimited`), the
  full-screen viewer and the crop screen itself (all Flutter). What Android
  implements natively is the `sis/external_picker` channel ("From an app",
  and `cropPicture`, the pixels behind the crop screen). On iOS that channel
  had no handler, so both calls raised `MissingPluginException`.
- New Swift in the Runner target, same channel, same method names,
  arguments and results as `MainActivity.kt` (no Dart or Android change):
  `ExternalPickerPlugin.swift` and `PickedImageProcessor.swift`, registered
  from `AppDelegate`. No new dependency and no Podfile: `image_picker` would
  have added a package for a channel the app already defines.
- "From an app" on iOS is the system photo picker (PHPicker), not the Files
  picker. iOS has no app chooser; PHPicker is the closest thing: out of
  process, needs no photo permission, works with limited access and with
  photos that live in iCloud, and offers albums. The Files picker would add a
  second screen for cloud-drive photos that are in Photos anyway; add it if
  members ask. Attachments are capped at 10 by the picker itself
  (`selectionLimit`), so `dropped` is always 0 on iOS.
- Decode, EXIF rotation and downscale use ImageIO thumbnails (decoded at the
  target size, so a 48 MP photo is never held whole); the crop re-decodes
  with the orientation applied, so a source with an EXIF tag crops the same
  square the member framed. Output is a JPEG, like Android.
- `Info.plist`: the photo-library purpose string is reworded like the
  Android explainer; `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`
  stops iOS from showing its own "select more photos" prompt on every ask,
  since the attachment sheet has its own "Allow more" button. No camera
  string: no flow uses the camera.
- Unverifiable here (iOS builds only on GitHub CI): the Swift has never been
  compiled or run on this machine; the first TestFlight build is its test.

## 2026-09-30 — iOS release: TestFlight from the same run (0.30.0)

- The iOS release is a job of `release.yml` (`ios`), not a separate workflow
  with its own trigger. It needs the release's `versionCode`, the CI-passed
  commit and the same scope decision; a second workflow would have to
  rediscover all three. The version is now computed once, in `scope`, and read
  by `publish` and `ios`. `ios` depends on `scope` only, so Play never waits
  on Apple and an Apple failure cannot fail the Play release: it is a red job
  beside a green one.
- One implementation of the signed build: the reusable workflow `ios-ipa.yml`,
  called by `release.yml` (with upload) and by `ci.yml` on same-repository
  pull requests (without). A signing check that existed only in the release
  would find a signing problem after the merge.
- Signing is cloud-managed with the App Store Connect API key (role Admin),
  `-allowProvisioningUpdates` and the `-authenticationKey*` flags. No
  distribution certificate, `.p12`, profile or match repository is stored
  anywhere: nothing to renew or leak except the key, which lives in a GitHub
  secret and is on disk only for the length of the job.
- `xcodebuild archive` and `-exportArchive` instead of `flutter build ipa`,
  which cannot pass the API key flags. Flutter still writes the build number,
  name and dart-defines into the Xcode configuration first
  (`flutter build ios --config-only`). ExportOptions is generated at run time
  (`app-store-connect`, automatic signing, `teamID` from the secret).
- Upload is `xcrun altool --upload-app` with the same key: nothing extra to
  install. `ITSAppUsesNonExemptEncryption` is false in `Info.plist`, so App
  Store Connect does not ask export compliance on every build.
- The export is checked before upload: `aps-environment` must be `production`,
  or the build installs and never receives a push.
- Off switch: the repository variable `IOS_RELEASE` = `off`. Not built: an
  external TestFlight group (the owner adds testers after the first build
  exists).

**Amended 2026-09-30 (0.30.0 upload rejected).** The first release upload
failed twice over: every code object was rejected as "not properly signed"
(`Code failed to satisfy specified code requirement(s)`), and the build used
the iOS 18.5 SDK (Xcode 16.4 on `macos-15`), which App Store Connect no
longer accepts. The signature finding survived a correct cloud-managed export
(every object signed `Apple Distribution`): the cause is the designated
requirement Xcode and codesign generate, `certificate leaf[subject.CN] =
"Apple Distribution: <name> (<team>)"`. The team's name has non-ASCII letters,
the generated requirement holds them in decomposed (NFD) form while the
certificate holds the composed form, and the comparison fails everywhere
(`codesign --verify` on the runner said "does not satisfy its designated
Requirement" too). No export option controls the requirement, so the app must
be signed by codesign with an explicit one, which needs the private key on
the runner. Now:

- A distribution certificate per run: the job generates a key and CSR,
  `tool/asc_signing.py` creates the certificate and an App Store profile
  through the App Store Connect API (the key the workflow already holds),
  the export signs with them (manual signing), and every framework and the
  app are signed again with `=designated => anchor apple generic and
  identifier "<bundle>" and certificate leaf[subject.OU] = "<team>"`. The
  certificate and profile are revoked in an `always()` step, so nothing is
  stored: still no `.p12`, secret or match repository. Rejected: storing a
  certificate in a secret (a credential to rotate and leak), and asking
  Apple to rename the team (a manual step with an unknown outcome).
- The iOS jobs run on `macos-26` (default Xcode 26.x), the pull-request
  build and the release alike, so both use the SDK Apple requires.
- Two checks the release used to be the first to run: `codesign --verify
  --deep --strict` plus an `Apple Distribution` authority on the app and each
  framework, and on pull requests `xcrun altool --validate-app` (Apple's
  validation of the exported `.ipa`), so a rejection shows on the PR, not
  after the merge. The pull-request run 36762032010 was the first Apple
  accepted ("No errors validating archive").
- Known limit: Apple allows three distribution certificates per team. A run
  killed before its `always()` step leaves one behind; when creation fails
  with that limit, the leftovers are revoked in the developer portal
  (Certificates, Identifiers & Profiles), which is the one manual step this
  design can still need.

**Amended 2026-10-01 (automatic group distribution).** Every TestFlight upload
now reaches the testers without a manual step (owner: "automate both"). App
Store Connect has two groups named `bacanaks`, one internal and one external;
the repository variable `TESTFLIGHT_GROUPS` (comma-separated names, unset =
`bacanaks`) names the targets, and every group with a matching name gets the
build.

- A separate job, `distribute`, needs `ios`, runs on Linux and is not needed
  by `publish`: Apple's processing takes 5 to 30 minutes, and polling on the
  macOS runner would bill it. It waits for `publish` only to read the What's
  new note, which the existing note step now also exposes as a job output
  (base64, since PR bodies are untrusted); it does not recompute it. The job
  runs when `publish` failed too.
- The work is `tool/asc_signing.py distribute` (one tool for everything that
  talks to App Store Connect, stdlib only): find the build, poll until
  `VALID` (cap 60 minutes), set What to Test, add to the groups, and submit
  for beta app review when a matched group is external. Re-running is safe.
- Not invented: the TestFlight Test Information (beta app description,
  feedback email, review contact). If the API refuses the first external
  submission for it, the job fails with a message naming what the owner fills in.
- Follow-ups from the security review of the signing job (PR #84): the
  revoke step tries both deletes and then fails if either did, the local
  cleanup runs regardless, the certificate and profile ids are printed the
  moment they exist, and the intermediate certificate is fetched over https.
  The Admin role rationale in SECURITY.md is corrected.

## 2026-10-01 — Google sign-in on iOS: the token's audience (0.30.1)

**The first TestFlight build (0.30.0) could not sign in**: Supabase answered
"unacceptable audience in id_token", and the sign-in screen printed that
text with the ID in it. Android was fine.

**Cause.** Google's iOS SDK issues the ID token for the iOS OAuth client
(`GIDClientID`), even though the app also passes the Web client as
`serverClientId` (which only adds the server auth code). The Supabase
Google provider accepted one client ID, the Web one, so the audience did not
match. Android's token carries the Web client as audience, which is why it
worked. The 0.29 security note that "the audience is still the Web client"
was an assumption no device had tested.

**Fix: the iOS client joins the provider's client list; the app does not
change for it.** Supabase's Google provider takes a comma-separated list of
client IDs: Web first, then the iOS client
`306417977220-vqg0ne5360a921i23quf294g8e0fjshq.apps.googleusercontent.com`.
Production auth settings are not deployed from the repository (no
`[auth.external.google]` in `supabase/config.toml`, no `config push` in
`release.yml`), so this is set once in the Supabase dashboard
(Authentication, Sign In / Providers, Google, Client IDs). "Skip nonce
checks" stays off: the nonce of 0.27 is unaffected. Rejected: making the app
send the Web client as the iOS client (Google refuses it: the iOS sign-in
redirect needs an iOS client), and skipping the audience check (no such
switch, and it would be the wrong one).

**Sign-in errors are fixed words.** The sign-in screen showed Google's and
Supabase's own error text, which can hold a token or an ID. It now says
"Sign-in failed. Please try again." (or "Sign-in was cancelled. Please try
again."), and the device log (`sis.auth`) keeps only the error code or type,
never a message body. The start-up failure screen, which printed the raw
exception, says "SIS could not start. Please try again." and logs only the
type (`sis.startup`). This replaces the 2026-09-24 "sign-in keeps its
diagnostics" choice.

## 2026-10-01 — Notification bursts: measure before the fix (0.30.4)

**A burst on one Android phone arrived late, not lost.** Every message of a
21-message burst was sent, received and shown; the first two within a second,
the rest in one batch about two minutes later (earlier bursts up to 29 minutes),
while a second phone on the same build was prompt. The plugin hands a
high-priority background push to a service directly and falls back to a
deferrable job only when the phone does not grant the push its high priority,
so the delay is either that fallback or FCM delivering late. The receipts could
not tell which.

**0.30.4 measures instead of guessing.** A small native receiver notes when each
push reaches the phone and with which priority; the `received` receipt carries
the send time, that arrival time, the moment the Dart handler starts and both
priorities (numbers and priority words only, never content). The next burst on
the affected phone decides the fix: draw the notification natively, run our own
handler engine, or change what the server sends.

**Notifications read chat's stores on the phone, read-only.** The sender's
picture comes from the chat list snapshot and the picture cache the chat feature
already keeps, through `notification_avatars.dart`, with the snapshot's owner
check and no network call. This is the one data-to-data import across features;
it stays until a third feature needs the same lookup.

## 2026-10-01 — Read marks across a background (0.30.5)

Owner report from TestFlight: on iPhones the sender often did not see the
read mark. Cause: the 0.25.2 resume catch-up re-read the open chat's
*messages* and the chat list, but not read status. Two losses followed, both
because Realtime replays nothing and iOS suspends the socket at once:

- **Sender backgrounded:** the `reads:<id>` broadcast sent while the phone was
  away was never heard, and `ReadMarksController` was not rebuilt on return,
  so the mark stayed stale until the chat was closed and reopened.
- **Reader backgrounded** with the chat open: messages arriving meanwhile were
  loaded by the catch-up but never marked read (only the live listener did
  that), so the server never recorded a read until the reader left the chat.

**Fix:** `resumeCatchUpProvider` (the one path for app resume and a tapped
notification) now invalidates `readMarksProvider` (re-join, then re-read) and
calls `markRead` for the open chat before the list's catch-up re-read.
Android shared both paths; it merely kept its socket longer. Groups use the
same controller.

**Not marked while hidden.** Where the socket outlived the background (Android),
a message arriving with the chat open but the app hidden was marked read although
nobody saw it. The live listener now marks read only while the app is visible
(`appVisibleProvider`, set from `AppLifecycleListener` onHide/onShow in
`app/sis_app.dart`); the resume catch-up marks it when the member returns.

## 2026-10-01 — A group's notification names the group (0.30.6)

Owner report, Android and iPhone: a group message's notification did not show
the group's name. Cause: the group name only travelled inside the title the
server worded ("Sender @ Group"), and only for the "Name and message" preview.
An iPhone drew that string as is (the system draws the alert, so the app
cannot reword it), and "Only who it is from" dropped the group entirely.

- **Owner's decision:** WhatsApp style. A group's notification title is the
  group's name and each line reads "Sender: message". A 1:1 is unchanged
  (title = the person).
- **Server, not the phone:** `push_targets` gains `sender` and `chat` (the
  group's name, null for a 1:1). The edge function builds an iPhone's alert
  from them (title = group, body = "Sender: message") and sends them as data
  fields `sender` and `chat` to Android, which feeds its MessagingStyle (title
  = group, `groupConversation`, each line's person = sender) from them instead
  of parsing "Sender @ Group". `title` and `body` are unchanged, so older
  builds and the plain 1:1 path are untouched. Reading the name from the local
  chat store was rejected: it cannot work on an iPhone, where the app never
  runs for a push.
- **Privacy:** the group name now travels in the push (FCM, and APNs on an
  iPhone) also under "Only who it is from", as "where from" next to "who
  from". "No details" still carries neither the sender nor the group: title
  "SIS", body "New message". Under "Name and message" nothing new travels.
- Nothing from 0.30.4 changes: one notification per chat, up to 25 lines,
  burst pacing, pictures, iPhone clear-on-read, receipts.

## 2026-10-01 — One long-lived iOS distribution certificate

**Evidence.** The release pipeline created a distribution certificate and an
App Store profile per run through the App Store Connect API, signed, uploaded
with altool and revoked the certificate seconds later (so no certificate
outlived the job).

- 0.30.5 build 193: Apple processing failed, ITMS-90721 "Certificate Revoked"
  (the certificate that signed Runner.app and its frameworks had been revoked
  before processing ended); `distribute` polled "NOT LISTED YET" to its limit.
- 0.30.5 build 194: same pipeline, processed and approved in external beta
  review. The revoke is a race, not a certain failure.
- 0.30.6 build 195 (Release run 36855087297): upload 11:33:24, certificate
  revoked in the same second, `VALID` at 11:35:33, submitted for beta review
  at 11:35:36, then rejected by TestFlight review with ITMS-90035 "Invalid
  Signature". Its signature checks (authority, designated requirement,
  `codesign --verify`) were identical to build 194's, and the pipeline had not
  changed between the two commits.

**Cause.** Apple validates the uploaded binary's signature against the signing
certificate more than once: while processing, and again in beta review up to
about 48 hours later. A certificate revoked before that fails the build, with
an error that does not always say "revoked".

**Options weighed.** (a) Keep each run's certificate until its build's review
ends and clean up by state: Apple allows three distribution certificates, so
three builds in review block the next release, with several releases a day
possible. (c) Skip external review (internal-only testers): changes how
testers are invited and was not verifiable. (b) **Chosen:** one long-lived
certificate, never revoked by a run; the private key is the repository secret
`IOS_DISTRIBUTION_KEY`; the certificate and the profile `sis ci distribution`
are read from App Store Connect on each run.

**Consequences.** Trade-off recorded in `docs/SECURITY.md` (a long-lived key in
repository secrets, the Android keystore's trust model; protected-environment
secret once there are collaborators). The key is generated locally and set with
`gh secret set` (`GITHUB_TOKEN` cannot write secrets); the certificate is
created by a one-off `workflow_dispatch` bootstrap that sees only a CSR. The
yearly rotation and the expiry warning are in `docs/DELIVERY.md`. The earlier
"revoke at `VALID`" idea (commit 2799c04) was dropped for the same reason as
the per-run revoke: beta review comes later.
