import AppKit
import KeyboardShortcuts
import SwiftUI

// App entry point. LSUIElement in Info.plist makes this an accessory
// (menu-bar-only) app. There is no main storyboard, so the default
// NSApplicationMain entry cannot wire the delegate from a nib — that made
// it run the app with NO delegate (status item never appeared). We provide
// main() explicitly; @main synthesizes the C entry point that calls it.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    private let engine = SyncEngine.shared

    private var statusBarController: StatusBarController?
    private var hud: HUDPanel?
    private var settingsWindow: NSWindow?
    private var settingsViewModel: SettingsViewModel?
    private var preferencesObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDPanel(engine: engine)
        statusBarController = StatusBarController(engine: engine) { [weak self] in
            self?.showSettings()
        }
        GamePadMonitor.shared.start()
        SoundCue.shared.start()
        wireShortcuts()

        // Keep an open settings window in sync with preference changes made
        // elsewhere (e.g. future pref surfaces); the VM itself is write-through.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsViewModel?.reloadFromPreferences()
        }
    }

    // Menu-bar app: closing the settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        GamePadMonitor.shared.stop()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
            self.preferencesObserver = nil
        }
    }

    // MARK: - Global shortcuts -> engine actions

    private func wireShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleMic) { [weak self] in self?.engine.toggle() }
        KeyboardShortcuts.onKeyUp(for: .muteMic) { [weak self] in self?.engine.mute() }
        KeyboardShortcuts.onKeyUp(for: .unmuteMic) { [weak self] in self?.engine.unmute() }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in self?.engine.pushToTalk(down: true) }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in self?.engine.pushToTalk(down: false) }
    }

    // MARK: - Settings window (created lazily, kept alive for reopen)

    func showSettings() {
        guard let window = settingsWindow else {
            installSettingsWindow()
            return
        }
        settingsViewModel?.reloadFromPreferences()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installSettingsWindow() {
        let viewModel = SettingsViewModel()
        settingsViewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicSync Settings"
        // Keep the window (and its view model) alive across close/reopen.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
