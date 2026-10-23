import Combine
import KeyboardShortcuts
import LaunchAtLogin

// Write-through settings view model: publishes UI state, persists every
// change into Preferences (UserDefaults) / LaunchAtLogin on the way out.
// removeDuplicates() keeps the didChange -> reload -> write loop from ever
// re-writing an unchanged value.
final class SettingsViewModel: ObservableObject {
    @Published var hudEnabled: Bool
    @Published var soundEnabled: Bool
    @Published var debugEnabled: Bool
    @Published var launchAtLogin: Bool
    @Published var remoteEnabled: Bool
    @Published var remoteToken: String

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let prefs = Preferences()
        hudEnabled = prefs.hudEnabled
        soundEnabled = prefs.soundEnabled
        debugEnabled = prefs.debugEnabled
        launchAtLogin = LaunchAtLogin.isEnabled
        remoteEnabled = prefs.remoteEnabled
        remoteToken = prefs.remoteToken ?? ""

        $hudEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [self] in Preferences().hudEnabled = $0 }
            .store(in: &cancellables)
        $soundEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [self] in Preferences().soundEnabled = $0 }
            .store(in: &cancellables)
        $debugEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [self] in Preferences().debugEnabled = $0 }
            .store(in: &cancellables)
        $launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { LaunchAtLogin.isEnabled = $0 }
            .store(in: &cancellables)
        $remoteEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [self] in
                let prefs = Preferences()
                prefs.remoteEnabled = $0
                // First enable mints the token; refresh the displayed one.
                remoteToken = prefs.remoteToken ?? ""
            }
            .store(in: &cancellables)
    }

    /// Re-reads Preferences + login-item state (called when the window is
    /// (re)shown and on Preferences.didChangeNotification).
    func reloadFromPreferences() {
        let prefs = Preferences()
        hudEnabled = prefs.hudEnabled
        soundEnabled = prefs.soundEnabled
        debugEnabled = prefs.debugEnabled
        launchAtLogin = LaunchAtLogin.isEnabled
        remoteEnabled = prefs.remoteEnabled
        remoteToken = prefs.remoteToken ?? ""
    }

    /// Explicit user action: mints a fresh token. Existing pairings (old
    /// URL) stop working; the Settings window shows the new one.
    func regenerateToken() {
        remoteToken = RemoteListener.shared.regenerateToken()
    }

    /// The full pairing URL (never displayed when remote is disabled).
    var pairingURL: String? {
        guard remoteEnabled, !remoteToken.isEmpty else { return nil }
        return "http://\(RemoteListener.hostName).local:\(RemoteListener.port)/#\(remoteToken)"
    }
}
