import Foundation

// Diagnostics vocabulary shared by producers and the console.
//
// Producers call the `Log` facade with a category, an optional metric and
// a message. Everything is immutable data: entries are created once by
// whichever thread/queue produced them, stored verbatim by LogStore, and
// rendered or aggregated by the console. No string parsing anywhere —
// metrics are enum-tagged payloads the stats pane can count structurally.

enum LogLevel: String, CaseIterable, Comparable {
    case debug
    case info
    case warn
    case error

    var symbol: String {
        switch self {
        case .debug: return "···"
        case .info: return "   "
        case .warn: return "⚠ "
        case .error: return "✗ "
        }
    }

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum LogCategory: String, CaseIterable {
    case app
    case engine
    case meet
    case slack
    case ui
    case remote

    var label: String {
        switch self {
        case .app: return "app"
        case .engine: return "engine"
        case .meet: return "meet"
        case .slack: return "slack"
        case .ui: return "ui"
        case .remote: return "remote"
        }
    }
}

// A command accepted by the engine (matches SyncEngine's trigger set).
enum CommandName: String, CaseIterable {
    case mute
    case unmute
    case toggle
    case pushToTalk
    case reconcile
}

// The two adapter operations that can be timed/counted.
enum AdapterOp: String {
    case probe
    case apply
}

// Structurally countable events. The console's stats pane folds these
// out of the captured buffer — the log line and the counter can never
// drift apart because they are the same record.
enum LogMetric {
    // Command accepted (value = which trigger).
    case command(CommandName)
    // Command dropped because the engine was busy.
    case busyDrop
    // Reconciliation read completed (nil adapter answers / live count kept
    // in the message, not here — this stays countable and cheap).
    case probeRound
    // Toggle found nothing actionable (no live session or undecidable).
    case toggleUndecidable
    // Goal settled on one session: the state posted to the UI.
    case transition(SessionKind, MicState)
    // One adapter operation finished: outcome + duration.
    case adapterResult(SessionKind, AdapterOp, ok: Bool, durationMs: Int)
    // Meet control unreachable although Chrome is running (posted once
    // per session; resets when the extension says hello).
    case setupIssue

    var label: String {
        switch self {
        case .command(let name): return "command \(name.rawValue)"
        case .busyDrop: return "busy-drop"
        case .probeRound: return "probe round"
        case .toggleUndecidable: return "toggle undecidable"
        case .transition(let kind, let state): return "posted \(kind.rawValue)=\(state.rawValue)"
        case .adapterResult(let kind, let op, let ok, let ms):
            let mark = ok ? "ok" : "fail"
            return "\(kind.rawValue) \(op.rawValue) \(mark) \(ms)ms"
        case .setupIssue: return "meet setup issue"
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id: Int
    let time: Date
    let level: LogLevel
    let category: LogCategory
    let metric: LogMetric?
    let message: String

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// Facade every producer calls. Cheap by construction: disabled capture is
// one bool check per call (LogStore._append rejects immediately); enabled
// capture is one timestamped struct append into the ring. Producers never
// touch the store, the lock, or main-thread dispatch.
enum Log {
    static func debug(_ category: LogCategory, _ metric: LogMetric? = nil, _ message: String) {
        LogStore.shared.append(.debug, category, metric, message)
    }

    static func info(_ category: LogCategory, _ metric: LogMetric? = nil, _ message: String) {
        LogStore.shared.append(.info, category, metric, message)
    }

    static func warn(_ category: LogCategory, _ metric: LogMetric? = nil, _ message: String) {
        LogStore.shared.append(.warn, category, metric, message)
    }

    static func error(_ category: LogCategory, _ metric: LogMetric? = nil, _ message: String) {
        LogStore.shared.append(.error, category, metric, message)
    }
}

// Wall-clock milliseconds since `start`, the single source of the
// durations reported in adapterResult metrics.
enum Timing {
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
