import Foundation

final class Preferences {
    static let didChangeNotification = Notification.Name("com.yurifrl.micsync.PreferencesChanged")

    private let defaults = UserDefaults.standard

    private func didChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // Brief floating HUD on every state change (Hammerspoon-style popup).
    var hudEnabled: Bool {
        get { defaults.object(forKey: "hudEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hudEnabled"); didChange() }
    }

    // Sound cues on state change.
    var soundEnabled: Bool {
        get { defaults.object(forKey: "soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "soundEnabled"); didChange() }
    }

    // Target preference when both sessions are live: .meet wins by default.
    var preferredTarget: String {
        get { defaults.string(forKey: "preferredTarget") ?? "meet" }
        set { defaults.set(newValue, forKey: "preferredTarget"); didChange() }
    }
}
