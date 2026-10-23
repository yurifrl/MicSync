import Foundation
import GameController

// GameController monitor for the 8BitDo pad (and any Extended Gamepad).
// Buttons are bound by physical position via GC's abstract profile, so
// X-input/Nintendo A/B label swaps don't matter: GC always reports the
// bottom face button as buttonA, right as B, left as X, top as Y.
//
// Bindings are overridable without any settings UI on purpose: UserDefaults
// keys `pad.<buttonName>` hold an engine action string. Button names:
//   buttonA, buttonB, buttonX, buttonY, dpadUp, dpadDown, dpadLeft,
//   dpadRight, leftShoulder, rightShoulder, leftTrigger, rightTrigger,
//   buttonMenu (start), buttonOptions (select)
// Action strings: "toggle" | "mute" | "unmute" | "ptt".
// Absent or invalid keys fall back to DefaultBindings.
final class GamePadMonitor {
    static let shared = GamePadMonitor()

    static let actionKeys: Set<String> = ["toggle", "mute", "unmute", "ptt"]

    // Positional defaults: A = toggle, B = push-to-talk (hold), X = mute,
    // Y = unmute. start (buttonMenu) and everything else ship unbound.
    static let defaultBindings: [String: String] = [
        "buttonA": "toggle",
        "buttonB": "ptt",
        "buttonX": "mute",
        "buttonY": "unmute",
    ]

    /// Per-controller scratch state so a disconnect can release a held
    /// push-to-talk and drop stale press edges.
    private final class PadContext {
        var pressed: [ObjectIdentifier: Bool] = [:]
        var names: [ObjectIdentifier: String] = [:]
    }

    private var started = false
    private var controllersByID: [ObjectIdentifier: GCController] = [:]
    private var contexts: [ObjectIdentifier: PadContext] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(controllerDidDisconnect), name: .GCControllerDidDisconnect, object: nil)

        // Pads already paired before launch.
        GCController.controllers().forEach(attach)
    }

    func stop() {
        guard started else { return }
        started = false
        NotificationCenter.default.removeObserver(self)
        // Snapshot first: detach mutates controllersByID.
        for controller in Array(controllersByID.values) {
            detach(controller)
        }
        controllersByID.removeAll()
        contexts.removeAll()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        attach(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        detach(controller)
    }

    // MARK: - Controller wiring

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard contexts[id] == nil else { return }
        let context = PadContext()
        contexts[id] = context
        controllersByID[id] = controller

        // Extended profile preferred; plain gamepad fallback. microGamepad
        // (Apple TV remote) is intentionally unsupported.
        if let pad = controller.extendedGamepad {
            bind(pad.buttonA, "buttonA", into: context)
            bind(pad.buttonB, "buttonB", into: context)
            bind(pad.buttonX, "buttonX", into: context)
            bind(pad.buttonY, "buttonY", into: context)
            bind(pad.dpad.up, "dpadUp", into: context)
            bind(pad.dpad.down, "dpadDown", into: context)
            bind(pad.dpad.left, "dpadLeft", into: context)
            bind(pad.dpad.right, "dpadRight", into: context)
            bind(pad.leftShoulder, "leftShoulder", into: context)
            bind(pad.rightShoulder, "rightShoulder", into: context)
            bind(pad.leftTrigger, "leftTrigger", into: context)
            bind(pad.rightTrigger, "rightTrigger", into: context)
            bind(pad.buttonMenu, "buttonMenu", into: context)
            if let options = pad.buttonOptions {
                bind(options, "buttonOptions", into: context)
            }
        } else if let pad = controller.gamepad {
            bind(pad.buttonA, "buttonA", into: context)
            bind(pad.buttonB, "buttonB", into: context)
            bind(pad.buttonX, "buttonX", into: context)
            bind(pad.buttonY, "buttonY", into: context)
            bind(pad.dpad.up, "dpadUp", into: context)
            bind(pad.dpad.down, "dpadDown", into: context)
            bind(pad.dpad.left, "dpadLeft", into: context)
            bind(pad.dpad.right, "dpadRight", into: context)
            bind(pad.leftShoulder, "leftShoulder", into: context)
            bind(pad.rightShoulder, "rightShoulder", into: context)
        }
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        controllersByID.removeValue(forKey: id)
        guard let context = contexts.removeValue(forKey: id) else { return }

        // Release any held push-to-talk on this pad so the engine never
        // sticks live after an unplug mid-hold.
        for (inputID, isPressed) in context.pressed where isPressed {
            if let name = context.names[inputID], binding(for: name) == "ptt" {
                DispatchQueue.main.async {
                    SyncEngine.shared.pushToTalk(down: false)
                }
            }
        }
    }

    private func bind(_ button: GCControllerButtonInput, _ name: String, into context: PadContext) {
        let inputID = ObjectIdentifier(button)
        context.names[inputID] = name
        context.pressed[inputID] = false
        button.valueChangedHandler = { [weak self] input, _, pressed in
            self?.handlePress(input: input, name: name, context: context, pressed: pressed)
        }
    }

    // MARK: - Input handling

    private func handlePress(input: GCControllerButtonInput?, name: String, context: PadContext, pressed: Bool) {
        guard let input else { return }
        let inputID = ObjectIdentifier(input)
        // Edge detection: valueChangedHandler can deliver repeats with the
        // same pressed value; only true transitions reach the engine.
        guard context.pressed[inputID] != pressed else { return }
        context.pressed[inputID] = pressed

        guard let action = binding(for: name) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dispatch(action: action, down: pressed)
        }
    }

    private func dispatch(action: String, down: Bool) {
        let engine = SyncEngine.shared
        switch action {
        case "toggle" where down: engine.toggle()
        case "mute" where down: engine.mute()
        case "unmute" where down: engine.unmute()
        case "ptt": engine.pushToTalk(down: down) // fires on press AND release edge
        default: break // release edge of a momentary action is a no-op
        }
    }

    private func binding(for name: String) -> String? {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "pad.\(name)"), Self.actionKeys.contains(stored) {
            return stored
        }
        return Self.defaultBindings[name]
    }
}
