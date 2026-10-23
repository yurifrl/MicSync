import AppKit
import SwiftUI

// Owns the debug console NSPanel: a floating utility panel anchored near
// the menu bar's right edge. Non-activating (focus stays in Slack/Meet),
// stays visible while toggling, placed once on open — the log list scrolls
// internally, so the frame never needs to move while open. Pure window
// management: capture gating and lifecycle live in the AppDelegate, which
// is driven by Preferences.debugEnabled.
final class DebugConsoleController: NSObject, NSWindowDelegate {
    private let engine: SyncEngine

    private var panel: NSPanel?
    // Width allowance for the status-item area the panel tucks beside.
    private var statusLength = CGFloat(40)

    init(engine: SyncEngine) {
        self.engine = engine
        super.init()
    }

    // MARK: - Open / close

    func open() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.setFrame(place(panel), display: false)
        panel.orderFrontRegardless() // non-activating: focus stays put
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "MicSync Debug"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DebugConsoleView(engine: engine))
        return panel
    }

    // Below the status item, tucked against the screen's right edge.
    private func place(_ panel: NSPanel) -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame else { return panel.frame }
        let width = panel.frame.width, height = panel.frame.height
        let x = visible.maxX - width - 8 - statusLength
        let y = visible.maxY - height - 8
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    // Title-bar close: route through the preference so the settings
    // checkbox, capture gate, and window stay one state.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Preferences().debugEnabled = false
        return false
    }
}
