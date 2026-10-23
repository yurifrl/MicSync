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
    private var debugConsole: DebugConsoleController?
    private var preferencesObserver: NSObjectProtocol?

    // Menu-bar apps have no Dock icon; relaunching the binary (or `open -a`)
    // is the only "click the icon again" gesture a user has, so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture must be live before the first producer fires, otherwise
        // the launch line (and anything else emitted during launch) is
        // dropped when the console opens.
        applyDebugMode()
        Log.info(.app, nil, "launched")
        hud = HUDPanel(engine: engine)
        statusBarController = StatusBarController(engine: engine) { [weak self] in
            self?.showSettings()
        }
        GamePadMonitor.shared.start()
        SoundCue.shared.start()
        SlackAdapter.promptForAXTrust()
        wireShortcuts()
        // LAN remote control: starts only when the user enabled it
        // (Preferences.remoteEnabled); inert otherwise.
        RemoteListener.shared.start()

        // Keep an open settings window in sync with preference changes made
        // elsewhere (e.g. future pref surfaces); the VM itself is write-through.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsViewModel?.reloadFromPreferences()
            self?.applyDebugMode()
        }
        applyDebugMode()
    }

    // Menu-bar app: closing the settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Debug mode

    // Single source of truth for debug mode is Preferences.debugEnabled:
    // log capture and the console panel both follow it. Capture is on
    // exactly while the panel is open — closing the console (either path)
    // stops capture and drops the buffer.
    private func applyDebugMode() {
        let on = Preferences().debugEnabled
        LogStore.shared.setEnabled(on)
        if on {
            if debugConsole == nil {
                debugConsole = DebugConsoleController(engine: engine)
            }
            debugConsole?.open()
        } else {
            debugConsole?.close()
            debugConsole = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GamePadMonitor.shared.stop()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
            self.preferencesObserver = nil
        }
    }

    // MARK: - Global shortcuts -> engine actions

    // KeyboardShortcuts 3.x registers Carbon handlers on the main actor.
    @MainActor
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
