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
mode. Reason: minimise update prompts for users.

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
