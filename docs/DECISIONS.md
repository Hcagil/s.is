# Decisions

Dated record of design and product decisions. Each entry states the decision and the reason.
Entries before 2026-10-03 are in [DECISIONS-archive.md](DECISIONS-archive.md); superseded entries stay there, never deleted.

## Current decisions

- 2026-10-20 — [iPhone encryption is exempt; Info.plist stays NO](#2026-10-20--iphone-encryption-is-exempt-infoplist-stays-no): App Store Connect's own encryption questionnaire found SIS exempt, so `ITSAppUsesNonExemptEncryption` stays `false` and builds carry no per-build answer.
- 2026-10-17 — [The server knows the app language](#2026-10-17--the-server-knows-the-app-language): The server stores the app language (profiles.app_language, en or tr) for the app's own messages
- 2026-10-17 — [Version names follow the date and change count](#2026-10-17--version-names-follow-the-date-and-change-count): Version names are yy.month.commit-count in UTC; the build number is unchanged
- 2026-10-17 — [Private Chats step 1: every message lives on the phone](#2026-10-17--private-chats-step-1-every-message-lives-on-the-phone): Private Chats step 1: each phone keeps a full encrypted copy of its chats and screens read it first
- 2026-10-14 — [Private Chats engine: our own binding, Olm version 1, pinned Rust](#2026-10-14--private-chats-engine-our-own-binding-olm-version-1-pinned-rust): Private Chats engine: own flutter_rust_bridge binding to vodozemac 0.11.1, Olm version 1, pinned Rust
- 2026-10-13 — [Private Chats: end-to-end encryption with vodozemac](#2026-10-13--private-chats-end-to-end-encryption-with-vodozemac): Private Chats: end-to-end encryption with vodozemac (Olm one-to-one, Megolm groups)
- 2026-10-12 — [Sign in with Apple on the iPhone, with the real email only](#2026-10-12--sign-in-with-apple-on-the-iphone-with-the-real-email-only): The iPhone gets Sign in with Apple, with the real email only; Android keeps Google
- 2026-10-11 — [Videos from links play inside the chat, in a sandboxed web view](#2026-10-11--videos-from-links-play-inside-the-chat-in-a-sandboxed-web-view): Videos from links play inside the chat in a sandboxed web view
- 2026-10-09 — [Voice messages and dictation share one composer button](#2026-10-09--voice-messages-and-dictation-share-one-composer-button): Voice messages and dictation share one composer button, copied from Telegram Android
- 2026-10-08 — [Maps for locations: Google Maps on the free tier, with an OpenStreetMap fallback](#2026-10-08--maps-for-locations-google-maps-on-the-free-tier-with-an-openstreetmap-fallback): Locations use Google Maps on the free tier, with an OpenStreetMap fallback
- 2026-10-08 — [The in-app video grid: iPhone now, Android when the owner says go](#2026-10-08--the-in-app-video-grid-iphone-now-android-when-the-owner-says-go): The in-app video grid shows the phone's videos with lengths: iPhone now, Android when the owner says go
- 2026-10-08 — [Video uses the system picker, like photos](#2026-10-08--video-uses-the-system-picker-like-photos): Video is picked through the system picker, like photos
- 2026-10-07 — [Custom themes and chat wallpaper live on the phone](#2026-10-07--custom-themes-and-chat-wallpaper-live-on-the-phone): Custom themes and chat wallpaper are stored on the phone
- 2026-10-06 — [Big updates collect on an integration branch](#2026-10-06--big-updates-collect-on-an-integration-branch): Big updates collect on an integration branch and reach main in one merge
- 2026-10-06 — [Android chat notifications are drawn natively only; Reply needs an unlocked phone](#2026-10-06--android-chat-notifications-are-drawn-natively-only-reply-needs-an-unlocked-phone): Android chat notifications are drawn natively only, so Reply needs an unlocked phone
- 2026-10-05 — [English and Turkish through gen-l10n; system font](#2026-10-05--english-and-turkish-through-gen-l10n-system-font): English and Turkish through gen-l10n, with the phone's own system font
- 2026-10-05 — [The SIS Bot is a server-created account at example.com](#2026-10-05--the-sis-bot-is-a-server-created-account-at-examplecom): The SIS Bot is a server-created account at an email address nobody else can own
- 2026-10-05 — [Uninvited sign-ins are refused before an account exists](#2026-10-05--uninvited-sign-ins-are-refused-before-an-account-exists): Uninvited sign-ins are refused before any account is created
- 2026-10-04 — [Play "Automatic protection" turned off](#2026-10-04--play-automatic-protection-turned-off): Play "Automatic protection" is turned off so Android can open offline
- 2026-10-04 — [Optimistic cold start from a last confirmed session (0.30.15)](#2026-10-04--optimistic-cold-start-from-a-last-confirmed-session-03015): Cold start shows the app from a last confirmed session, with no wait for round trips and no error offline
- 2026-10-01 — [One long-lived iOS distribution certificate](DECISIONS-archive.md#2026-10-01--one-long-lived-ios-distribution-certificate): One long-lived iOS distribution certificate replaces a new one created and revoked on each run
- 2026-10-01 — [Android draws a not-high-priority push itself, at once (0.30.7)](DECISIONS-archive.md#2026-10-01--android-draws-a-not-high-priority-push-itself-at-once-0307): Android draws a not-high-priority push itself at once instead of waiting for the app to open
- 2026-10-01 — [A group's notification names the group (0.30.6)](DECISIONS-archive.md#2026-10-01--a-groups-notification-names-the-group-0306): A group's notification names the group
- 2026-10-01 — [Read marks across a background (0.30.5)](DECISIONS-archive.md#2026-10-01--read-marks-across-a-background-0305): Read marks survive a background period; resume catch-up now also re-reads read status
- 2026-10-01 — [Notification bursts: measure before the fix (0.30.4)](DECISIONS-archive.md#2026-10-01--notification-bursts-measure-before-the-fix-0304): Notification bursts: measure delivery first before changing anything
- 2026-10-01 — [Google sign-in on iOS: the token's audience (0.30.1)](DECISIONS-archive.md#2026-10-01--google-sign-in-on-ios-the-tokens-audience-0301): Google sign-in on iOS must send the token audience Supabase accepts
- 2026-09-30 — [iOS release: TestFlight from the same run (0.30.0)](DECISIONS-archive.md#2026-09-30--ios-release-testflight-from-the-same-run-0300): The iOS TestFlight release is a job in release.yml, using the same run and commit
- 2026-09-30 — [Photo picking and the square crop on iOS (0.29.0)](DECISIONS-archive.md#2026-09-30--photo-picking-and-the-square-crop-on-ios-0290): On iOS, photo picking and the square crop reuse the Flutter code; only the native channel was added
- 2026-09-30 — [Push notifications on iOS (0.28.0)](DECISIONS-archive.md#2026-09-30--push-notifications-on-ios-0280): iPhones get regular FCM notifications (not data-only), grouped by thread
- 2026-09-30 — ["What's new" messages from SIS (0.27.0)](DECISIONS-archive.md#2026-09-30--whats-new-messages-from-sis-0270): "What's new" notes arrive as messages from SIS in a read-only chat, delivered when the app updates
- 2026-09-29 — [Notifications the Telegram way (0.25.2)](DECISIONS-archive.md#2026-09-29--notifications-the-telegram-way-0252): Notifications work the Telegram way: one per chat, no duplicates, tapping opens the chat with new messages
- 2026-09-29 — [Push receipts, and the release-only notification fix](DECISIONS-archive.md#2026-09-29--push-receipts-and-the-release-only-notification-fix): Push receipts were added to trace lost notifications, and a release-only notification bug was fixed
- 2026-09-29 — [Update prompt on iOS](DECISIONS-archive.md#2026-09-29--update-prompt-on-ios): iOS shows no in-app update prompt because TestFlight already announces builds
- 2026-09-29 — [The chat list shows instantly from the phone](DECISIONS-archive.md#2026-09-29--the-chat-list-shows-instantly-from-the-phone): The chat list is stored on the phone and shows instantly with last-message previews
- 2026-09-29 — [Leaving a group, removing members, and admins](DECISIONS-archive.md#2026-09-29--leaving-a-group-removing-members-and-admins): Groups have admins; members can leave and admins can remove members, WhatsApp-style
- 2026-09-28 — [Contacts, exact-tag search, and who sees your picture](DECISIONS-archive.md#2026-09-28--contacts-exact-tag-search-and-who-sees-your-picture): New chat lists only contacts; people are added by exact-tag search; members choose who sees their picture
- 2026-09-28 — [The licences page shows each licence as written](DECISIONS-archive.md#2026-09-28--the-licences-page-shows-each-licence-as-written): The licences page shows each licence as written, keeping centring and indentation
- 2026-09-28 — [The app opens faster: start-up requests run side by side](DECISIONS-archive.md#2026-09-28--the-app-opens-faster-start-up-requests-run-side-by-side): Start-up requests run side by side instead of one after another, so the app opens faster
- 2026-09-28 — [Unsent text stays in each chat](DECISIONS-archive.md#2026-09-28--unsent-text-stays-in-each-chat): Each chat keeps its own draft; sent messages are sent even if you leave the chat
- 2026-09-28 — [Your text message appears the moment you send it](DECISIONS-archive.md#2026-09-28--your-text-message-appears-the-moment-you-send-it): A sent text message appears on screen at once, before the server confirms
- 2026-09-28 — [Swipe a message to act on it](DECISIONS-archive.md#2026-09-28--swipe-a-message-to-act-on-it): Swiping a message right opens its actions, replacing the long press
- 2026-09-28 — [Pictures like WhatsApp: a crop screen and a larger square](DECISIONS-archive.md#2026-09-28--pictures-like-whatsapp-a-crop-screen-and-a-larger-square): Profile and group pictures open full-size; picking uses a crop screen and one larger stored square, like WhatsApp
- 2026-09-28 — [Pick photos through a gallery app of your choice](DECISIONS-archive.md#2026-09-28--pick-photos-through-a-gallery-app-of-your-choice): Photos can be picked through any gallery app the member chooses, an owner-requested exception to SIS-only design
- 2026-09-27 — [Profile pictures for people and groups](DECISIONS-archive.md#2026-09-27--profile-pictures-for-people-and-groups): People and groups can have a profile picture; any group member may change a group's picture
- 2026-09-27 — [A search needs three letters or digits; search screens](DECISIONS-archive.md#2026-09-27--a-search-needs-three-letters-or-digits-search-screens): A search needs at least three letters or digits, closing a hole found by security testing
- 2026-09-27 — [Message search over all history, on the server](DECISIONS-archive.md#2026-09-27--message-search-over-all-history-on-the-server): Message search covers all history and runs on the server, over a folded copy of each message
- 2026-09-26 — [The time sits on the last line when it fits](DECISIONS-archive.md#2026-09-26--the-time-sits-on-the-last-line-when-it-fits): The time sits on the last text line when it fits (supersedes the time-on-its-own-row layout)
- 2026-09-26 — [Previews and reads stay fast as history grows; offline is said at once](DECISIONS-archive.md#2026-09-26--previews-and-reads-stay-fast-as-history-grows-offline-is-said-at-once): Chat list previews read only the newest message per conversation, so they stay fast as history grows
- 2026-09-25 — [Everything visible is SIS's own design](DECISIONS-archive.md#2026-09-25--everything-visible-is-siss-own-design): No Android-drawn UI inside the app: SIS draws its own notices, waits and dialogs
- 2026-09-25 — [Editing a message](DECISIONS-archive.md#2026-09-25--editing-a-message): Own text messages and photo captions can be edited for 6 hours; no edit history is kept
- 2026-09-25 — [Repo stays public; CI stays on GitHub-hosted runners](DECISIONS-archive.md#2026-09-25--repo-stays-public-ci-stays-on-github-hosted-runners): The repository stays public and CI stays on GitHub-hosted runners
- 2026-09-24 — [One SIS notification, grouped like Telegram](DECISIONS-archive.md#2026-09-24--one-sis-notification-grouped-like-telegram): Pushes carry data only; the app shows one SIS notification grouped per chat, like Telegram
- 2026-09-24 — [Read status, mutual like last seen](DECISIONS-archive.md#2026-09-24--read-status-mutual-like-last-seen): A message has a thin yellow edge until read; in groups, read means any member has read it
- 2026-09-24 — [Replies and forwards](DECISIONS-archive.md#2026-09-24--replies-and-forwards): Long press a message to reply or forward; a reply quotes the original from the chat on screen
- 2026-09-24 — [Deleting a message for everyone](DECISIONS-archive.md#2026-09-24--deleting-a-message-for-everyone): A sender may delete a message for everyone within 6 hours (vanishes within 1 hour, then a "deleted" notice)
- 2026-09-24 — [The attachment sheet shows the phone's own photos](DECISIONS-archive.md#2026-09-24--the-attachment-sheet-shows-the-phones-own-photos): The attach sheet shows the phone's recent photos (WhatsApp-style) after a runtime photo permission
- 2026-09-24 — [Photos load once, and yours appear at once](DECISIONS-archive.md#2026-09-24--photos-load-once-and-yours-appear-at-once): A photo is downloaded once per phone and cached; your own sent photos show at once
- 2026-09-24 — [The app's half of push](DECISIONS-archive.md#2026-09-24--the-apps-half-of-push): The phone registers a push token only for the signed-in account and removes it first on sign-out
- 2026-09-24 — [Push notifications: settings, mutes, and a sender nobody can misuse](DECISIONS-archive.md#2026-09-24--push-notifications-settings-mutes-and-a-sender-nobody-can-misuse): Push uses Firebase in the existing Cloud project, Analytics off, with a service account that can only send notifications
- 2026-09-24 — [Errors are written for the member](DECISIONS-archive.md#2026-09-24--errors-are-written-for-the-member): Error messages are written in plain words for the member, never the SDK's raw text
- 2026-09-24 — [Per-account state follows the signed-in account](DECISIONS-archive.md#2026-09-24--per-account-state-follows-the-signed-in-account): Per-account state is dropped and rebuilt when the signed-in account changes
- 2026-09-23 — [Profile pages for people and groups](DECISIONS-archive.md#2026-09-23--profile-pages-for-people-and-groups): People and groups have profile pages opened from the chat title or the member list
- 2026-09-23 — [Links open plainly; photos open full-screen](DECISIONS-archive.md#2026-09-23--links-open-plainly-photos-open-full-screen): Web links in messages open in the browser (http, https, www only); photos open full-screen
- 2026-09-23 — [The release waits for CI on `main`](DECISIONS-archive.md#2026-09-23--the-release-waits-for-ci-on-main): release.yml runs when CI completes and publishes only if CI passed on that exact commit
- 2026-09-23 — [Settings is a set of pages; sign out lives only there](DECISIONS-archive.md#2026-09-23--settings-is-a-set-of-pages-sign-out-lives-only-there): Settings is a set of pages (Privacy, Account, About); Sign out lives only in Account
- 2026-09-23 — [Last seen is mutual, and stored where no client can read it](DECISIONS-archive.md#2026-09-23--last-seen-is-mutual-and-stored-where-no-client-can-read-it): Last seen is mutual (hide yours, lose others') and enforced on the server where no client can read it
- 2026-09-23 — [Unread counts, and why last_read_at is private](DECISIONS-archive.md#2026-09-23--unread-counts-and-why-last_read_at-is-private): Unread is one last_read_at timestamp per member and conversation, kept private; opening a chat marks it read
- 2026-09-23 — [The name, the look and the logo](DECISIONS-archive.md#2026-09-23--the-name-the-look-and-the-logo): SIS means "Stay In Sync", written "SIS"; name, look and logo decided
- 2026-09-23 — [One helper joins and leaves every Realtime channel](DECISIONS-archive.md#2026-09-23--one-helper-joins-and-leaves-every-realtime-channel): One helper (realtime_channels.dart) is the only place a Realtime channel is joined or torn down
- 2026-09-23 — [Online status and typing over private, RLS-gated channels](DECISIONS-archive.md#2026-09-23--online-status-and-typing-over-private-rls-gated-channels): Presence and typing use private Realtime channels authorised by RLS on realtime.messages
- 2026-09-23 — [Member tags and a first-run name screen](DECISIONS-archive.md#2026-09-23--member-tags-and-a-first-run-name-screen): Every member has a unique, editable tag generated at sign-up, plus a first-run name screen
- 2026-09-22 — [Groups, attachments and push: the decisions behind them](DECISIONS-archive.md#2026-09-22--groups-attachments-and-push-the-decisions-behind-them): After-the-fact record of the decisions behind groups, attachments and push
- 2026-09-22 — [Profiles are visible only for allowlisted accounts](DECISIONS-archive.md#2026-09-22--profiles-are-visible-only-for-allowlisted-accounts): profiles_read requires the profile owner to be allowlisted, so non-members' profiles stay hidden
- 2026-09-22 — [Repositories are covered by integration tests, not mocks](DECISIONS-archive.md#2026-09-22--repositories-are-covered-by-integration-tests-not-mocks): Repositories are tested against a real local Supabase stack, not mocked SDKs
- 2026-09-22 — [Riverpod's automatic retry is off for chat providers](DECISIONS-archive.md#2026-09-22--riverpods-automatic-retry-is-off-for-chat-providers): Riverpod's automatic retry is off for chat providers so a failure shows its reason instead of a forever spinner
- 2026-09-22 — [Chat schema: membership is server-authored](DECISIONS-archive.md#2026-09-22--chat-schema-membership-is-server-authored): Conversations and membership have no client write policy; only the start_direct_conversation RPC creates them
- 2026-09-21 — [Android OAuth clients are registered from the downloaded certificate](DECISIONS-archive.md#2026-09-21--android-oauth-clients-are-registered-from-the-downloaded-certificate): Android OAuth fingerprints come from the certificate downloaded from Play Console, hashed locally, never read off the page
- 2026-09-21 — [`main` is protected](DECISIONS-archive.md#2026-09-21--main-is-protected): Branch protection on main: three CI checks, up-to-date branches, linear history, no force pushes; admins can still bypass
- 2026-09-21 — [Project restart](DECISIONS-archive.md#2026-09-21--project-restart): Application code, tests, docs and schema were reset; the Play app, signing keys, Supabase project and repo were kept

## 2026-10-04 — Optimistic cold start from a last confirmed session (0.30.15)

**Problem.** A cold start waited for three round trips in a row
(`activate_session`, the member's profile read, `own_profile`) before the
first list frame, and showed an error screen when the phone was offline. The
owner's bar is a usable list in under 500 ms with the network never on the
critical path.

**Options weighed.** (a) Keep gating on the server: slow, and an error screen
offline. (b) Show the stored list with no binding or bound: a revoked or
replaced session would stay readable on that phone for good. (c) **Chosen:** a
marker file (`last_session.json`) bound to the user and the session id, with a
14-day limit (manager decision), and the confirmation asked behind the list.

**Why RLS stays the authority.** The stored list is already on the phone. The
server refuses every read and write of a revoked member whatever the app
shows, so the optimism only decides what an already stored file displays. The
14 days bound the one residual risk: a member revoked while the phone is
offline.

**Security-lead design: PASS, with blocking items.** B1 closes every route on
Denied and on sign-out (this also fixes a Denied that arrives mid-session
leaving a chat open). B2 binds the marker to user and session. B3 moves
`confirmedAt` only on a server `true` and caps it at 14 days. B4 keeps token
and email out of the marker. B5 is `docs/SECURITY.md` and this entry.

**Consequences.** `Allowed.confirmed` and `Allowed.onboarded`;
`AuthRepository.userId` and `sessionId`; `LastSessionStore` with a JSON file
implementation; a retry ladder of 2 s up to 60 s plus a retry on resume; a
small notice on Home while the check cannot reach the server; iOS excludes
Application Support from iCloud and iTunes backups. No `supabase/` change.

## 2026-10-04 — Play "Automatic protection" turned off

**Context.** Opening SIS on Android without a connection showed a Google Play
box ("Check that Google Play is enabled on your device…") over a black screen
instead of the stored chats. 0.30.16 made the app's own Play update check stay
silent offline, and the box still came back. The remaining source is Play
Console's *Automatic protection*, which wraps the published build with Google
Play's own integrity check; that check needs Play to answer, so offline it
blocks the start.

**Decision.** The owner turned Automatic protection off in Play Console
himself (2026-10-04). It applies from the next build Play processes, not to
builds already installed.

**Why this is safe.** SIS does not rely on an install-source check for
anything. Every read and write is decided on the server by RLS and the app
access check; a copy installed from outside Play gets nothing a Play install
would not. What we give up is Google's blocking of re-distributed or modified
copies, which matters little for a closed tester group.

**Consequences.** Offline start on Android is no longer blocked by Play. The
owner re-tests the offline open after the next release (open online, wait a
minute, close, airplane mode, open: the stored chats appear). If we later want
install-source assurance, it comes back as an explicit Play Integrity check
that fails open offline, decided in its own entry.

## 2026-10-05 — Uninvited sign-ins are refused before an account exists

**Context.** Anyone who finished Google sign-in got an auth user and a profile
row, and was only then denied by the allowlist (Play's pre-launch robots made
eleven such accounts on 2026-09-21). The hosted email provider was found on,
although the project is documented as Google-only.

**Decision.** A Supabase "before user created" auth hook,
`app_private.before_user_created`, refuses a sign-up unless the normalised address is on the
allowlist and is not on a reserved test domain (example.com, .net, .org, which
covers the SIS Bot). It has a `google_only` switch, left off: the email provider
is being turned off and Apple sign-in arrives in v0.31, so a provider check
would only have to be loosened again. It fails closed (no catch-all that allows); break-glass is switching
the hook off in the dashboard. It runs as `supabase_auth_admin` with read access
to the allowlist only. The app maps the resulting 403 to the existing Access
denied screen. In the same migration, `deleted_attachments` gains `recorded_at`
(a deleter's record only covers an object that existed when it was written) and
a re-delete of a re-used path takes over the record (security re-gate findings
L1 and L2).

**Why.** Data minimisation: strangers leave no rows. Admin `createUser` does not
run the hook (verified on gotrue v2.196.0), so the bot is created through it and
its address is refused for every public path. The hook does not cover existing
users or linking, so `has_app_access()` stays the authoritative gate.

**Consequences.** The local config runs the hook too: invited fixtures are on
the seed allowlist and non-invited fixtures are created through the admin API,
which the hook does not see. Production enables the hook in the dashboard or
through the Management API after the migration is applied, and keeps the email
provider off (since 2026-10-05). Turning `google_only` on needs Apple added to it first.

## 2026-10-05 — The SIS Bot is a server-created account at example.com

**Context.** Testing rounds need an assistant that talks to testers inside SIS:
the Debug chat and 1:1 chats with testers the owner names. The bot needs an
email address that nobody else can ever own, because SIS links a Google
sign-in to an existing user by email. The owner wants no extra Google account,
no phone check and no captcha.

**Decision.** The bot is a Supabase user created on the server with the
address `sis-destek-bot@example.com`. It has no password and no Google sign-in.
Its session is made once by a private admin step, and only the refresh token is
kept, outside the repository.

**Why it is safe.**
- `example.com` is reserved by IANA and receives no mail, so no login link,
  code or password reset can reach anyone.
- No Google account can be verified on that address.
- The bot is created with its own name ("SIS Destek") and tag, so nothing is
  derived from the email.
- The order closes the sign-up race: create the user (email confirmed) first,
  then add the allowlist row, and remove the allowlist row before ever deleting
  the user. The sign-up hook admits the address only through admin creation.
- On the server the bot can reach only the Debug chat and 1:1 chats with
  owner-listed testers. It is never an admin, gets no push, is rate-limited,
  and has an owner-only off switch. RLS and RPC checks cover every path, and
  the bot session never holds the service-role key.

**Consequences.**
- Mail to the bot goes nowhere, so the bot has no email recovery. If its
  session is lost, the owner's admin step makes a new one.
- Revoking its session or flipping the off switch stops it at once.

**How it is enforced.** Migration `20261005130000_sis_bot.sql`: a trigger on
`conversation_members` proves every membership (the Debug chat, or the 1:1 with
a listed tester, role member); the OFF switch sits inside `has_app_access()`;
find-by-tag, group avatars, release notes, device tokens, profile and contact
writes, uploads and Realtime are refused for the bot; sends and chat starts are
rate-limited (RLMT2). The Debug membership is made by the owner-run bootstrap
while the switch is still OFF, so it is exempt from the ON and rate checks; a
runbook insert (no JWT) is exempt from ON so listing a tester works while OFF.
The tool pair is `tool/sis_bot.sh` (bot session only) and
`tool/sis_bot_admin.sh` (owner-run, in the owner's own terminal; service key read only from a mode-600 file the owner names, never from an environment variable).

## 2026-10-05 — English and Turkish through gen-l10n; system font

**Context.** Update 1 brings every screen in Turkish as well as English. The
"What's new" decision of 2026-09-30 said English only because the app had no
localisation. The approved Update 1 design also sets text in the phone's own
font.

**Decision.** Strings live in `lib/l10n/app_en.arb` and `app_tr.arb` and are
read through the generated `AppLocalizations` (gen-l10n, configured in
`l10n.yaml`). The app follows the system language; there is no in-app
language switch. The generated Dart files are checked in, so analysis and
builds do not depend on a generation step. This adds the SDK package
`flutter_localizations` and its required `intl` dependency. Text uses the
platform default font (no `fontFamily` in the theme); the Sora wordmark is
unchanged.

**Consequences.**
- Every new string goes into both ARB files in the same change, and a test
  keeps their keys equal and their values non-empty.
- Localised text is a presentation concern: `application/` and `core/` return
  typed failures or reason codes, never sentences.
- iOS offers Turkish only once `CFBundleLocalizations` lists `tr` (and `tr` is
  in `knownRegions`); that change ships with the Update 1 release.

## 2026-10-06 — Android chat notifications are drawn natively only; Reply needs an unlocked phone

**Context.** A Reply from a lock-screen notification must not send without
the phone being unlocked. Android 12 (API 31) can require that with
`setAuthenticationRequired(true)`, but only on notifications drawn natively;
the Dart notification plugin cannot set it. Android 11 and older has no such
flag at all. Chat notifications were drawn by two paths (native
`InstantPush` and Dart `LocalPushDisplay`), so the rule could not be held on
both.

**Decision.** `InstantPush` (Kotlin) is the only drawer of Android chat
notifications. Dart keeps setup, taps, clearing and channel pruning, but no
longer posts chat notifications on Android.
- API 31 and above: Reply is shown and requires unlock.
- API 30 and below with a secure lock (PIN, pattern, password): no Reply
  button; Mark as read stays. A Reply that still arrives while the phone is
  locked (an older notification) is refused with the "not sent" line.
- API 30 and below without a secure lock: Reply stays, as nothing could be
  unlocked.
- iOS: the Reply action is `.authenticationRequired`.

Arrival pacing moves native with the drawer: pushes are drawn in order on one
background thread, at least 300 ms apart up to 15 queued, then without a gap,
so a burst never holds the receiver past Android's limit. The old
`sis-instant*` channels are deleted once; the `msg-*` channels, and the
owner's per-chat settings on them, are kept. The channel-id hash is shared by
Dart and Kotlin through `test/fixtures/alert_channel_vectors.json`.

**Consequences.**
- Notification layout changes are made in Kotlin. The group summary has a
  Dart twin for iOS (`_showSummary`); the two carry "keep in sync" comments.
- Owner decision 2026-10-06: Reply needs unlock on every phone, and both
  parts ship before Update 1.

## 2026-10-06 — Big updates collect on an integration branch

**Context.** The owner chose to ship the approved full design as a few large
updates instead of many small releases. Merging each slice into `main` would
release every slice on its own, because a push to `main` publishes.

**Decision.** A big update collects on one integration branch,
`feat/update-<n>`. Each slice is still a short-lived topic branch, gated and
squash-merged by PR into the integration branch, with the same checks as
`main`. When the update is complete, the integration branch is merged into
`main` in one PR, which releases it. Fixes that cannot wait still go to
`main` directly as usual, and `main` is merged into the integration branch
afterwards.

**Consequences.**
- `main` stays releasable and receives one release per big update.
- The integration branch lives only for the duration of one update and is
  deleted after it is merged.
- User-facing text: the developer-only "Setup required" screen (shown when a
  build is missing its configuration) stays in English; every screen a user
  can reach is localised.

## 2026-10-07 — Custom themes and chat wallpaper live on the phone

**Context.** The owner approved custom themes and a chat wallpaper in the full
design. Update 2, slice 4 builds them.

**Decision.**
- One theme object, `SisBrand`, built by `sisTheme` from `sisBrandFor`
  (built-in) or `sisBrandForCustom` (custom), is the only source of colour.
  Widgets read `SisBrand`; nothing hard-codes theme colours.
- Custom themes (id, name, mode Automatic/Light/Dark, accent, my-bubble
  colour, their-bubble colour) and the chat wallpaper (none, colour,
  gradient or picture; dim 0 to 0.8; blur 0 to 12) are stored on the phone
  only, in the existing shared_preferences appearance store under
  `sis.appearance.custom_themes`, `sis.appearance.custom_theme_id` and
  `sis.appearance.wallpaper`. No server, no migration. A picked picture is
  copied into the app's own folder and its path is stored. The settings are
  read before `runApp`, so the first frame is already right.
- Effective wallpaper: the member's own non-none wallpaper wins; otherwise a
  custom theme shows none; otherwise a built-in theme shows its own
  wallpaper from the approved mock, in dark brightness only (light shows
  none, so text stays readable). There is one global wallpaper, behind the
  message list in every chat. "Reset Chat Backgrounds" sets the wallpaper to
  none and deletes the picture file.
- A custom theme with mode Light or Dark overrides the phone; Automatic
  follows it.
- The theme editor ("+ New theme") is designed but not built: it waits for
  the owner to approve its mockup. Until then it is greyed out and custom
  themes come from Duplicate (long-press a built-in tile, or the dots card
  on a custom theme). Custom accent colours are not yet contrast-checked
  against white text; the editor must restrict them.

**Consequences.**
- Themes and wallpaper are not backed up or shared between phones; the
  Appearance page says so.
- The editor needs no storage change.

## 2026-10-08 — Video uses the system picker, like photos

**Context.** Sending a video needs the member to choose one. A gallery grid of
our own would need `READ_MEDIA_VIDEO`, which the "Photos only" decision
(Play data-safety and permission posture) deliberately avoids.

**Decision.**
- Video uses the system chooser through `file_picker`, like photos and files;
  no `READ_MEDIA_VIDEO`, the manifest does not change.
- After the pick, a review page shows the videos as tiles with "Send (N)".
- A video is limited to 5 minutes, shrunk on the phone to about 720p
  (`light_compressor_v2`) and then uploaded under the existing 50 MiB cap;
  playback uses `video_player`, the share sheet `share_plus` (all in `data/`).
- The send queue is saved on the phone, so text, file and video sends
  survive the app being closed.
- The thumbnail is a small jpeg stored next to the video as `<path>.t`.

## 2026-10-08 — The in-app video grid: iPhone now, Android when the owner says go

**Context.** The owner wants the video picker to be SIS's own grid of the
phone's videos with their lengths, like Telegram (approved design: row
`att_vpick` of the full-design mockup). This reverses the 2026-09-24 "The
attachment sheet shows the phone's own photos" choice ("Photos only": no video
permission) and, for the video picker, the entry above ("Video uses the system
picker"). On Android the grid needs `READ_MEDIA_VIDEO`. Play is likely to
refuse that declaration for a chat app, because the system picker already
covers the need, and a declaration that is pending blocks all publishing.

**Decision.**
- iPhone: the grid is on now. It lists videos through `photo_manager` (already
  a dependency, 3.12.0, Apache-2.0), used only in a feature's `data/` layer
  (`PhotoManagerVideoGallery`). `NSPhotoLibraryUsageDescription` is in English
  and Turkish (`en.lproj` and `tr.lproj` `InfoPlist.strings`). With limited
  library access only the allowed videos show, with "Allow more" (the system
  sheet, `presentLimited`). With denied access SIS shows its own screen:
  Allow or Open settings, "Use the phone's picker", "Not now".
- Android: the grid is off. No `READ_MEDIA_VIDEO` (the manifest still removes
  it with `tools:node="remove"`) and no other new media permission. The
  phone's own picker from the entry above stays until the owner says go.
- A per-platform constant in `lib/core/platform_features.dart`
  (`videoGridOnIos`, `videoGridOnAndroid`) picks grid or phone picker. It is a
  compile-time constant, not a remote flag. Turning Android on later is that
  one line plus the manifest permission (and the Play declaration).
- The grid feeds the existing video path unchanged: copy and length check up
  to 5 minutes (the shared `prepareVideoSource`), compress, the saved send
  queue. The grid's "Send (N)" bar replaces the review page on that path; the
  review page stays for the phone's picker.

**Consequences.**
- iPhone members see the grid, and the Photos permission prompt the first time
  they pick a video (the same library permission as the photo grid). Android
  members see no change.
- The grid and the permission flow on a real iPhone can only be checked on a
  device (no integration test), like the photo gallery.

## 2026-10-08 — Maps for locations: Google Maps on the free tier, with an OpenStreetMap fallback

**Context.** Sending a location needs a map, a place search and a card
preview. Nominatim (OpenStreetMap's search) forbids app autocomplete, so it
cannot power the search box.

**Decision.**
- Google Maps Platform on its free tier: `google_maps_flutter` for the map,
  Places API (New) over REST for search, the Maps Static API for the card
  preview, the Geocoding API for the address. Static map images are kept in
  memory only, never on disk (Maps Platform terms); Places and Geocoding
  coordinates may be cached for at most 30 days under the same terms.
- Before a location is sent, the phone sends the pin or position to Google
  (reverse address, search bias, each pin move).
- The iOS implementation is `google_maps_flutter_ios_sdk9` (Swift Package
  Manager, iOS 15), so the repo stays SPM-only with no Podfile.
- Keys are restricted per platform (Android package + signing SHA-1, iOS
  bundle id) and each API has a per-day request cap, so a leaked key cannot
  run up a bill.
- Keys stay out of git: CI secrets `MAPS_API_KEY_ANDROID` / `MAPS_API_KEY_IOS`,
  locally `.private/maps.properties` and `ios/Flutter/Secrets.xcconfig`
  (both git-ignored). The Dart side reads `--dart-define=MAPS_API_KEY`.
- Everything sits behind a swappable layer (`MapsBackend` in `data/`). With no
  key the app builds and runs on `flutter_map` with OpenStreetMap tiles, with
  no search and no street address.
- Location is foreground only (`ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION`,
  `NSLocationWhenInUseUsageDescription`), asked for when the picker opens.

**Consequences.** A location message stores latitude, longitude, name and
address. Opening the card asks first, then hands the point to the phone's maps
app. Tile and image requests to third parties carry the phone's IP, as any
map does.

## 2026-10-09 — Voice messages and dictation share one composer button

**Decision.** The composer has one button for voice and dictation, copied from
Telegram Android: a tap switches the mode, a hold starts it, release sends,
a left swipe cancels, an upward swipe locks. A voice message is a file message
(`audio/mp4`, AAC in an `.m4a`) of up to 10 minutes with a small stored
waveform, sent through the existing upload, offline queue and storage.

- Packages: `record` 7.1.1 (recording, https://pub.dev/packages/record) and
  `speech_to_text` 7.5.0 (dictation, https://pub.dev/packages/speech_to_text).
  Both are SDK imports, so they live in `data/` only (`tool/check_pattern.sh`).
- Dictation runs on the phone only (on-device recognition) and writes into the
  message box in the app language. Nothing is sent to a server. The
  `speech_to_text` package silently falls back to the network recogniser when
  no on-device one exists, so on Android dictation first asks the phone
  (`SpeechRecognizer.isOnDeviceRecognitionAvailable`, Android 12 and later,
  through the `sis/speech` channel in `MainActivity`) and refuses to start,
  showing the "unavailable" notice, when the answer is no or unknown. iOS sets
  `requiresOnDeviceRecognition`.
- The transcript is a nullable column (`voice_transcript`, 1 to 10000
  characters) with the same row security as `body`. It is never part of a push
  or notification text and never part of the chat list preview. The
  `VoiceTranscriber` seam ships returning null, so "Show text" is never shown
  yet; native recognition of a recorded file is a separate follow-up step.
- Chat list, forward and quote previews say "Voice message".

**Consequences.** Android asks for `RECORD_AUDIO` only; iOS gets English and
Turkish usage strings for the microphone and speech recognition. Played state
is kept on the phone only.

## 2026-10-11 — Videos from links play inside the chat, in a sandboxed web view

A tap on the play mark of a YouTube, Instagram, TikTok or X link card opens a
card rising from the bottom (the approved "option B" mock) with the card's own
picture and a dimmed play mark; the site's official embed loads behind it.
Nothing contacts the site before that tap.

- Packages: `webview_flutter` 4.14.1 (https://pub.dev/packages/webview_flutter),
  with `webview_flutter_android` 4.14.1 and `webview_flutter_wkwebview` 3.27.0
  used directly for the sandbox settings. Support: Android SDK 24+, iOS 13.0+
  (the app is on 24 and 15). All three are SDK imports, so they live in
  `data/` only (`tool/check_pattern.sh`). No new permission.
- Embeds, official forms only: YouTube `youtube-nocookie.com/embed/<id>`
  (YouTube's no-cookie embed address; it needs a `Referer` of `https://com.esd.sis`, or YouTube
  answers error 153); Instagram `/p|reel|tv/<code>/embed/`; TikTok
  `tiktok.com/player/v1/<id>` (its embed player); X
  `platform.twitter.com/embed/Tweet.html?id=<id>`. Short links (vm.tiktok.com,
  t.co) have no embed and keep opening outside the app. The rules live in
  `domain/video_embed.dart` (`videoEmbedFor`, `videoEmbedAllows`).
- Sandbox: HTTPS only, hosts on a per-site allowlist, any other navigation
  opens the browser or app and is cancelled, no JavaScript bridge, no file or
  content access, mixed content never allowed, no permission requests, no
  zoom, and the cache, local storage and cookies are cleared when the card
  closes. JavaScript stays on because the embeds need it.
- A refusal is shown when the page answers 401, 403, 404, 410, 451 or fails to
  load. With no bridge the app cannot see errors drawn inside the player
  itself; the site shows its own message there.
- Picture-in-picture is not built: `webview_flutter` has no support for it and
  it would need native code on both platforms.

**Consequences.** Cards that were refused show the normal link card with an
"Open in <site>" row until the app is closed (kept in memory only).

## 2026-10-12 — Sign in with Apple on the iPhone, with the real email only

**The iPhone gets a Sign in with Apple button below the Google button; Android keeps Google only.** App Store rule 4.8 asks for an equivalent sign-in when another third-party one is offered. It is native (the `sign_in_with_apple` package, 8.2.0) and goes through `signInWithIdToken` like Google.

- A hidden Apple email (`@privaterelay.appleid.com`) is refused: SIS matches people by a real address on the invite list, and a relay address matches nothing. The phone refuses it first, with its own message; the sign-up hook refuses it as a server backstop and nothing is stored.
- The same real email through Google and Apple is one account (Supabase automatic linking of identities with the same verified email).
- The invite list applies exactly as for Google, through the same `before_user_created` hook.
- Every attempt sends a fresh nonce (SHA-256 to Apple, raw to Supabase) and the Apple provider keeps the nonce check on.
- Both sign-in ways obey one-phone-at-a-time, including the sign-in buttons on the "You signed in on another phone" screen.
- CI turns the Sign in with Apple capability on for `com.esd.sis` through the App Store Connect API and replaces a profile that lacks the entitlement.

**Reason.** Rule 4.8, and iPhone users without a Google account. **Consequence.** The Supabase Apple provider must be enabled with the bundle ID as Client ID before the iPhone build can sign in.

## 2026-10-13 — Private Chats: end-to-end encryption with vodozemac

**SIS messages become end-to-end encrypted: locked on the sender's phone, unlocked only on the receivers' phones.** The engine is Matrix's `vodozemac` (Olm for one-to-one sessions, Megolm for groups). It is Apache-2.0, externally audited by Least Authority, and it runs behind our own `flutter_rust_bridge` binding. SIS stays closed source.

- Not chosen: `libsignal` is AGPL, which would force SIS to be open source, and Signal does not support it outside Signal. Writing our own ratchet is ruled out: Matrix retired its older `libolm` over flaws (CVE-2024-45191/45192).
- The server still sees metadata: who talks to whom and when, group members, message size and type, read marks, and who reacted to which message and when (the reaction's content is locked in one-to-one chats). The privacy notice says so.
- Groups: the app makes random Megolm group keys and rotates them when members change. No person ever chooses a group key.
- Search moves onto the phone, on a new on-phone message store. Notification text and pictures are unlocked on the phone, including in the iPhone notification extension. Link cards, polls, media, voice and location travel inside the encrypted message; the server can still count poll votes.
- Bot chats (the Debug group and the tester one-to-one chats) stay unencrypted. They carry a label and need the tester's OK, with the warning "This chat is not end-to-end encrypted: an AI and the developer read it. Please don't write passwords or private things here." System chats (What's new, Admin) stay unencrypted as well.
- Messages sent before encryption are not re-encrypted. They are kept and marked "sent before encryption", and the group switch that shows old messages to new members keeps working for them. Deleting them is a separate, later decision.
- Key backup:
  - The same kind of phone restores the key automatically, from iCloud Keychain or Android Block Store.
  - Between iPhone and Android, the key is split in two: one half in the user's Google Drive app-data folder, the other on our server. Neither Google nor SIS can open it alone. The user does nothing.
  - Optional extras:
    - a QR code scanned from the old phone;
    - a spare key shown as a QR code;
    - a PIN or passphrase layer, off by default, that cannot be recovered. "Forgot" means setting a new one while a phone still holds the key.
  - A PIN kept on our server is ruled out: without a hardware vault with a try limit (Signal SVR), a short PIN falls to offline guessing.
- An optional app lock (fingerprint, face or screen lock) is separate from the encryption key and off by default.
- Report and block users are built in. The reporter's phone sends the reported messages, only with the reporter's OK (App Store 1.2, Play user-generated content policy).
- Finding people by email is removed completely.

**Reason.** The owner wants nobody but the people in a chat to read it, including SIS, Supabase, Google and Apple.

**Consequences.**
- A user who loses every phone, cannot reach the Google Drive half and kept no spare key loses their encrypted history. A hijacked Google account can open that user's backup; the owner accepted this for zero-action restore. A user who signs in only with Apple and moves to Android needs one QR scan.
- Every phone change shows contacts a "security code changed" notice, and a screen compares the codes by QR.
- Once Private Chats ships, the owner raises the minimum supported build by hand, so older builds must update. This replaces the earlier rule that the minimum is never raised, for this release only. Nothing raises it automatically.
- Before the first encrypted TestFlight build, the iPhone export answer (`ITSAppUsesNonExemptEncryption`) is re-answered. Before any release beyond friend testers, a Turkish lawyer checks law 5809 Art. 39 and OTT authorisation.
- It is built in steps, each tested with the friend testers:
  1. the on-phone store and search;
  2. the engine and the binding (Android, iPhone, the notification extension);
  3. the key directory;
  4. one-to-one text and notifications;
  5. groups;
  6. media and attachments;
  7. security codes;
  8. key backup;
  9. bot and system chats, and switching off the plain-text server paths;
  10. report and block.

## 2026-10-14 — Private Chats engine: our own binding, Olm version 1, pinned Rust

**SIS calls vodozemac 0.11.1 through its own thin flutter_rust_bridge 2.13.0 binding (Cargokit), and one-to-one sessions use Olm version 1.** Version 1 is vodozemac's default and the Matrix `m.olm.v1.curve25519-aes-sha2` scheme, the one covered by the 2022 Least Authority audit; version 2 sits behind an experimental feature and is not in the Matrix spec.

- Message types keep vodozemac's numbering: 0 = pre-key (opens a session), 1 = normal. There is no mapping layer.
- The iPhone notification extension reaches the same crate through a plain C function and a cbindgen header, because flutter_rust_bridge needs the Flutter engine and the extension has none.
- Rust is pinned to 1.99.0 in `rust/rust-toolchain.toml`; the vendored Cargokit reads that file instead of installing today's stable, so builds can be reproduced. The rustup installer in the Docker image is pinned and checked by SHA-256.
- Release builds log only warnings from Rust, so a later debug line cannot leak plain text into device logs.
- The binding lives in `lib/data/crypto/`, and only `data/` layers may import `flutter_rust_bridge` (`tool/check_pattern.sh`).

**Reason.** Apache-2.0 keeps SIS closed source (the existing Flutter binding is AGPL), and the audited, spec-defined version is the safe default. **Consequence.** Each session stores its version, so moving to version 2 later affects only new sessions. The crate licences must be shown in the app before a public release.

## 2026-10-17 — Private Chats step 1: every message lives on the phone

**Each phone keeps its own copy of the member's chats in one encrypted database file, and the screens read that copy first.** This is step 1 of Private Chats (2026-10-13). It replaces the 2026-09-27 "Instant search inside a chat" decision, which kept only the newest messages on the phone because a full copy cost the server too much. Once messages are encrypted the server can no longer search them, so the full copy on the phone is required.

- The store is drift 2.35 on SQLite3 Multiple Ciphers. The file is encrypted from day one, and its key is kept in the iPhone Keychain or the Android Keystore (on iPhone, this device only, so a backup restores it only onto the same phone). On iPhone the file sits in the App Group container, so the notification extension can open it later; if the container is unavailable it falls back to the app support folder. On Android it sits in the app support folder, which is not backed up (`allowBackup="false"`). The iPhone backup-exclusion flag is set on Application Support only, not on the App Group container; on any other phone a restored file there cannot be opened, so the app deletes it and starts empty.
- The server stays the truth. Opening a chat shows the stored messages at once, then the server page replaces them and removes rows the server no longer returns.
- Catch-up: a new `messages.updated_at` column, set by a trigger on every insert and update, feeds `changesSince`. One cursor per account moves forward after each page and starts 5 seconds early, so a late commit is not missed. Catch-up runs on app start, on resume and on sign-in.
- A new phone fills in the whole history in the background: text and metadata only, never media. It goes newest chats first, in pages of 300 rows, and gives way to the chat that is open. A killed app resumes where it stopped.
- Groups the member left keep the messages the server still lets the member read (its membership dates decide). The app has no leave-date rule of its own.
- Sign-out, a denied account or a replaced session erases the file and its key. A file left by another account is erased on open. The chat list itself lives in the same encrypted file. The push feed file (`chat_list.json`, read by the Android push code) never holds message text; at launch the app deletes an old-format `chat_list.json` (one that could hold previews) and keeps a valid new feed.
- Search runs on the phone. The server search stays as a fallback for history not yet filled in, until step 9 switches off the plain-text server paths. In the chat list it is asked unless every chat is fully stored. Inside one chat it is asked only if that chat is not fully stored and the phone found nothing.

**Reason.** Chats must open instantly and keep working offline. Encrypted chats can only be searched and shown where they are unlocked: on the phone.

**Consequences.**
- A new phone downloads the member's full text history once, which costs server reads.
- Reactions and polls still load a moment after the messages; storing them is a later slice.
- Messages hidden only for this member, and messages removed outright on the server, are not in the change feed. They leave the phone when the chat list or that chat's page is next checked.
- There is no reconnect signal yet, so a Realtime reconnect does not start a catch-up; resume does. A reconnect hook is a follow-up.

## 2026-10-17 — Version names follow the date and change count

**Decision.** Each release's version name is `<yy>.<month>.<commit count on main>` in UTC, e.g. `26.10.220`, computed by the release run. The build number (`versionCode` = run number + 100) is unchanged and is never shown in the app: Settings, What's new and the update-required screen show only the name.

**Why.** A name built from the date says how fresh a build is at a glance, needs no manual edit, and always rises. The build number is a store detail with no meaning to users.

**Consequences.** `pubspec.yaml`'s version is used only for local builds. `isNewerVersion` compares names part by part, so `26.10.220` ranks above the old `0.x` names. Stored What's new notes keep their "(build)" header; the app hides it.

## 2026-10-17 — The server knows the app language

**Decision.** `profiles.app_language` (`en`/`tr`, nullable) holds the language the app shows (the in-app Settings choice, or the phone's when set to System), not the phone language. The app writes it at start and when it changes. SIS Destek's automatic first line (1:1 and group) uses it; unknown means Turkish. A group line is English only when every other active member has `en`. A line already sent is never resent. Lines Discuss writes by hand are untouched.

**Why.** The bot cannot guess a person's language; the app knows it.

**Consequences.** New stored data per person (one two-letter code, readable only by the server); it must be added to the store privacy notice, which lives outside this repo. What's new notes carry both languages (`For users:` and `For users (TR):`).

## 2026-10-20 — Private Chats step 4a: one-to-one text is locked

**Decision.** A text between two human members is Olm-locked on the sender's phone. The locked JSON is `{v,i,t,lp}`; `i` is the message id and the receiver rejects a locked text whose id differs from its row. The server stores it in two new nullable columns, `ciphertext` and `olm_type`, with `body` fixed to the placeholder `🔒 Encrypted message`. Each member has one phone: the sender's own copy is the plain text kept on that phone, and own rows are never decrypted. A session and the plain text are saved in one transaction. Each peer has one serial decrypt queue, and only an authentication failure is final. Edits go through `edit_message_encrypted`. Notifications show a fixed "🔒 New message" with the sender's name and no Reply button until step 4b.

**Why.** The server, Supabase, Google and Apple must not be able to read one-to-one texts; this is step 4 of the Private Chats plan of 2026-10-13.

**Consequences.**
- Places, polls, contacts, media and stickers stay plain until step 6, and the first message of a chat can go out plain until step 7.
- Notifications show no text and no Reply button until step 4b.
- 4a and 4b ship together (owner, 2026-10-19), so nothing reaches main or testers before 4b.
- The send queue now lives in the encrypted on-phone store, with the ciphertext of locked texts.
- Once a chat has held a locked message the server refuses plain inserts and notification replies into it, so a chat never goes back to plain.

## 2026-10-20 — iPhone encryption is exempt; Info.plist stays NO

**Decision.** `ios/Runner/Info.plist` keeps `ITSAppUsesNonExemptEncryption = false`, and the release tool sends no per-build encryption answer. The change that set it to `true` (#213) is reverted.

**Why.** App Store Connect's App Encryption Documentation questionnaire (answered 2026-10-20: standard algorithms only, none proprietary, not offered in France) returned "you don't need to upload any documents" and pointed to the Info.plist key for skipping the per-build questions. The earlier `true` came from reading Apple's documentation table instead of running the questionnaire; with `true` and no compliance code every upload failed with altool error 90592.

**Consequences.** iPhone uploads work again with no manual step. A store or build setting that depends on a legal reading is changed only after the platform's own form gives the answer. The US yearly self-classification question (5D992) is separate and open with a lawyer; it does not change this key.
