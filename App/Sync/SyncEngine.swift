import Foundation
import Combine

// Trigger-driven command engine. There is NO background loop: the app
// costs zero CPU between triggers. Every trigger either issues a direct
// order (mute/unmute/PTT — no state read at all) or performs ONE
// reconciliation read (toggle, menu open) and acts on what it learned.
//
// External state changes (muting from inside Slack/Meet directly) are
// picked up at the next trigger, not before. Instant push-style sync is
// the Chrome-extension bridge's job, not polling's.

final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    // Posted when a command settles on a session (HUD/sound).
    // userInfo["state"] = MicState, userInfo["kind"] = SessionKind.
    static let micStateDidChange = Notification.Name("MicStateDidChange")

    // Last reconciliation read; the menu is built from this.
    @Published var snapshots: [SessionKind: SessionSnapshot] = [:]

    // The goal the app last accepted. Set the moment a command runs;
    // cleared by reconciliation when no session is live.
    @Published var desiredState: MicGoal?

    let adapters: [SessionKind: SessionAdapter]

    // Internal: SyncEngine+Reconciliation.swift delivers on this queue.
    let queue = DispatchQueue(label: "com.yurifrl.micsync.engine", qos: .userInitiated)
    private var working = false       // one operation at a time
    private var pendingGoal: MicGoal? // latest command wins — keeps a PTT release alive
    private var lastPosted: [SessionKind: MicState] = [:]

    private init() {
        adapters = [
            .meet: MeetBridge(),
            .slack: SlackAdapter(),
        ]
    }

    // ----------------------------------------------------------
    // Triggers
    // ----------------------------------------------------------

    // Direct orders: applied without reading any state.
    // `ack` fires once the command settles on the engine queue (or
    // immediately when the engine is busy and the command is coalesced
    // into the pending goal). nil keeps the plain trigger behavior —
    // the keyboard shortcuts pass nothing.
    func mute(ack: ((Bool) -> Void)? = nil) {
        command(.mute)
        run(.muted, ack)
    }

    func unmute(ack: ((Bool) -> Void)? = nil) {
        command(.unmute)
        run(.live, ack)
    }

    // Push-to-talk: hold = live, release always ends muted.
    func pushToTalk(down: Bool, ack: ((Bool) -> Void)? = nil) {
        command(.pushToTalk)
        down ? run(.live, ack) : run(.muted, ack)
    }

    // The one state-needing command: a single reconciliation read
    // decides the flip, and the SAME read's live-session set receives
    // the goal — one read round, then label-directed presses.
    func toggle(ack: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !working else {
                ack?(false) // busy: the click was a no-op
                return
            }
            working = true
            command(.toggle)
            reconcileRead { [weak self] table in
                guard let self else { return }
                let live = SessionKind.allCases.filter { table[$0]?.inCall == true }
                guard let first = live.first,
                      let snap = table[first],
                      let goal = MicGoal(from: snap.state.flipped) else {
                    working = false // nothing live, or undecidable state: no guess
                    Log.warn(.engine, .toggleUndecidable, live.isEmpty ? "no live session" : "mic state undecidable")
                    ack?(false)
                    return
                }
                apply(goal, to: live) { [weak self] in
                    self?.working = false
                    ack?(true)
                }
            }
        }
    }

    // Menu-open reconciliation: one read round refreshes the snapshot
    // table; a goal whose sessions have all ended is dropped.
    func reconcile() {
        queue.async { [weak self] in
            guard let self, !working else { return }
            working = true
            command(.reconcile)
            reconcileRead { [weak self] _ in
                self?.working = false
            }
        }
    }

    // ----------------------------------------------------------
    // Command plumbing (engine queue only)
    // ----------------------------------------------------------

    private func run(_ goal: MicGoal, _ ack: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if working {
                pendingGoal = goal
                Log.debug(.engine, .busyDrop, "queued latest command; engine busy")
                // The superseded command is a no-op; the coalesced goal
                // still runs and reports through ITS ack.
                ack?(false)
                return
            }
            working = true
            applyGoal(goal, ack)
        }
    }

    // Command entry: one info line + one countable metric per accepted
    // command (the busy-drop line is its counterpart when queued).
    private func command(_ name: CommandName) {
        Log.info(.engine, .command(name), "accepted")
    }

    private func applyGoal(_ goal: MicGoal, _ ack: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async { self.desiredState = goal }
        // Direct order: every adapter self-decides from its control's
        // own label; nothing is read first, nothing verified after.
        apply(goal, to: SessionKind.allCases) { [weak self] in
            guard let self else { return }
            if let next = pendingGoal {
                pendingGoal = nil
                applyGoal(next)
                // Superseded: this goal never reached every adapter.
                ack?(false)
            } else {
                working = false
                ack?(true)
            }
        }
    }

    // One probe round lives in SyncEngine+Reconciliation.swift.

    // Apply a goal to the given kinds in parallel; cb fires on the
    // engine queue once every adapter has answered.
    private func apply(_ goal: MicGoal, to kinds: [SessionKind], cb: @escaping () -> Void) {
        let group = DispatchGroup()
        for kind in kinds {
            guard let adapter = adapters[kind] else { continue }
            group.enter()
            adapter.apply(goal) { [weak self] ok in
                guard let self else { group.leave(); return }
                self.queue.async {
                    if ok { self.postSettled(state: goal.state, kind: kind) }
                    group.leave()
                }
            }
        }
        group.notify(queue: queue, execute: cb)
    }

    private func postSettled(state: MicState, kind: SessionKind) {
        guard lastPosted[kind] != state else { return } // debounce
        lastPosted[kind] = state
        Log.info(.engine, .transition(kind, state), "posted \(kind.rawValue)=\(state.rawValue)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.micStateDidChange,
                object: nil,
                userInfo: ["state": state, "kind": kind]
            )
        }
    }
}
