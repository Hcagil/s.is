# Development plan

Status: Docker configuration prepared; image build and application implementation pending.

| Stage | Deliverable | Validation |
| --- | --- | --- |
| 1. Environment | Docker build environment and mock chat screen | Analysis, tests, APK build, Android launch |
| 2. Identity | Accounts, profiles, schema, access policies | Login/recovery and unauthorized-access checks |
| 3. Direct chat | Send, conversation list, history, reconnect | Multiple accounts, retry deduplication, history recovery |
| 4. Groups | Create, membership management, departure | Roles, access revocation, history policy |
| 5. Android acceptance | Working core flows | Install, login, direct/group messaging, network interruption |
| 6. iOS | Native build and platform compatibility | iPhone checks and cross-platform messaging |
| 7. Pilot release | Installable builds and targeted improvements | Fresh installs and regression checks |

Finalize encryption before message persistence and group-history rules before group implementation. Store publication is a separate stage.
