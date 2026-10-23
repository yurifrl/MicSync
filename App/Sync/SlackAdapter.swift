import Foundation
import AppKit
import ApplicationServices

// Slack huddle backend via the macOS accessibility tree.
//
// Slack (Electron/Chromium) exposes its real UI tree only through the
// FOCUSED WINDOW: from the app element, kAXWindowsAttribute reports zero
// windows and the direct children carry just the menu bar, so any walk
// seeded on the app element never reaches the huddle widget. Roots are
// therefore collected from kAXFocusedWindowAttribute + kAXWindowsAttribute
// + kAXChildrenAttribute and walked together.
//
// Trigger-driven: `apply` is a direct order decided from the control's own
// label (no state read, no verification press); `probe` is the single-shot
// read used only by toggle and menu-open reconciliation.

final class SlackAdapter: SessionAdapter {
    let kind: SessionKind = .slack

    private static let slackBundle = "com.tinyspeck.slackmacgap"
    // Hard cap on AX-tree nodes walked per operation; Chromium trees can be
    // enormous, and an unbounded walk would stall whatever queue runs it.
    private static let maxAXNodes = 4000

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

    // ----------------------------------------------------------
    // AX primitives
    // ----------------------------------------------------------

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let str = value as? String else { return nil }
        return str
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private final class Budget {
        var remaining: Int
        init(_ remaining: Int) { self.remaining = remaining }
    }

    // Bounded depth-first search for a UI element whose AXDescription,
    // AXTitle or AXValue matches any pattern. Caps the walk so a huge
    // Chromium tree can never stall the queue.
    private func axFind(_ root: AXUIElement, patterns: [String], budget: Budget) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        while !stack.isEmpty, budget.remaining > 0 {
            let element = stack.removeFirst()
            budget.remaining -= 1

            let description = axString(element, kAXDescriptionAttribute) ?? ""
            let title = axString(element, kAXTitleAttribute) ?? ""
            let value = axString(element, kAXValueAttribute) ?? ""

            for pattern in patterns {
                if description.range(of: pattern, options: .regularExpression) != nil
                    || title.range(of: pattern, options: .regularExpression) != nil
                    || value.range(of: pattern, options: .regularExpression) != nil {
                    return element
                }
            }
            stack.append(contentsOf: axChildren(element))
        }
        return nil
    }

    // Walk roots: from the app element Chromium exposes only the menu bar
    // (kAXWindows -> 0, children -> menu bar). The real UI hangs off the
    // focused window; multi-window Slack (detached huddle windows) makes
    // kAXWindows useful on some builds, so all reachable roots are walked.
    private func uiRoots(_ app: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success {
            roots.append(contentsOf: (windows as? [AXUIElement]) ?? [])
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
            roots.append(f as! AXUIElement)
        }
        roots.append(contentsOf: axChildren(app)) // menu bar (+ any exposed shells)
        return roots
    }

    // The app element (after nudging AXManualAccessibility for builds that
    // still honor it) or nil when Slack is not running.
    private func slackApp() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.slackBundle).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let current = AXUIElementCopyAttributeValue(
            element, "AXManualAccessibility" as CFString, &value)
        if !(current == .success && (value as? Bool) == true) {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, true as CFBoolean)
        }
        return element
    }

    // Should the control be pressed for this goal? Unmute-flavored labels
    // mean the mic is currently muted: a .muted goal is already satisfied
    // (no press), a .live goal needs the press — and vice versa.
    private func shouldPress(_ mic: AXUIElement, _ goal: MicGoal) -> Bool {
        let label = axString(mic, kAXDescriptionAttribute)
            ?? axString(mic, kAXTitleAttribute)
            ?? ""
        let isMuted = label.range(of: "^Turn on", options: .regularExpression) != nil
            || label.range(of: "^Unmute", options: .regularExpression) != nil
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
            guard ensureAXPermission(), let app = slackApp() else { return cb(false) }

            // Direct order: find a decidable mic control across all UI
            // roots and decide from its own label. "Not muted" / sidebar
            // rows are excluded by micPatterns.
            let budget = Budget(Self.maxAXNodes)
            var mic: AXUIElement?
            for root in uiRoots(app) {
                if let hit = axFind(root, patterns: Self.micPatterns, budget: budget) {
                    mic = hit
                    break
                }
            }
            guard let mic else {
                return cb(false) // no huddle (or no decidable control)
            }
            if shouldPress(mic, goal) {
                AXUIElementPerformAction(mic, kAXPressAction as CFString)
            }
            cb(true) // the press (or the already-holding goal) settles it
        }
    }

    // Single-shot read for toggle / menu-open reconciliation only.
    func probe(_ cb: @escaping (SessionSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self, !busy else { return cb(nil) }
            busy = true
            defer { busy = false }
            guard Self.isAXTrusted(), let app = slackApp() else { return cb(nil) }

            let budget = Budget(Self.maxAXNodes)
            var session: AXUIElement?
            for root in uiRoots(app) {
                if let hit = axFind(root, patterns: Self.sessionPatterns, budget: budget) {
                    session = hit
                    break
                }
            }
            guard session != nil else { return cb(SessionSnapshot(kind: .slack, inCall: false, state: .unknown)) }

            var mic: AXUIElement?
            for root in uiRoots(app) {
                if let hit = axFind(root, patterns: Self.micPatterns, budget: budget) {
                    mic = hit
                    break
                }
            }
            guard let mic else {
                return cb(SessionSnapshot(kind: .slack, inCall: true, state: .unknown))
            }
            let label = axString(mic, kAXDescriptionAttribute)
                ?? axString(mic, kAXTitleAttribute)
                ?? ""
            let state: MicState = label.range(of: "^Turn on", options: .regularExpression) != nil
                || label.range(of: "^Unmute", options: .regularExpression) != nil
                ? .muted : .live
            cb(SessionSnapshot(kind: .slack, inCall: true, state: state))
        }
    }
}
