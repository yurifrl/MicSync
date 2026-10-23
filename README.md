# MicSync

Menu-bar app that keeps your microphone state in sync across **Google Meet (Chrome)** and **Slack (desktop app)**. Toggle once, both follow. It detects live sessions, shows the state in the menu bar, and enforces one desired state everywhere.

> Status bar shows 🎙 live / 🔇 muted / ❔ unknown. Left-click toggles; right-click (or option-click) opens the menu.

## What it does

- **Session detection** — event-driven, zero polling between triggers:
  - **Google Meet** — via the bundled Chrome extension (`micsync-chrome-extension/`); it connects to the app's local WebSocket server (`ws://127.0.0.1:8895/ws`) and drives the Meet tab directly. Load it once from `chrome://extensions` → *Load unpacked*.
  - **Slack** — live huddle in the desktop app; reads/presses the mic button through the Accessibility tree.
- **Sync engine** — holds ONE desired state and enforces it on every live session; if an app drifts (self-mute, page reload), the next tick corrects it.
- **Push-to-talk** — hold shortcut/gamepad button to go live; release always ends muted.
- **HUD popup** — brief Hammerspoon-style overlay on every state change (optional).
- **Gamepad support** — 8BitDo pads etc. drive the same actions directly (GameController.framework); defaults: A=toggle, B=push-to-talk (hold), X=mute, Y=unmute, select=switch target. Rebindable via `defaults write com.yurifrl.micsync pad.<button> <action>` with action ∈ toggle|mute|unmute|ptt|switch.

## Shortcuts

All five (toggle, mute, unmute, push-to-talk, switch target) are recorded in Settings → Shortcuts with the standard "click, then press the combo" recorder. Unassigned shortcuts stay inert. Bare numpad digits (0–9) are valid shortcuts — once recorded, the digit is consumed system-wide and never reaches the frontmost app.

[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) is vendored at `vendor/KeyboardShortcuts` (3.1.0) rather than fetched: the recorder's event monitor is patched (`RecorderCocoa.swift`) to accept bare numpad digits and to never swallow mouse-ups, so the clear (✕) button works while recording. Don't swap it back to the remote package without a release that fixes both.

## Phone control (LAN remote)

Enable Settings → *Remote control* to open a token-gated listener on `0.0.0.0:8896` (`RemoteListener.swift`, advertised via Bonjour as `_micsync._tcp`). It feeds the **same trigger engine** the shortcuts use — a phone command mutes Meet, Slack, and any other live session exactly like a keypress. The Settings pane shows a pairing QR: `http://<hostname>.local:8896/#<token>`.

- Endpoints: `GET /status`, `GET /mute|/unmute|/toggle` (409 on no-op), `GET /ptt/1|/ptt/0`; every request needs the token (`Authorization: Bearer` or `?token=`, else 403).
- `WS /ws?token=…` pushes the `/status` frame on connect and after every engine change (no polling).
- Pair once from the phone (QR or paste the URL); the token persists in `defaults` (`remoteEnabled`, `remoteToken`) until regenerated in Settings.

## Requirements

- macOS 13+
- Accessibility permission (Slack huddle control)
- The bundled Chrome extension loaded once (Chrome ▸ `chrome://extensions` ▸ Developer mode ▸ *Load unpacked* ▸ select `micsync-chrome-extension/`)

## Build

```sh
xcodegen generate
xcodebuild build -project MicSync.xcodeproj -scheme MicSync -configuration Release
```

## Release

Push a `v*` tag — GitHub Actions builds, Developer-ID-signs, notarizes, staples, wraps a DMG, and publishes the release. Configure repo **variable** `DEVELOPER_ID_APPLICATION` and **secrets** `MACOS_SIGNING_P12_BASE64`, `MACOS_SIGNING_P12_PASSWORD`, `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`.

Push an `extension-v*` tag (e.g. `extension-v0.1.0`, must match `micsync-chrome-extension/manifest.json`'s `version`) — GitHub Actions validates the extension, zips it, and attaches the zip + SHA-256 checksums to a GitHub Release.
