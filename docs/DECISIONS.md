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
