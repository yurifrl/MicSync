import AppKit
import Combine
import LaunchAtLogin

// Owns the NSStatusItem. Plain left-click toggles the mic directly; the
// menu opens on right-click (or option-click). Title is a bare glyph —
// no suffixes. The menu is rebuilt from live engine state on every open.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let engine: SyncEngine
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var stateObserver: NSObjectProtocol?

    init(engine: SyncEngine, onOpenSettings: @escaping () -> Void) {
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        // No automatic menu on click: the button handles left-click itself.
        statusItem.menu = nil
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildTitle()
        observeEngine()
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Status item button

    @objc private func statusButtonClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
        if rightClick {
            // Pop the options menu without consuming the click.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            engine.toggle()
        }
    }

    // MARK: - Engine observation

    private func observeEngine() {
        Publishers.CombineLatest(engine.$desiredState, engine.$snapshots)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildTitle() }
            .store(in: &cancellables)

        // Belt-and-braces: the engine also posts on every effective change.
        stateObserver = NotificationCenter.default.addObserver(
            forName: SyncEngine.micStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildTitle()
        }
    }

    private var glyph: String {
        switch engine.desiredState {
        case .some(.live): return "🎙"
        case .some(.muted): return "🔇"
        case .some(.unknown), .none: return "❔"
        }
    }

    // Snapshots only hold kinds with a live adapter; inCall marks a real call.
    private var liveSessions: [SessionKind] {
        SessionKind.allCases.filter { engine.snapshots[$0]?.inCall == true }
    }

    private func rebuildTitle() {
        statusItem.button?.title = glyph
    }

    // MARK: - Menu (rebuilt on every open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for kind in liveSessions {
            let state = engine.snapshots[kind]?.state ?? .unknown
            menu.addItem(disabledItem("\(kind.displayName): \(state.label)"))
        }
        if liveSessions.isEmpty {
            menu.addItem(disabledItem("No active sessions"))
        }

        menu.addItem(.separator())
        add("Toggle Mic", action: #selector(toggleMicAction), enabled: !liveSessions.isEmpty)
        add("Mute", action: #selector(muteAction), enabled: !liveSessions.isEmpty)
        add("Unmute", action: #selector(unmuteAction), enabled: !liveSessions.isEmpty)

        menu.addItem(.separator())
        add("Settings…", action: #selector(openSettingsAction), enabled: true)
        add(
            "Launch at Login",
            action: #selector(toggleLoginAction(_:)),
            enabled: true,
            checked: LaunchAtLogin.isEnabled
        )

        menu.addItem(.separator())
        add("Quit MicSync", action: #selector(quitAction), enabled: true)
    }

    // MARK: - Actions

    @objc private func toggleMicAction() { engine.toggle() }
    @objc private func muteAction() { engine.mute() }
    @objc private func unmuteAction() { engine.unmute() }
    @objc private func openSettingsAction() { onOpenSettings() }

    @objc private func toggleLoginAction(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled.toggle()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu item helpers

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func add(_ title: String, action: Selector, enabled: Bool, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        menu.addItem(item)
    }
}
