import AppKit

// Transient toast: translucent dark rounded card at the top-center of the
// main screen showing the new mic state plus the session app name, auto
// dismissed after 1.5s with a fade. Borderless, non-activating, and fully
// click-through so it never steals focus from the call.
final class HUDPanel: NSPanel {
    private let engine: SyncEngine

    private let card = HUDCardView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let appLabel = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?
    // Guards against a stale fade-out ordering the panel off screen while a
    // newer event is already fading it back in.
    private var showGeneration = 0
    private var micStateObserver: NSObjectProtocol?
    private var setupIssueObserver: NSObjectProtocol?

    init(engine: SyncEngine) {
        self.engine = engine
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        alphaValue = 0

        contentView = makeContentView()

        micStateObserver = NotificationCenter.default.addObserver(
            forName: SyncEngine.micStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.present(from: notification)
        }

        // Backend setup failures: show what to fix (bypasses the HUD-enabled
        // preference — without the hint the backend is simply dead).
        setupIssueObserver = NotificationCenter.default.addObserver(
            forName: MeetAdapter.micSetupIssue,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.presentSetupIssue(from: notification)
        }
        setupIssueObserver = NotificationCenter.default.addObserver(
            forName: SlackAdapter.axPermissionIssue,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.presentSetupIssue(from: notification)
        }
    }

    deinit {
        if let micStateObserver {
            NotificationCenter.default.removeObserver(micStateObserver)
        }
        if let setupIssueObserver {
            NotificationCenter.default.removeObserver(setupIssueObserver)
        }
        dismissTimer?.invalidate()
    }

    // MARK: - Content

    private func makeContentView() -> NSView {
        stateLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        stateLabel.textColor = .white
        stateLabel.alignment = .center

        appLabel.font = .systemFont(ofSize: 12, weight: .regular)
        appLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        appLabel.alignment = .center

        let stack = NSStackView(views: [stateLabel, appLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2

        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
        ])
        return card
    }

    // MARK: - Presentation

    private func presentSetupIssue(from notification: Notification) {
        appLabel.stringValue = (notification.userInfo?["title"] as? String) ?? "Chrome setup required"
        stateLabel.stringValue = (notification.userInfo?["message"] as? String)
            ?? "Enable View ▸ Developer ▸ Allow JavaScript from Apple Events"

        showGeneration += 1
        dismissTimer?.invalidate()
        dismissTimer = nil

        let size = card.fittingSize
        setContentSize(size)
        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height - 48
            )
            setFrameOrigin(origin)
        }

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        let generation = showGeneration
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.dismiss(generation: generation)
        }
    }

    private func present(from notification: Notification) {
        // Respect Preferences.hudEnabled at event time (checked live, no cache).
        guard Preferences().hudEnabled else { return }

        // Engine carries state + kind in userInfo; fall back to live engine
        // reads if the cast ever misses.
        let state = (notification.userInfo?["state"] as? MicState) ?? engine.desiredState ?? .unknown
        let kind = (notification.userInfo?["kind"] as? SessionKind) ?? .meet

        switch state {
        case .live: stateLabel.stringValue = "🎙 Live"
        case .muted: stateLabel.stringValue = "🔇 Muted"
        case .unknown: stateLabel.stringValue = "❔ Unknown"
        }
        appLabel.stringValue = kind.displayName

        showGeneration += 1
        dismissTimer?.invalidate()
        dismissTimer = nil

        // Size to content, then center-top of the main screen (below the menu bar).
        let size = card.fittingSize
        setContentSize(size)
        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height - 48
            )
            setFrameOrigin(origin)
        }

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        let generation = showGeneration
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.dismiss(generation: generation)
        }
    }

    private func dismiss(generation: Int) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            self.orderOut(nil)
        })
    }
}

// Backdrop: translucent dark rounded card drawn in a layer.
private final class HUDCardView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.78).cgColor
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }
}
