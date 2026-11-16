# GPT Live

A full-duplex voice assistant for Android and macOS. You talk to it, it answers from your knowledge base, runs long tasks in the background and **calls you back** when a result is ready.

Two modes, chosen by the **API | CLI** switch in the app (CLI is the default):

| | API | CLI |
|---|---|---|
| Voice | GPT-Live (`gpt-live-1`) over WebRTC | Codex realtime v3 over WebRTC |
| Backend "brain" | Responses API (`gpt-6-luna`) via native delegation | a persistent Codex thread (`codex app-server`) |
| Billing | OpenAI API key, ≈ $0.05/min + tokens | ChatGPT subscription of the backend machine |
| Background tasks | `enqueue_text_task` → server worker | Codex turns; finished turns ring the app |

## Quick start

Requirements: Node.js 22.13+, Flutter 3.44+, JDK 17 + Android SDK (Android), Xcode (macOS). CLI mode also needs codex CLI **0.162+** logged in with ChatGPT (`codex login`).

```sh
cd server
npm ci
cp .env.example .env    # set OPENAI_API_KEY (API mode) and DEV_CLIENT_TOKEN
npm start               # listens on 0.0.0.0:8789 by default
```

Generate a token with `node -e 'console.log(require("node:crypto").randomBytes(32).toString("base64url"))'`.

```sh
cd app
flutter pub get
flutter run -d <device>           # Android or macos
```

In the app open the connection settings and enter the server URL (`http://10.0.2.2:8789` on the Android emulator, `http://<LAN-IP>:8789` on a phone, `http://127.0.0.1:8789` on macOS) and the `DEV_CLIENT_TOKEN`. Never put the OpenAI key into the app.

## Features

- **Console UI**: LCD status display with timer, cost and level meters, speaker-grille visualiser, animated settings.
- **Voice picker**, switchable mid-call (the session is replaced, the conversation continues).
- **Knowledge base and instructions editors** in the app. Saving during a call applies immediately: API — `session.update` / `session.instructions.append`; CLI — `thread/realtime/appendText` for the voice and `thread/inject_items` for Codex.
- **Cost estimate** next to the timer (API) or Codex subscription limits (CLI); total spend in settings.
- **Per-session time limit** (default 5 min, 1–30).
- **Incoming call** when a background task finishes after you hung up; "Answer" starts a new session with the exact result (CLI: the same Codex thread).
- On desktop a call survives switching apps; on Android it ends when the app goes to the background.

## Knowledge base vs instructions

Both live in `server/config/` and are sent to the model as prompt text, not as files it looks up.

- `rules.md` — **how to behave** (role, style). Conversation sections go to the voice; everything goes to the backend.
- `data.txt` — **what to know** (facts). Only the backend / Codex receives it, wrapped as data, never as instructions. Limit 48 KB.

These two files are personal and **not tracked by git**. A fresh checkout creates them from `data.example.txt` and `rules.example.md`; the first in-app edit keeps a `*.default.*` copy.

## CLI mode notes

- Uses the experimental `thread/realtime/*` API of `codex app-server` (`experimentalApi`); it may change with Codex updates. Realtime v3 works over WebRTC only.
- Voice rules are passed as developer `initialItems` (v3 ignores `prompt`).
- The agent works in `CODEX_CWD` (default `server/codex-workspace`) with `CODEX_SANDBOX` (default `workspace-write`) and `approvalPolicy: never`; MCP servers from `~/.codex/config.toml` are available to it.
- Bridge code: `server/src/codex_bridge.js`.

## HTTP API

All requests need `Authorization: Bearer <DEV_CLIENT_TOKEN>` and `X-Client-ID`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | server status |
| POST | `/live/session` | `{sdp, conversation_id, mode?, voice?, max_seconds?, task_id?, replaces?}` → SDP answer |
| POST | `/live/:id/close` · `/live/:id/heartbeat` | close / keep alive (+ cost or limits) |
| GET · POST | `/tasks` · `/tasks/:id` | list, create, read background tasks |
| GET | `/knowledge` | knowledge base, instructions, voices, prices |
| POST | `/knowledge/data` · `/knowledge/rules` | save and apply to running calls |
| GET | `/usage` | spend estimate |
| WS | `/events` | task and live events |

## Reliability and limits

- State is stored in `server/storage/state.json` with atomic fsynced writes; one server per storage directory.
- After a restart queued tasks continue; interrupted running tasks are marked Failed (paid calls are never retried automatically).
- The shared dev token is meant for **one trusted client on a LAN**. Do not expose the server to the internet as is.
- Cost figures are estimates; check OpenAI billing and set spending limits.

## Builds and checks

```sh
cd server && npm test
cd app && flutter analyze && flutter test
cd app && flutter build apk --release
cd app && flutter build macos --release && python3 ../scripts/check_macos_release.py "build/macos/Build/Products/Release/GPT Live.app"
```

macOS WebRTC needs both `network.client` and `network.server` entitlements in Release builds; the check script verifies the signed bundle. The app icon is generated by `scripts/make_icon.py`.
