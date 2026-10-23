import AppKit
import Combine
import LaunchAtLogin

// Owns the NSStatusItem. Title glyph mirrors the engine's desired state;
// when both sessions are live a " (M)"/" (S)" suffix shows the effective
// target (pinned, or Auto which resolves Meet-first). The menu is rebuilt
// from live engine state every time it opens.
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
        statusItem.menu = menu // click opens the menu
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

    // MARK: - Engine observation

    private func observeEngine() {
        Publishers.CombineLatest3(engine.$desiredState, engine.$snapshots, engine.$pinnedTarget)
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

    private var bothLive: Bool { liveSessions.count >= 2 }

    private func rebuildTitle() {
        var title = glyph
        if bothLive {
            // Engine Auto is Meet-first by adapter order.
            title += engine.pinnedTarget == .slack ? " (S)" : " (M)"
        }
        statusItem.button?.title = title
    }

    // MARK: - Menu (rebuilt on every open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if liveSessions.isEmpty {
            menu.addItem(disabledItem("No active sessions"))
        } else {
            for kind in liveSessions {
                let state = engine.snapshots[kind]?.state ?? .unknown
                menu.addItem(disabledItem("\(kind.displayName): \(state.label)"))
            }
        }
        let targetLine: String = {
            switch engine.pinnedTarget {
            case .meet: return "Target: Meet (pinned)"
            case .slack: return "Target: Slack (pinned)"
            case nil: return "Target: Auto (Meet first)"
            }
        }()
        menu.addItem(disabledItem(targetLine))

        menu.addItem(.separator())
        add("Toggle Mic", action: #selector(toggleMicAction), enabled: !liveSessions.isEmpty)
        add("Mute", action: #selector(muteAction), enabled: !liveSessions.isEmpty)
        add("Unmute", action: #selector(unmuteAction), enabled: !liveSessions.isEmpty)

        menu.addItem(.separator())
        // switchTarget() cycles meet -> slack -> auto; a direct pin has no
        // engine API by contract, so the menu cycles like the shortcut does.
        add("Switch Meet/Slack Target", action: #selector(switchTargetAction), enabled: bothLive)

        menu.addItem(.separator())
        add("Settings…", action: #selector(openSettingsAction), enabled: true)
        add("Launch at Login", action: #selector(toggleLoginAction), enabled: true, checked: LaunchAtLogin.isEnabled)
        menu.addItem(.separator())
        add("Quit MicSync", action: #selector(quitAction), enabled: true)
    }

    // MARK: - Actions

    @objc private func toggleMicAction() { engine.toggle() }
    @objc private func muteAction() { engine.mute() }
    @objc private func unmuteAction() { engine.unmute() }
    @objc private func switchTargetAction() { engine.switchTarget() }
    @objc private func openSettingsAction() { onOpenSettings() }

    @objc private func toggleLoginAction(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled.toggle()
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
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
