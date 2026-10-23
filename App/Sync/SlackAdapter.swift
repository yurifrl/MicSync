import Foundation
import AppKit
import ApplicationServices

// Slack huddle backend via the macOS accessibility tree.
//
// Slack (Electron) builds its accessibility tree only when an assistive
// client opts in; setting AXManualAccessibility on the app element forces
// Chromium to expose it. Huddles are driven via AXPress on the docked
// in-call widget buttons; those elements exist ONLY while a huddle is
// live, so a probe outside a huddle finds nothing and reports inCall=false.

final class SlackAdapter: SessionAdapter {
    let kind: SessionKind = .slack

    private static let slackBundle = "com.tinyspeck.slackmacgap"
    // Hard cap on AX-tree nodes walked per probe; Chromium trees can be
    // enormous, and an unbounded walk would stall whatever queue runs it.
    private static let maxAXNodes = 4000
    // Re-read delay after AXPress so the callback reports reality.
    private static let verifyDelay: TimeInterval = 0.5

    // Mic-button patterns shared by detection and pressing. Verified
    // against a live huddle: the in-call mic button uses "Mute"/"Unmute"
    // (bare); the other variants cover alternate builds/locales. "Not
    // muted" (the sidebar huddle-row state chip) is deliberately excluded:
    // pressing it does nothing and its wording inverts state.
    private static let micPatterns = [
        "^Unmute$", "^Mute$",
        "^Turn on microphone$", "^Turn off microphone$",
        "^Unmute microphone$", "^Mute microphone$",
    ]

    // A live huddle is proven by session-scoped controls (leave/end), NOT
    // by any word "huddle" alone — the sidebar contains huddle rows offline.
    private static let sessionPatterns = ["^Leave huddle$", "^End huddle$", "^Leave conversation$"]

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
              let list = value as? [AXUIElement] else { return [] }
        return list
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

    // Enable Slack's AX tree once per instance; returns the app element or
    // nil when Slack is not running.
    private func slackReady() -> AXUIElement? {
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

    // Describe the live huddle dock, or inCall=false when none.
    private func huddlesData(_ root: AXUIElement) -> (inCall: Bool, state: MicState) {
        let budget = Budget(Self.maxAXNodes)
        guard axFind(root, patterns: Self.sessionPatterns, budget: budget) != nil else {
            return (false, .unknown)
        }
        guard let mic = axFind(root, patterns: Self.micPatterns, budget: budget) else {
            return (true, .unknown)
        }
        let label = axString(mic, kAXDescriptionAttribute)
            ?? axString(mic, kAXTitleAttribute)
            ?? ""
        if label.range(of: "^Turn on", options: .regularExpression) != nil
            || label.range(of: "^Unmute", options: .regularExpression) != nil {
            return (true, .muted)
        }
        // "Turn off microphone" / "Mute" -> currently live
        return (true, .live)
    }

    private func snapshot(from data: (inCall: Bool, state: MicState)) -> SessionSnapshot {
        SessionSnapshot(kind: .slack, inCall: data.inCall, state: data.state)
    }

    // ----------------------------------------------------------
    // SessionAdapter
    // ----------------------------------------------------------

    func probe(_ cb: @escaping (SessionSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self, !busy else { return cb(nil) }
            busy = true
            defer { busy = false }
            guard let root = slackReady() else { return cb(nil) }
            cb(self.snapshot(from: self.huddlesData(root)))
        }
    }

    // Perform the action on the huddle mic toggle; cb(verified).
    func set(_ desired: MicState, cb: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, !busy else { return cb(false) }
            busy = true
            guard let root = self.slackReady() else {
                busy = false
                return cb(false)
            }
            let before = self.huddlesData(root)
            guard before.inCall else {
                busy = false
                return cb(false) // no-huddle
            }
            guard before.state != .unknown else {
                busy = false
                return cb(false) // no-mic-button
            }
            let need = (desired == .muted && before.state == .live)
                || (desired == .live && before.state == .muted)
            if !need {
                busy = false
                return cb(true) // already at desired state
            }
            guard let mic = self.axFind(
                root, patterns: Self.micPatterns,
                budget: Budget(Self.maxAXNodes)) else {
                busy = false
                return cb(false)
            }
            AXUIElementPerformAction(mic, kAXPressAction as CFString)
            // Re-read after the click settles so the callback reports
            // reality (ported 0.5s verify).
            queue.asyncAfter(deadline: .now() + Self.verifyDelay) { [weak self] in
                guard let self else { return cb(false) }
                if let afterRoot = self.slackReady() {
                    let after = self.huddlesData(afterRoot)
                    cb(after.inCall && after.state == desired)
                } else {
                    cb(false)
                }
                busy = false
            }
        }
    }
}
