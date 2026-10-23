import Foundation

// Shared contracts for mic-state detection and cross-app sync.
// Every adapter reports a snapshot; the engine holds ONE desired state
// and forces every live session to it. "Force" is idempotent: adapters
// read the current state first and only press when it differs.

enum MicState: String {
    case live
    case muted
    case unknown

    var flipped: MicState {
        switch self {
        case .live: return .muted
        case .muted: return .live
        case .unknown: return .muted
        }
    }

    var label: String {
        switch self {
        case .live: return "Live"
        case .muted: return "Muted"
        case .unknown: return "Unknown"
        }
    }
}

enum SessionKind: String, CaseIterable {
    case meet
    case slack

    var displayName: String {
        switch self {
        case .meet: return "Google Meet"
        case .slack: return "Slack"
        }
    }
}

struct SessionSnapshot: Equatable {
    let kind: SessionKind
    let inCall: Bool
    let state: MicState

    static let none = { kind in SessionSnapshot(kind: kind, inCall: false, state: .unknown) }
}

// One per target app. probe/set MUST run off the main run loop internals
// (AppleScript subprocess / AX tree walk) and always call back exactly once.
protocol SessionAdapter: AnyObject {
    var kind: SessionKind { get }

    // nil snapshot = app not running or probe failed.
    func probe(_ cb: @escaping (SessionSnapshot?) -> Void)

    // Forces `desired`. cb(success) — false = no live session or action failed.
    func set(_ desired: MicState, cb: @escaping (Bool) -> Void)
}
