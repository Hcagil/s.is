# Roadmap

Source of truth: [DESIGN.md §9](DESIGN.md).

| Version | Delivers | Done when |
|---|---|---|
| v0.1 | Google sign-in, allowlist gate, home screen, update policy, **full pipeline** | A merged change reaches a phone through Play with no cable |
| v0.2 | 1:1 text chat with Realtime | Two devices exchange messages; one remote update has landed — first stable version |
| v0.3 | Groups; display names | Group of three chats |
| v0.4 | Live chat list; tags and first-run name screen; settings; online and typing status | A new member picks a name and tag, and two members see each other online and typing |
| v0.5 | Design foundation: shared Realtime join/teardown; the name (SIS = Stay In Sync); the Nocturne theme, Sync S logo, launcher icon, branded header | Every existing screen wears the design and the new icon is on the phone |
| v0.6 | Unread counts; sender names in groups; last seen (switchable, server-enforced); settings sub-pages | A member sees what is unread and who said what in a group |
| v0.7 | User and group profile pages | Tapping a chat title or a sender opens their profile |
| v0.8 | Push notifications; global, per-user and per-chat notification settings | A message arrives as a notification on a closed app |
| v0.9 | Own media sheet and fast media | A photo appears at once for the sender and as a blurred preview first for receivers |
| after v0.9 | iOS | scheduled after v0.9 |
| later | E2EE | scheduled individually |

## Status

| Version | Status |
|---|---|
| v0.1 | **done** 2026-09-21 — build 103 on the Play internal track; sign-in, allowlist and single-active-device verified on a Play-installed device; a merged change reached the device with no cable |
| v0.2 | **done** 2026-09-22 — 1:1 chat with Realtime on the internal track; history survives a phone change and only one phone stays active, both proven by test. Two real devices exchanged messages and photos on 2026-09-23. |
| v0.3 | **done** 2026-09-22 — group conversations and member-editable display names |
| v0.4 | **done** 2026-09-23 — live chat list; tags and a first-run name screen; settings; online and typing status with server-enforced sharing switches |
| v0.5 | **done** 2026-09-23 — shared Realtime join/teardown (#16); SIS = Stay In Sync; Nocturne design, Sync S logo and launcher icon (#17) |
| v0.6 | **done** 2026-09-23 — unread counts and sender names in groups (#18); last seen, mutual and server-enforced (#21); settings pages (#20) |
| later | in progress — image attachments shipped as a demo; push has its database half, and needs a Firebase project before it can send (docs/DELIVERY.md) |
