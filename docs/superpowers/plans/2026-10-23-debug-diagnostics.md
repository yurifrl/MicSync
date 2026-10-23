# Debug diagnostics + console (approved design, implementation plan)

Session-scoped debug console in settings; gated in-memory logging; focused refactor.

## Tasks

1. **Diagnostics core** — `App/Diagnostics/Log.swift` (LogLevel/LogCategory/LogEntry/LogMetric/CommandName/AdapterOp + `Log` facade), `LogStore.swift` (NSLock gate, 1000-entry buffer, cleared on disable, coalesced 0.25s main-queue publish, `clear()`), `DiagnosticsStats.swift` (pure fold over entries).
2. **Console** — `DebugConsoleController.swift` (nonactivating NSPanel, windowWillClose → onClose), `DebugConsoleView.swift` (state header from SyncEngine, stats pane, lazy List stream, pause/clear/level filter, autoscroll).
3. **Settings wiring** — `SettingsViewModel.swift` extracted; `debugMode` session-scoped (not in Preferences); `onDebugModeChange` closure; toggle in Behavior section; AppDelegate owns panel, single choke point sets `LogStore.isEnabled`.
4. **Refactor** — `AppleScriptRunner.swift` (subprocess plumbing + duration out of MeetAdapter), `MeetScripts.swift` (JS/AppleScript constants), `AXTree.swift` (axString/axChildren/Budget/axFind/roots/appElement out of SlackAdapter), `SyncEngine+Reconciliation.swift` (reconcileRead out; `queue` becomes internal for the extension).
5. **Instrumentation** — engine: command entry/busy-queue/drop/toggle-undecidable/posted transitions/probe rounds; Meet: per-run duration, probe/apply outcomes, frozen recovery, setup issue; Slack: walk duration, apply/probe outcomes, permission issue; App: launch line. Every completed adapter op emits exactly one `adapterResult` metric.
6. **Verify** — `xcodegen generate` + `xcodebuild` Debug build; live smoke: launch, open settings, toggle debug console, run toggles, observe stream + stats, close → capture stops.

## Invariants
- `Log.*` calls are near-free when console closed (single guarded append).
- One store, one pipeline; stats are an aggregation over the buffer (no second source).
- Session-scoped: no persistence, cleared on disable; `nextID` monotonic forever.
- Behavior untouched elsewhere: HUDPanel, GamePadMonitor, SoundCue, StatusBarController, Contracts.
- No commits (user has uncommitted WIP in the same files).
