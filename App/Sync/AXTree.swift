import Foundation
import AppKit
import ApplicationServices

// Generic accessibility-tree primitives shared by AX-driven adapters.
// Pure helpers only: no app-specific vocabulary, no decisions. Walks are
// budget-capped so a huge Chromium tree can never stall the queue that
// runs them.
enum AXTree {

    // Reference-type walk budget: one budget may be shared across several
    // find calls so a multi-root scan walks at most maxNodes in total.
    final class Budget {
        var remaining: Int
        init(_ remaining: Int) { self.remaining = remaining }
    }

    // Hard cap on AX-tree nodes walked per operation; Chromium trees can
    // be enormous, and an unbounded walk would stall whatever queue runs it.
    static let maxNodes = 4000

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let str = value as? String else { return nil }
        return str
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    // Bounded depth-first search for a UI element whose AXDescription,
    // AXTitle or AXValue matches any pattern.
    static func find(_ root: AXUIElement, patterns: [String], budget: Budget) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        while !stack.isEmpty, budget.remaining > 0 {
            let element = stack.removeFirst()
            budget.remaining -= 1

            let description = string(element, kAXDescriptionAttribute) ?? ""
            let title = string(element, kAXTitleAttribute) ?? ""
            let value = string(element, kAXValueAttribute) ?? ""

            for pattern in patterns {
                if description.range(of: pattern, options: .regularExpression) != nil
                    || title.range(of: pattern, options: .regularExpression) != nil
                    || value.range(of: pattern, options: .regularExpression) != nil {
                    return element
                }
            }
            stack.append(contentsOf: children(element))
        }
        return nil
    }

    // Walk roots for a Chromium/Electron app element. Chromium exposes
    // only the menu bar through the app element (kAXWindows -> 0, direct
    // children -> menu bar); the real UI hangs off the focused window.
    // Multi-window Slack (detached huddle windows) makes kAXWindows useful
    // on some builds, so all reachable roots are collected and walked.
    static func uiRoots(_ app: AXUIElement) -> [AXUIElement] {
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
        roots.append(contentsOf: children(app)) // menu bar (+ any exposed shells)
        return roots
    }

    // The app element (after nudging AXManualAccessibility, which some
    // Chromium builds still honor) or nil when the app is not running.
    static func appElement(bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
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
}
