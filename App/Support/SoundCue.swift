import AppKit

// Plays the state-change sound cues. Glass = went live, Pop = muted
// (same cues as the Hammerspoon version). Respects Preferences.soundEnabled
// at event time, checked live so a settings flip applies instantly.
final class SoundCue {
    static let shared = SoundCue()

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: SyncEngine.micStateDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard Preferences().soundEnabled else { return }
            guard let state = notification.userInfo?["state"] as? MicState else { return }
            switch state {
            case .live: NSSound(named: "Glass")?.play()
            case .muted: NSSound(named: "Pop")?.play()
            case .unknown: break
            }
        }
    }
}
