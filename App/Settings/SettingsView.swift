import Combine
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

// Write-through settings view model: publishes UI state, persists every
// change into Preferences (UserDefaults) / LaunchAtLogin on the way out.
// removeDuplicates() keeps the didChange -> reload -> write loop from ever
// re-writing an unchanged value.
final class SettingsViewModel: ObservableObject {
    @Published var hudEnabled: Bool
    @Published var soundEnabled: Bool
    @Published var launchAtLogin: Bool

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let prefs = Preferences()
        hudEnabled = prefs.hudEnabled
        soundEnabled = prefs.soundEnabled
        launchAtLogin = LaunchAtLogin.isEnabled

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
        $launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { LaunchAtLogin.isEnabled = $0 }
            .store(in: &cancellables)
    }

    /// Re-reads Preferences + login-item state (called when the window is
    /// (re)shown and on Preferences.didChangeNotification).
    func reloadFromPreferences() {
        let prefs = Preferences()
        hudEnabled = prefs.hudEnabled
        soundEnabled = prefs.soundEnabled
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

// Settings window content. Sections: Behavior, Shortcuts, About. All UI in
// code; the recorder is KeyboardShortcuts' standard capture control.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Show HUD popup", isOn: $viewModel.hudEnabled)
                Toggle("Play sound on change", isOn: $viewModel.soundEnabled)
                Toggle("Launch at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.launchAtLogin = $0 }
                ))
            }

            Section("Shortcuts") {
                shortcutRow("Toggle Mic", name: .toggleMic)
                shortcutRow("Mute", name: .muteMic)
                shortcutRow("Unmute", name: .unmuteMic)
                shortcutRow("Push to Talk", name: .pushToTalk)
                shortcutRow("Switch Meet/Slack Target", name: .switchTarget)
            }

            Section("About") {
                aboutBlock
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private func shortcutRow(_ label: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("MicSync").font(.headline)
                Text(versionString).foregroundColor(.secondary)
            }
            Text("Syncs mute state across Google Meet (Chrome) and Slack huddles.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(short) (\(build))"
    }
}
