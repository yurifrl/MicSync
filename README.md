# MicSync

Menu-bar app that keeps your microphone state in sync across **Google Meet (Chrome)** and **Slack (desktop app)**. Toggle once, both follow. It detects live sessions, shows the state in the menu bar, and enforces one desired state everywhere.

> Status bar shows 🎙 live / 🔇 muted / ❔ unknown, with a `(M)`/`(S)` suffix pinning the target when both sessions are live.

## What it does

- **Session detection** — polls every 2s:
  - **Google Meet** — any Chrome tab on `meet.google.com`; reads mic state via injected JS (needs *View ▸ Developer ▸ Allow JavaScript from Apple Events* enabled in Chrome).
  - **Slack** — live huddle in the desktop app; reads/presses the mic button through the Accessibility tree.
- **Sync engine** — holds ONE desired state and enforces it on every live session; if an app drifts (self-mute, page reload), the next tick corrects it.
- **Push-to-talk** — hold shortcut/gamepad button to go live; release always ends muted.
- **HUD popup** — brief Hammerspoon-style overlay on every state change (optional).
- **Gamepad support** — 8BitDo pads etc. drive the same actions directly (GameController.framework); defaults: A=toggle, B=push-to-talk (hold), X=mute, Y=unmute, select=switch target. Rebindable via `defaults write com.yurifrl.micsync pad.<button> <action>` with action ∈ toggle|mute|unmute|ptt|switch.

## Shortcuts

All five (toggle, mute, unmute, push-to-talk, switch target) are recorded in Settings → Shortcuts with the standard "click, then press the combo" recorder. Unassigned shortcuts stay inert.

## Requirements

- macOS 13+
- Accessibility permission (Slack huddle control)
- Automation permission for Chrome (Meet control)
- Chrome: *Allow JavaScript from Apple Events* (View ▸ Developer)

## Build

```sh
xcodegen generate
xcodebuild build -project MicSync.xcodeproj -scheme MicSync -configuration Release
```

## Release

Push a `v*` tag — GitHub Actions builds, Developer-ID-signs, notarizes, staples, wraps a DMG, and publishes the release. Configure repo **variable** `DEVELOPER_ID_APPLICATION` and **secrets** `MACOS_SIGNING_P12_BASE64`, `MACOS_SIGNING_P12_PASSWORD`, `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`.
