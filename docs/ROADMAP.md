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
| v0.15 | **done** 2026-09-26 — the time sits on a message's last line when it fits; the whole chat header opens the profile, with the avatar; gallery newest first (0.14.2); bubbles hug their text, offline in about a second, fast previews (0.14.1) |
| v0.16 | **done** 2026-09-27 — message search in the chat list and inside a chat, over all history: highlight, ↑↓ between hits, jump to old messages; a search needs three letters or digits |
| v0.16.1 | **done** 2026-09-27 — the signed-in user is checked once per query in every policy; message reads bounded by membership (history read 5× faster) |
| v0.17 | **done** 2026-09-27 — change your profile picture and a group's picture; shown everywhere the initials circle was |
| v0.17.1 | **done** 2026-09-27 — the photo grid scrolls back past the newest 60 photos (attachments and picture picker) |
| v0.18 | **done** 2026-09-27 — search inside a chat answers instantly from the phone; the server is asked only for older hits |
| v0.18.1 | **done** 2026-09-27 — reloading the photo grid ("Allow more") never mixes in an old page or leaves it stuck loading |
| v0.18.2 | a person's profile page shows their picture, including one set or changed during the session |
| v0.19 | pick photos through a gallery app of your choice, for attachments and for profile and group pictures |
| v0.20 | pictures like WhatsApp: choose the square on a crop screen; tap a picture to see it full screen |
| v0.21 | swipe a message right to open its actions in a row above it; long press no longer used |
| v0.21.1 | after a swipe the message springs back to its place; the action row stays above it |
| v0.21.2 | a text message appears the moment you tap send |
| v0.21.3 | unsent text stays in each chat's write box; each chat sends through its own queue |
| v0.21.4 | the app opens faster: start-up requests run side by side |
| v0.21.5 | the licences page shows each licence as written (centred lines, indents) |
| v0.22 | contacts; new chat shows your people and finds others by exact tag; who sees your picture: everyone, contacts, nobody |
| v0.23 | leave a group, admins remove and add members (with or without old messages) |
| v0.24 | the chat list appears the moment SIS opens, from the phone, then refreshes |
| v0.25 | iOS: the app builds for iPhone (CI), signs in with Google, and does what the Android app does — updates, push, photo picking and crop; then every release also goes to TestFlight |
| v0.27 | "What's new" messages from SIS in a read-only system chat, delivered when the app updates |
| v0.28 | **done** 2026-09-30 — push notifications on iPhone |
| v0.29 | **done** 2026-09-30 — photo picking and the square crop on iPhone |
| v0.30 | **done** 2026-09-30 — every release also goes to TestFlight; builds reach the tester groups by themselves |
| v0.30.1 | a failed sign-in shows a plain sentence, never the raw error |
| v0.30.2 | iPhone: the keyboard stays open after sending; the tag box stays above the keyboard in a new chat |
| v0.30.3 | backing out of the crop returns to the same place in the photo grid |
| v0.30.4 | notifications: bursts arrive at once and show more lines per chat; the sender's picture on Android; iPhone clears a chat's notifications once it is read |
| v0.30.5 | iPhone: the read mark always reaches the sender |
| Update 1 | **Update 1** (version name as written in pubspec.yaml; the build number rises) — one combined release of the approved full design: appearance and text size, the new chat list, tap and long-press on messages (reactions, Seen by), group info, notifications drawn by the phone (bursts, sender pictures, Reply only when unlocked), the SIS Bot, and every screen in Turkish. Later rows keep their order and are renumbered after v1.0 |
| v0.31 | Sign in with Apple on iPhone (a hidden Apple email is refused; the same email is one account) |
| v0.32 | "What's new" v2: sent to everyone when an update is available, with an "Update now" button; a redesigned SIS chat |
| v0.33 | group chats show the sender's picture beside the last bubble of a run |
| v0.33.1 | maintenance: flaky tests, small fixes, workflow lint |
| v0.34 | iPhone checks the owner inside the notification and shows the sender's picture; sign-ins end after 30 days unused; drafts and the offline queue survive closing the app |
| v0.35 | photos in the offline queue; reopening a chat keeps its place, with a button to the first unread message; cleanup of storage left by deleted accounts |
| v0.36 | find SIS members from the phone's contacts |
| v0.37 | pin a message for everyone in the chat (a group setting decides who may pin); pin up to 5 chats on the list |
| v0.38 | react to a message with an emoji by long press |
| after v0.36 | plan end-to-end encryption |
| later | voice-to-write; public App Store release |
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
| v0.10 | **done** 2026-09-24 — delete for everyone (#33); reply and forward to several chats |
| v0.11 | **done** 2026-09-25 — read status, mutual like last seen: your message has a yellow edge until read (0.11.1; a group message counts as read once anyone has read it), normal once read; groups show who read it; reads made while sharing is off stay hidden; 1:1 header says just "typing…" |
| v0.12 | **done** 2026-09-25 — one SIS notification grouping every chat, expandable like Telegram; opening a chat clears its notification; older builds keep regular notifications; nothing of a previous member survives on the phone |
| v0.13 | **done** 2026-09-25 — edit your own message or photo caption for 6 hours; "edited" next to the time; no history; each bubble shows its time |
| v0.14 | **done** 2026-09-25 — everything visible is SIS's own design: notice pill, logo loader, SIS switches and choices, SIS licences page; no Android photo picker; permissions asked once behind SIS screens |
| later | in progress — image attachments shipped as a demo; push has its database half, and needs a Firebase project before it can send (docs/DELIVERY.md) |

- Cleanup job: remove stored pictures and attachments of deleted or delisted
  accounts, and uploads orphaned by a network failure (security review
  2026-09-27; unreadable, only storage).
- Leave a group / remove a member: does not exist yet. It is needed before any
  on-phone message store, so that a left chat's messages are purged (local
  search design, 2026-09-27).
