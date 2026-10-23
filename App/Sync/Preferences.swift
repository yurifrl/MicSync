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

    // Debug mode: gated log capture + the console panel. Driven by the
    // AppDelegate, which opens/closes the console when this flips.
    var debugEnabled: Bool {
        get { defaults.object(forKey: "debugEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "debugEnabled"); didChange() }
    }

    // LAN remote control listener (port 8896). Default off: it opens a
    // network endpoint, so it must be an explicit user opt-in.
    var remoteEnabled: Bool {
        get { defaults.object(forKey: "remoteEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "remoteEnabled"); didChange() }
    }

    // Pairing token for the remote listener: random, URL-safe, ≤ 20
    // chars. Persisted so the pairing URL survives relaunch. Generated
    // lazily on first enable; regenerating is an explicit Settings
    // action (invalidates old pairings).
    var remoteToken: String? {
        get { defaults.string(forKey: "remoteToken") }
        set { defaults.set(newValue, forKey: "remoteToken"); didChange() }
    }

    // The pairing URL the listener serves and the Settings QR encodes.
    var remotePairingURL: String? {
        guard let token = remoteToken else { return nil }
        return "http://\(RemoteListener.hostName).local:\(RemoteListener.port)/#\(token)"
    }

}
