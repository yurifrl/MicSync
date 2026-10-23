import Foundation
import Combine

// Owns the single desired mic state and forces it on every live session.
// The probe loop runs on a background queue; all AppleScript/AX work lives
// inside the adapters, which are also fully asynchronous, so nothing here
// can block the main run loop.

final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    // Posted whenever the enforced state settles on a session (HUD/sound).
    // userInfo["state"] = MicState, userInfo["kind"] = SessionKind.
    static let micStateDidChange = Notification.Name("MicStateDidChange")

    private let probeInterval: TimeInterval = 2.0
    private let nodeBudget = 4000 // Slack AX walk cap; engine only passes intent through.

    @Published var snapshots: [SessionKind: SessionSnapshot] = [:]
    // nil = no live session to hold a state for.
    @Published var desiredState: MicState?

    let adapters: [SessionKind: SessionAdapter]

    private let queue = DispatchQueue(label: "com.yurifrl.micsync.engine", qos: .userInitiated)
    private var probeTimer: DispatchSourceTimer?
    private var probing = false
    private var enforcing = false
    private var lastPosted: [SessionKind: MicState] = [:]

    private init() {
        adapters = [
            .meet: MeetAdapter(),
            .slack: SlackAdapter(),
        ]
        startProbeLoop()
    }

    // ----------------------------------------------------------
    // Public controls
    // ----------------------------------------------------------

    // Flip the mic of the first live session; the resulting desired state
    // is then enforced on every live session (mute once, all follow).
    func toggle() {
        queue.async { [weak self] in
            guard let self else { return }
            let current = actionTargets().compactMap { kind -> MicState? in
                let state = self.snapshots[kind]?.state
                return (state == .live || state == .muted) ? state : nil
            }
            guard let state = current.first else { return }
            desiredState = state.flipped
            enforce()
        }
    }

    func mute() {
        queue.async { [weak self] in
            guard let self else { return }
            desiredState = .muted
            enforce()
        }
    }

    func unmute() {
        queue.async { [weak self] in
            guard let self else { return }
            desiredState = .live
            enforce()
        }
    }

    // Push-to-talk: while held the mic is live; release always ends muted.
    func pushToTalk(down: Bool) {
        down ? unmute() : mute()
    }

    // ----------------------------------------------------------
    // Probe loop (background queue, 2s)
    // ----------------------------------------------------------

    private func startProbeLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + probeInterval, repeating: probeInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        probeTimer = timer
        // First sweep immediately.
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        guard !probing else { return }
        probing = true

        let group = DispatchGroup()
        var observed: [SessionKind: SessionSnapshot] = [:]
        let lock = NSLock()

        for (kind, adapter) in adapters {
            group.enter()
            adapter.probe { snapshot in
                if let snapshot {
                    lock.lock()
                    observed[kind] = snapshot
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            probing = false
            DispatchQueue.main.async { self.snapshots = observed }

            // Session ended while a desired state was held -> drop it.
            if desiredState != nil, actionTargets(in: observed).isEmpty {
                DispatchQueue.main.async { self.desiredState = nil }
                return
            }

            // Self-healing: a session whose observed state drifted from the
            // desired state gets re-enforced on the next tick.
            enforce(in: observed)
        }
    }

    // ----------------------------------------------------------
    // Enforcement
    // ----------------------------------------------------------

    // Sessions that should currently be driven to the desired state:
    // every live session — mute once, all follow.
    private func actionTargets(in pool: [SessionKind: SessionSnapshot]? = nil) -> [SessionKind] {
        let table = pool ?? snapshots
        return SessionKind.allCases.filter { table[$0]?.inCall == true }
    }

    // Idempotent: adapters only press when their observed state differs.
    private func enforce(in pool: [SessionKind: SessionSnapshot]? = nil) {
        guard let desired = desiredState, !enforcing else { return }
        let targets = actionTargets(in: pool)
        guard !targets.isEmpty else { return }

        enforcing = true
        let group = DispatchGroup()

        for kind in targets {
            guard let adapter = adapters[kind],
                  let snap = (pool ?? snapshots)[kind] else { continue }
            if snap.state == desired {
                // Already settled — announce (debounced by lastPosted).
                postSettled(state: desired, kind: kind)
                continue
            }
            group.enter()
            adapter.set(desired) { ok in
                self.queue.async {
                    if ok { self.postSettled(state: desired, kind: kind) }
                    group.leave()
                }
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.enforcing = false
        }
    }

    private func postSettled(state: MicState, kind: SessionKind) {
        guard lastPosted[kind] != state else { return } // debounce: no change, no post
        lastPosted[kind] = state
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.micStateDidChange,
                object: nil,
                userInfo: ["state": state, "kind": kind]
            )
        }
    }

}
