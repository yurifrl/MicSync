import Foundation
import AppKit

// Meet backend: bridge to the bundled Chrome extension
// (micsync-chrome-extension/). Speaks the extension's wire protocol over a
// WebSocket server on 127.0.0.1:8895 — no AppleScript, no injected JS, no
// Chrome automation permission. The extension drives the Meet page DOM;
// this adapter only sends orders and reads status.
//
// Wire protocol (JSON over one WebSocket connection per Chrome):
//   in  { type: "hello", client, protocol-version, app, version }
//   in  { type: "ping" }                          → answered { type: "pong" }
//   in  { type: "result", id, ok, error?, status? }
//   out { type: "status-request", id }            → shorthand for get-status
//   out { action: "mute-on"|"mute-off", id }      → goal-directed commands
//
// Extension → SessionAdapter mapping:
//   probe  → status-request: ok + status.inCall → snapshot(muted ? .muted
//            : .live); ok + !inCall → (false, .unknown); error/timeout → nil
//   apply  → mute-on / mute-off: { ok: true } → true (the press is the
//            effect; no verification read), any error → false
//
// The WebSocket plumbing (listener, handshake, frames, buffers) lives in
// WSServerCore; this file owns only the extension protocol.

final class MeetBridge: SessionAdapter {
    let kind: SessionKind = .meet

    // Surfaced when Meet control is unreachable although Chrome is running
    // (the modern equivalent of the old AppleScript setup error).
    static let setupIssue = Notification.Name("MeetBridgeSetupIssue")

    // Must match MS.ENDPOINT in the extension (shared.js).
    private static let port: UInt16 = 8895
    private static let requestTimeout: TimeInterval = 5

    // ----------------------------------------------------------
    // Server state (queue-confined)
    // ----------------------------------------------------------
    private let queue = DispatchQueue(label: "com.yurifrl.micsync.meetbridge", qos: .userInitiated)
    private let core = WSServerCore(queue: DispatchQueue(label: "com.yurifrl.micsync.meetbridge.ws", qos: .userInitiated), singleConnection: true)
    private var setupIssuePosted = false
    // Queue-confined mirror of "the core holds a live connection" (any
    // handshake state). Identity-tracked: the drop of a replaced socket
    // must not clear the liveness of its successor.
    private var liveConnectionID: ObjectIdentifier?

    private enum Request {
        case status((Status?) -> Void)
        case command((Bool) -> Void)
    }

    struct Status {
        let inCall: Bool
        let muted: Bool? // nil = control not visible
    }

    private var pending: [String: Request] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var nextID = 0

    init() {
        wireCore()
        core.start(port: Self.port, reuse: true, loopback: true)
    }

    // Wire the shared WS core to this adapter's protocol. All callbacks
    // arrive on the core's queue; pending-request state stays confined to
    // MeetBridge's own queue and is touched only through it.
    private func wireCore() {
        core.onListenError = { [weak self] message in
            self?.queue.async {
                self?.postSetupIssue(
                    title: "Meet bridge failed to start",
                    message: message
                )
            }
        }
        // One connection at a time (enforced by the core's
        // singleConnection policy): a new extension socket replaces the
        // old one (Chrome reload, browser restart, second profile).
        core.onAccept = { [weak self] connection in
            let id = ObjectIdentifier(connection)
            self?.queue.async {
                self?.liveConnectionID = id
            }
        }
        core.onWSText = { [weak self] text, _ in
            guard let self else { return }
            self.queue.async {
                self.handleMessage(text)
            }
        }
        // Nothing pending can be answered anymore. A replaced socket's
        // late drop must not clear the successor's liveness.
        core.onDrop = { [weak self] connection in
            let id = ObjectIdentifier(connection)
            guard let self else { return }
            self.queue.async {
                guard self.liveConnectionID == id else { return }
                self.liveConnectionID = nil
                for (id, request) in self.pending {
                    self.fail(request, cbError: nil)
                    self.timeouts[id]?.cancel()
                }
                self.pending.removeAll()
                self.timeouts.removeAll()
            }
        }
    }

    // ----------------------------------------------------------
    // SessionAdapter
    // ----------------------------------------------------------

    // Single-shot read; the ONLY state query.
    func probe(_ cb: @escaping (SessionSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.liveConnectionID != nil else {
                self?.maybePostSetupIssue()
                return cb(nil)
            }
            let id = self.newID()
            let start = DispatchTime.now()
            self.pending[id] = .status { status in
                Log.debug(.meet, .adapterResult(.meet, .probe, ok: status != nil, durationMs: Timing.ms(since: start)), status == nil ? "no answer from extension" : "answered")
                guard let status, status.inCall else {
                    // No Meet tab / landing page: no live session to report.
                    return cb(status == nil ? nil : SessionSnapshot(kind: .meet, inCall: false, state: .unknown))
                }
                cb(SessionSnapshot(kind: .meet, inCall: true, state: status.muted == true ? .muted : .live))
            }
            self.send(id: id, ["type": "status-request", "id": id])
            self.armTimeout(id)
        }
    }

    // Direct order; cb(true) means the press happened (or the goal already
    // held). cb(false) = no extension connection, no Meet tab, or no
    // decidable control.
    func apply(_ goal: MicGoal, cb: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.liveConnectionID != nil else {
                self?.maybePostSetupIssue()
                return cb(false)
            }
            let id = self.newID()
            let start = DispatchTime.now()
            self.pending[id] = .command { ok in
                Log.debug(.meet, .adapterResult(.meet, .apply, ok: ok, durationMs: Timing.ms(since: start)), ok ? "pressed" : "not applied")
                cb(ok)
            }
            self.send(id: id, ["action": goal == .live ? "mute-off" : "mute-on", "id": id])
            self.armTimeout(id)
        }
    }

    // ----------------------------------------------------------
    // Sending
    // ----------------------------------------------------------

    private func send(id: String, _ object: [String: Any]) {
        core.broadcast(object) // broadcast == send-to-all; id travels in the payload
    }

    // ----------------------------------------------------------
    // Message handling
    // ----------------------------------------------------------

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "ping":
            send(id: "", ["type": "pong"])
        case "hello":
            // The extension is present and working; the setup issue (if it
            // fired) is resolved.
            setupIssuePosted = false
            Log.info(.meet, nil, "extension connected (hello)")
        case "result":
            guard let id = object["id"] as? String, let request = pending[id] else { return }
            pending[id] = nil
            timeouts[id]?.cancel()
            timeouts[id] = nil
            let ok = object["ok"] as? Bool ?? false
            guard ok else {
                fail(request, cbError: object["error"] as? String ?? "error")
                return
            }
            switch request {
            case .status(let cb):
                // Extension sends {ok:true, status:{inCall, muted, ...}};
                // muted null = control invisible.
                guard let s = object["status"] as? [String: Any] else {
                    fail(request, cbError: "missing status")
                    return
                }
                cb(Status(inCall: s["inCall"] as? Bool ?? false, muted: s["muted"] as? Bool))
            case .command(let cb):
                cb(true)
            }
        default:
            break // unknown messages are ignored so the extension can evolve
        }
    }

    private func fail(_ request: Request, cbError: String?) {
        switch request {
        case .status(let cb):
            cb(nil)
        case .command(let cb):
            cb(false)
        }
    }

    private func armTimeout(_ id: String) {
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let request = self?.pending[id] else { return }
                self?.pending[id] = nil
                self?.timeouts[id] = nil
                self?.fail(request, cbError: "timeout")
            }
        }
        timeouts[id] = work
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: work)
    }

    private func newID() -> String {
        nextID += 1
        return "app-\(nextID)"
    }

    // ----------------------------------------------------------
    // Setup issue (surfaced by the HUD, see HUDPanel)
    // ----------------------------------------------------------

    private var chromeIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.google.Chrome"
        }
    }

    // Called on every failed command/probe while the extension is absent;
    // posts once per session (reset when a hello arrives).
    private func maybePostSetupIssue() {
        guard !setupIssuePosted, chromeIsRunning else { return }
        setupIssuePosted = true
        postSetupIssue(
            title: "MicSync extension required",
            message: "Load the MicSync Bridge extension in Chrome (chrome://extensions ▸ Load unpacked ▸ micsync-chrome-extension)"
        )
    }

    private func postSetupIssue(title: String, message: String) {
        Log.warn(.meet, .setupIssue, "\(title): \(message)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.setupIssue,
                object: nil,
                userInfo: [
                    "title": title,
                    "message": message,
                    "kind": SessionKind.meet,
                ]
            )
        }
    }
}
