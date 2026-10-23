import Foundation
import AppKit
import ApplicationServices

// Slack huddle backend via the macOS accessibility tree.
//
// Trigger-driven: `apply` is a direct order decided from the control's own
// label (no state read, no verification press); `probe` is the single-shot
// read used only by toggle and menu-open reconciliation. AX plumbing
// (element lookup, bounded walks, roots) lives in AXTree; this adapter
// owns Slack-specific patterns and decisions.

final class SlackAdapter: SessionAdapter {
    let kind: SessionKind = .slack

    private static let slackBundle = "com.tinyspeck.slackmacgap"

    // Mic-button patterns shared by detection and pressing. Verified
    // against a live huddle: the in-call mic button uses "Mute"/"Unmute"
    // (bare) or "Mute/Unmute microphone" depending on build; the other
    // variants cover alternate builds/locales. "Not muted" (the sidebar
    // huddle-row state chip) is deliberately excluded: pressing it does
    // nothing and its wording inverts state.
    private static let micPatterns = [
        "^Unmute$", "^Mute$",
        "^Turn on microphone$", "^Turn off microphone$",
        "^Unmute microphone$", "^Mute microphone$",
    ]

    // A live huddle is proven by session-scoped controls (leave/end), NOT
    // by any word "huddle" alone — the sidebar contains huddle rows offline.
    private static let sessionPatterns = ["^Leave huddle$", "^End huddle$", "^Leave conversation$"]

    // Posted (once, main thread) when the app's own Accessibility
    // permission is missing. Untrusted AX calls fail SILENTLY (no error,
    // no prompt), so without this the Slack backend just reads as dead.
    static let axPermissionIssue = Notification.Name("AxPermissionIssue")

    private var axIssuePosted = false

    /// Reports whether this process holds the Accessibility permission
    /// needed for huddle control.
    static func isAXTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its own Accessibility consent prompt, which adds
    /// MicSync to Privacy & Security ▸ Accessibility automatically. The
    /// manual check never triggers it (untrusted checks fail silently), so
    /// the app must request the prompt itself — once per launch is enough;
    /// macOS suppresses duplicates while the request is pending.
    static func promptForAXTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Returns false (after posting the alert once) when untrusted.
    private func ensureAXPermission() -> Bool {
        guard !Self.isAXTrusted() else { return true }
        if !axIssuePosted {
            axIssuePosted = true
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.axPermissionIssue,
                    object: nil,
                    userInfo: [
                        "title": "Accessibility permission required",
                        "message": "System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable MicSync",
                        "kind": SessionKind.slack,
                    ]
                )
            }
        }
        return false
    }

    private let queue = DispatchQueue(label: "com.yurifrl.micsync.slack", qos: .userInitiated)
    private var busy = false // guard reentrancy on the serial AX queue

    // The control's own label, read the same way everywhere a decision
    // needs it (description first, then title).
    private static func label(_ element: AXUIElement) -> String {
        AXTree.string(element, kAXDescriptionAttribute)
            ?? AXTree.string(element, kAXTitleAttribute)
            ?? ""
    }

    // Muted-flavored labels ("Turn on…"/"Unmute…") mean the mic is
    // currently muted. Shared by shouldPress and probe so both decisions
    // can never drift.
    private static func labelSaysMuted(_ text: String) -> Bool {
        text.range(of: "^Turn on", options: .regularExpression) != nil
            || text.range(of: "^Unmute", options: .regularExpression) != nil
    }

    // Should the control be pressed for this goal? Unmute-flavored labels
    // mean the mic is currently muted: a .muted goal is already satisfied
    // (no press), a .live goal needs the press — and vice versa.
    private func shouldPress(_ mic: AXUIElement, _ goal: MicGoal) -> Bool {
        let isMuted = Self.labelSaysMuted(Self.label(mic))
        return (goal, isMuted) == (.live, true) || (goal, isMuted) == (.muted, false)
    }

    // ----------------------------------------------------------
    // SessionAdapter
    // ----------------------------------------------------------

    func apply(_ goal: MicGoal, cb: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, !busy else { return cb(false) }
            busy = true
            defer { busy = false }
            let start = DispatchTime.now()
            guard ensureAXPermission() else {
                Log.warn(.slack, .adapterResult(.slack, .apply, ok: false, durationMs: Timing.ms(since: start)), "no Accessibility permission")
                return cb(false)
            }
            guard let app = AXTree.appElement(bundleID: Self.slackBundle) else {
                Log.debug(.slack, .adapterResult(.slack, .apply, ok: false, durationMs: Timing.ms(since: start)), "Slack not running")
                return cb(false)
            }

            // Direct order: find a decidable mic control across all UI
            // roots and decide from its own label. "Not muted" / sidebar
            // rows are excluded by micPatterns.
            let budget = AXTree.Budget(AXTree.maxNodes)
            var mic: AXUIElement?
            for root in AXTree.uiRoots(app) {
                if let hit = AXTree.find(root, patterns: Self.micPatterns, budget: budget) {
                    mic = hit
                    break
                }
            }
            guard let mic else {
                Log.debug(.slack, .adapterResult(.slack, .apply, ok: false, durationMs: Timing.ms(since: start)), "no huddle or decidable mic control")
                return cb(false) // no huddle (or no decidable control)
            }
            let press = shouldPress(mic, goal)
            if press {
                AXUIElementPerformAction(mic, kAXPressAction as CFString)
            }
            Log.debug(.slack, .adapterResult(.slack, .apply, ok: true, durationMs: Timing.ms(since: start)), press ? "pressed" : "already held")
            cb(true) // the press (or the already-holding goal) settles it
        }
    }

    // Single-shot read for toggle / menu-open reconciliation only.
    func probe(_ cb: @escaping (SessionSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self, !busy else { return cb(nil) }
            busy = true
            defer { busy = false }
            let start = DispatchTime.now()
            // One logging funnel: every completion path reports here.
            let respond: (SessionSnapshot?) -> Void = { snap in
                Log.debug(.slack, .adapterResult(.slack, .probe, ok: snap != nil, durationMs: Timing.ms(since: start)),
                          snap == nil ? "Slack not running / no AX trust" : "answered")
                cb(snap)
            }
            guard Self.isAXTrusted(), let app = AXTree.appElement(bundleID: Self.slackBundle) else {
                return respond(nil)
            }

            let budget = AXTree.Budget(AXTree.maxNodes)
            var session: AXUIElement?
            for root in AXTree.uiRoots(app) {
                if let hit = AXTree.find(root, patterns: Self.sessionPatterns, budget: budget) {
                    session = hit
                    break
                }
            }
            guard session != nil else { return respond(SessionSnapshot(kind: .slack, inCall: false, state: .unknown)) }

            var mic: AXUIElement?
            for root in AXTree.uiRoots(app) {
                if let hit = AXTree.find(root, patterns: Self.micPatterns, budget: budget) {
                    mic = hit
                    break
                }
            }
            guard let mic else {
                return respond(SessionSnapshot(kind: .slack, inCall: true, state: .unknown))
            }
            let state: MicState = Self.labelSaysMuted(Self.label(mic)) ? .muted : .live
            respond(SessionSnapshot(kind: .slack, inCall: true, state: state))
        }
    }
}
