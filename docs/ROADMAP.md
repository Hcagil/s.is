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
| v0.7 | User and group profile pages; tappable links; full-screen photo viewer | Tapping a 1:1 chat title or a group member opens their profile |
| v0.8 | Push notifications; lock-screen preview choice; mute a person or a chat (8 h / 1 week / always); a global switch | A message arrives as a notification on a closed app |
| v0.9 | Own media sheet and fast media | A photo appears at once for the sender and as a blurred preview first for receivers |
| v0.10 | Message actions by long press: delete for everyone (within 6 h; under 1 h it vanishes), reply, forward to several chats | A reply shows its quote; a deleted message is gone for everyone |
| v0.11 | Read status (mutual, like last seen; group "read by"); 1:1 header says just "typing…" | Your message turns from grey to normal when it is read |
| v0.12 | One SIS notification grouping every chat, expandable like Telegram | Several messages from several chats arrive as one expandable notification |
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
| v0.7 | **done** 2026-09-24 — tappable links and a full-screen photo viewer (#23); person and group profile pages with shared media and links |
| v0.8 | **done** 2026-09-24 — notification settings, mutes and the sender (#27); the app's push client (#28); Notifications settings page and mute on person and group pages |
| v0.9 | **done** 2026-09-24 — photos load once, yours appear at once, blurred previews first (#31); attachment sheet with the phone's own photos |
| later | in progress — image attachments shipped as a demo; push has its database half, and needs a Firebase project before it can send (docs/DELIVERY.md) |
