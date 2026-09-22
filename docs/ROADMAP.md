# Roadmap

Source of truth: [DESIGN.md §9](DESIGN.md).

| Version | Delivers | Done when |
|---|---|---|
| v0.1 | Google sign-in, allowlist gate, home screen, update policy, **full pipeline** | A merged change reaches a phone through Play with no cable |
| v0.2 | 1:1 text chat with Realtime | Two devices exchange messages; one remote update has landed — first stable version |
| v0.3 | Groups; display names | Group of three chats |
| v0.4 | Live chat list; tags and first-run name screen; settings; online and typing status | A new member picks a name and tag, and two members see each other online and typing |
| later | Push, media, iOS, E2EE | scheduled individually |

## Status

| Version | Status |
|---|---|
| v0.1 | **done** 2026-09-21 — build 103 on the Play internal track; sign-in, allowlist and single-active-device verified on a Play-installed device; a merged change reached the device with no cable |
| v0.2 | **done** 2026-09-22 — 1:1 chat with Realtime on the internal track; history survives a phone change and only one phone stays active, both proven by test. Two real devices exchanged messages and photos on 2026-09-23. |
| v0.3 | **done** 2026-09-22 — group conversations and member-editable display names |
| v0.4 | in progress — live chat list; tags, first-run name screen, settings |
| later | in progress — image attachments shipped as a demo; push has its database half, and needs a Firebase project before it can send (docs/DELIVERY.md) |
