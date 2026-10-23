import Foundation

// Shared contracts for mic control and cross-app sync.
//
// Model: trigger-driven, goal-directed. NOTHING polls. A command is a
// direct order — adapters decide from the control's own label (or an
// in-page need-check) whether pressing produces the goal, and the press
// IS the effect: no verification reads. State is read only when a
// command cannot be expressed without it: `toggle`, and menu-open
// reconciliation.

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

// An actionable order — total, never ambiguous. A command that cannot be
// decided from a control's label fails instead of guessing.
enum MicGoal {
    case live
    case muted

    var state: MicState { self == .live ? .live : .muted }

    // nil for .unknown: an unknown state is not a goal, it is a refusal.
    init?(from state: MicState) {
        switch state {
        case .live: self = .live
        case .muted: self = .muted
        case .unknown: return nil
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
}

// One per target app. All methods run their slow work (AppleScript
// subprocess / AX tree walk) off the main run loop and call back
// exactly once.
protocol SessionAdapter: AnyObject {
    var kind: SessionKind { get }

    // Direct order. The adapter decides from the control's own function
    // whether to press: a control whose press produces `goal` is
    // pressed; a control showing the goal already holds is a no-op
    // success. cb(false) = no live session, app not running, or no
    // decidable control — never a guess, never a verification read.
    func apply(_ goal: MicGoal, cb: @escaping (Bool) -> Void)

    // Single-shot read; the ONLY state query. Used by toggle and
    // menu-open reconciliation, never on a timer.
    // nil = app not running or probe failed.
    func probe(_ cb: @escaping (SessionSnapshot?) -> Void)
}
