# MicSync Bridge — Chrome extension

Companion extension for MicSync. It connects to the app's WebSocket server and
executes mute / camera / leave / reaction / chat commands by driving the Google
Meet UI. The popup is just a connected / disconnected indicator (with the error
reason when disconnected).

Isolated from the rest of the repo — everything lives in this folder.

## Layout

| File | Role |
|---|---|
| `manifest.json` | MV3, `WebSocket` in service worker (Chrome ≥ 116) |
| `shared.js` | Frozen protocol constants: patterns, actions, endpoint |
| `background.js` | Service worker: owns the WS connection, reconnect/backoff, routes commands to Meet tabs, `bring-to-front` via tab APIs |
| `content/content.js` | Meet controller: DOM actions + status answers (aria-label based, locale tolerant en/pt/es) |
| `popup/` | Connected / disconnected indicator |

## Protocol (app ⇄ extension)

- URL (fixed constant): `ws://127.0.0.1:8895/ws` — set in `shared.js`.
- No authentication: the server is localhost-only, the endpoint is a constant.
- Extension → app (JSON lines):
  - `{ type: "hello", client: "chrome-extension", protocol: "1.0.0", app, version }` on connect
  - `{ type: "result", id, ok, ..., status? }` response to a command (`get-status` included)
  - `{ type: "ping" }` every 20 s while connected
- App → extension:
  - `{ action, value?, id }` — dispatched to all Meet tabs
  - `{ type: "status-request", id }` — shorthand for `get-status`
  - `{ type: "pong" }` ignored

`status` shape: `{ app: "google-meet", inCall, muted, cameraOn, handRaised, title }`
(`muted`/`cameraOn` are `null` when the control isn't visible).

## Supported actions

`get-status`, `toggle-mute`, `mute-on`, `mute-off`, `toggle-video`,
`video-on`, `video-off`, `leave`, `toggle-chat-window`, `react`
(value: `applause | laugh | like | love | wow | celebrate | sad | dislike |
thinking | raise-hand`), `bring-to-front` (handled natively by the service
worker, no tab access needed).

Results: `{ ok: true, status }` or `{ ok: false, error: "…", status }`
(`not-in-call`, `mic-button-not-found`, `camera-button-not-found`,
`leave-button-not-found`, `reactions-panel-not-found`, `reaction-label-not-found`, …).

## How it finds Meet controls

Buttons are matched by visible label / aria-label against locale-tolerant regexes
(`mic`, `camera`, `leave call` …), then verified/actuated via
`aria-pressed` / `aria-checked` state patterns. Status is pulled on demand
(`get-status`); the page itself is never modified — the content script runs in
the isolated world.

## Load for development

1. `chrome://extensions` → Developer mode → **Load unpacked** → select this folder.
2. Start MicSync (it serves `ws://127.0.0.1:8895/ws`); the popup turns green
   when connected.

## Notes

- MV3 service workers sleep; every inbound WS frame (incl. pings every 20 s while
  connected) resets the idle timer — no custom keep-alive needed on Chrome 116+.
- All host/identity data is local: no analytics, no external requests beyond
  `ws://127.0.0.1:8895/ws`.
