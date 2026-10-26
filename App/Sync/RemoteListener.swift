import Foundation
import Network
import Combine

// LAN remote control: a phone (or any device) drives the SAME trigger
// engine the keyboard shortcuts use. Plain HTTP + WebSocket on one
// NWListener (port 8896, all interfaces so Bonjour + .local resolve);
// token-gated; pushes state over WS on every observable change.
//
// Listener is strictly a client of SyncEngine: it calls the same public
// triggers (mute/unmute/toggle/pushToTalk/reconcile) a keyboard press
// would, never the adapters. The engine stays trigger-driven; this
// listener's only recurring work is its Combine subscriptions (no
// timers, no polling).
//
// Wire protocol (shared with the syscd-app phone module):
//   GET /                       pairing/status page (static markup)
//   GET /status                 {"v":1,"ok":true,"desired":<goal|null>,
//                                "sessions":[{"kind":..,"muted":..}]}
//   GET /mute|/unmute|/toggle   command; responds with the /status body
//                               (409 when the engine reports a no-op)
//   GET /ptt/1, GET /ptt/0      push-to-talk down / up
//   WS  /ws?token=...           (or Authorization: Bearer) — pushes the
//                               state frame on connect and after every
//                               observable engine change.
//
// Token must match on EVERY request (HTTP and WS); mismatch is 403.

final class RemoteListener {
    static let port: UInt16 = 8896
    // Bonjour advertises this service; the pairing host is <hostname>.local.
    static let serviceName = "micsync"

    // One listener per app instance (AppDelegate owns its lifetime).
    static let shared = RemoteListener()

    static var hostName: String {
        // gethostname() is the actual Bonjour-registered local hostname
        // ("Yuris-MacBook-Pro-2"); localizedName is the display name and
        // may contain apostrophes/parens ("Yuri's MacBook Pro (2)"), which
        // are illegal in a DNS label and produce unscannable pairing URLs.
        var name = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
        guard gethostname(&name, Int(MAXHOSTNAMELEN)) == 0 else { return "micsync" }
        let raw = String(cString: name)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: ".local", with: "")
        // Sanitize to [A-Za-z0-9-]; strip leading/trailing hyphens (RFC 952).
        let clean = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .drop { $0 == "-" }
            .reversed()
            .drop { $0 == "-" }
            .reversed()
        return clean.isEmpty ? "micsync" : String(clean)
    }

    // ----------------------------------------------------------
    // Server state (core queue)
    // ----------------------------------------------------------
    private let queue = DispatchQueue(label: "com.yurifrl.micsync.remote", qos: .userInitiated)
    private let core = WSServerCore(queue: DispatchQueue(label: "com.yurifrl.micsync.remote.ws", qos: .userInitiated))
    private let preferences = Preferences()

    // WS connections that completed auth, keyed by connection identity.
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]

    private var cancellables: [AnyCancellable] = []

    private var enabled: Bool { preferences.remoteEnabled }
    private var token: String? { preferences.remoteToken }

    // ----------------------------------------------------------
    // Lifecycle
    // ----------------------------------------------------------

    // Called by the AppDelegate after construction: applies the stored
    // preference and subscribes to later flips of it.
    func start() {
        // State pushes. These publish on the main thread.
        let engine = SyncEngine.shared
        engine.$desiredState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.engineStateChanged() }
            .store(in: &cancellables)
        engine.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.engineStateChanged() }
            .store(in: &cancellables)

        // Preference flips (enable/disable, token regeneration).
        NotificationCenter.default.addObserver(
            forName: Preferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyEnabledState()
        }

        applyEnabledState()
    }

    func stop() {
        cancellables.removeAll()
        core.stop()
        subscribers.removeAll()
    }

    // Settings "regenerate" button: new token → old pairings invalid.
    func regenerateToken() -> String {
        let fresh = Self.newToken()
        preferences.remoteToken = fresh
        return fresh
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 15) // 20 base32 chars
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Unreachable in practice; fall back to arc4random.
            for i in bytes.indices { bytes[i] = UInt8(arc4random_uniform(256)) }
        }
        return base32(bytes)
    }

    // RFC 4648 base32, unpadded (A–Z, 2–7: URL-safe, pronounceable).
    private static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 31])
        }
        return out
    }

    // Applies the stored preference: starts/stops the listener + Bonjour.
    private func applyEnabledState() {
        guard enabled else {
            queue.async { [self] in
                core.stop()
                subscribers.removeAll()
            }
            return
        }
        // First enable: mint the token once, persisted from here on.
        if token == nil {
            preferences.remoteToken = Self.newToken()
        }
        guard !core.listening else { return }
        startListener()
    }

    // ----------------------------------------------------------
    // Listener + Bonjour
    // ----------------------------------------------------------

    private func startListener() {
        let service = NWListener.Service(name: "MicSync", type: "_micsync._tcp", domain: nil)
        core.start(
            port: Self.port,
            reuse: true,
            loopback: false,
            bonjour: service
        )
        Log.info(.remote, nil, "remote control listening on port \(Self.port)")

        // One HTTP surface, token-gated. (The closure is set once; it
        // reads the CURRENT token from preferences on every request, so
        // regeneration invalidates old URLs immediately.)
        core.onHTTP = { [weak self] request in
            guard let self else { return }
            self.queue.async {
                self.handleHTTP(request)
            }
        }

        // WS auth happens at upgrade time, on the core queue, before the
        // 101 goes out; rejected connections get 403. Reads the CURRENT
        // token so regeneration invalidates old pairings immediately.
        core.onWSUpgrade = { [weak self] request in
            guard let self else { return false }
            return self.authorized(request)
        }
        core.onWSAccept = { [weak self] connection, _ in
            let id = ObjectIdentifier(connection)
            self?.queue.async {
                self?.subscribers[id] = connection
                self?.engineStateChanged()
            }
        }
        core.onDrop = { [weak self] connection in
            let id = ObjectIdentifier(connection)
            self?.queue.async {
                self?.subscribers.removeValue(forKey: id)
            }
        }
    }

    // ----------------------------------------------------------
    // HTTP routing
    // ----------------------------------------------------------

    // CORS allow-all for browser clients; native apps ignore these.
    private static let corsHeaders = ["Access-Control-Allow-Origin: *"]

    private func handleHTTP(_ request: WSServerCore.HTTPRequest) {
        // Web (browser) clients always preflight credentialed-header requests;
        // answer them regardless of the token so the pairing-page origin can
        // reach /status. Native clients never send OPTIONS.
        if request.method == "OPTIONS" {
            request.respond("HTTP/1.1 204 No Content", [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET",
                "Access-Control-Allow-Headers: Authorization",
                "Access-Control-Max-Age: 600",
            ], nil)
            return
        }
        // The pairing page is the QR destination: the token rides in the
        // URL fragment (#...), which browsers never transmit — the page
        // must be reachable without it. Everything else is token-gated.
        if request.path != "/" {
            guard authorized(request) else {
                request.respond("HTTP/1.1 403 Forbidden", ["Content-Type: text/plain; charset=utf-8"] + Self.corsHeaders, Data("forbidden".utf8))
                return
            }
        }
        switch request.path {
        case "/":
            request.respond("HTTP/1.1 200 OK", ["Content-Type: text/html; charset=utf-8"] + Self.corsHeaders, Data(Self.pairingPage(token: token ?? "").utf8))
        case "/status":
            // The engine publishes on main; build the payload there.
            DispatchQueue.main.async { [weak self] in
                request.respond("HTTP/1.1 200 OK", ["Content-Type: application/json"] + Self.corsHeaders, self?.statusBody() ?? Data("{}".utf8))
            }
        case "/mute", "/unmute", "/toggle", "/ptt/1", "/ptt/0":
            dispatchCommand(request)
        default:
            request.respond("HTTP/1.1 404 Not Found", ["Content-Type: text/plain; charset=utf-8"] + Self.corsHeaders, Data("not found".utf8))
        }
    }

    private func authorized(_ request: WSServerCore.HTTPRequest) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if request.query["token"] == token { return true }
        if let header = request.headers["authorization"] {
            let parts = header.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" && parts[1] == token
        }
        return false
    }

    // Builds the wire status. Reads engine @Published state; MUST run on
    // the main thread (the engine publishes there).
    private func statusBody() -> Data {
        assert(Thread.isMainThread)
        let engine = SyncEngine.shared
        var object: [String: Any] = [
            "v": 1,
            "ok": true,
            "desired": desiredJSON(engine.desiredState),
        ]
        var sessions: [[String: Any]] = []
        for kind in SessionKind.allCases {
            if let snap = engine.snapshots[kind], snap.inCall {
                sessions.append([
                    "kind": kind.rawValue,
                    "muted": snap.state == .unknown ? NSNull() : NSNumber(value: snap.state == .muted),
                ])
            }
        }
        object["sessions"] = sessions
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // One mapping layer: engine types → wire JSON. No engine renames.
    // Contract (shared with the phone module): `desired` is the MicGoal
    // case name as a string — "live" | "muted" — or JSON null when no
    // goal is set. NOT a boolean.
    private func desiredJSON(_ goal: MicGoal?) -> Any {
        switch goal {
        case .live: return "live"
        case .muted: return "muted"
        case nil: return NSNull()
        }
    }

    // ----------------------------------------------------------
    // Commands
    // ----------------------------------------------------------

    // Dispatches into the engine and answers once the engine's callback
    // for THIS command settles (mute/unmute/ptt) — or right after the
    // one reconciliation read for toggle. 409 on engine-reported no-op.
    private func dispatchCommand(_ request: WSServerCore.HTTPRequest) {
        let engine = SyncEngine.shared
        let path = request.path
        let done: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            // The engine acks on its queue; the status payload needs main
            // (Published reads) and the core needs its own queue. Fan out
            // once per settle: main builds JSON, remote queue answers.
            DispatchQueue.main.async { [weak self] in
                let body = self?.statusBody() ?? Data()
                self?.queue.async {
                    if ok {
                        request.respond("HTTP/1.1 200 OK", ["Content-Type: application/json"] + Self.corsHeaders, body)
                    } else {
                        request.respond("HTTP/1.1 409 Conflict", ["Content-Type: application/json"] + Self.corsHeaders, body)
                    }
                }
            }
        }
        switch path {
        case "/mute":
            engine.mute(ack: done)
        case "/unmute":
            engine.unmute(ack: done)
        case "/ptt/1":
            engine.pushToTalk(down: true, ack: done)
        case "/ptt/0":
            engine.pushToTalk(down: false, ack: done)
        case "/toggle":
            engine.toggle(ack: done)
        default:
            done(false)
        }
    }

    // ----------------------------------------------------------
    // WS state push
    // ----------------------------------------------------------

    // Called from the main thread whenever an observable engine input
    // moved (desiredState, snapshots) or a WS client connected.
    private func engineStateChanged() {
        queue.async { [self] in
            guard !subscribers.isEmpty else { return }
            // Payload builds on main (Published reads); core broadcasts
            // on its own queue.
            DispatchQueue.main.async { [weak self] in
                let body = self?.statusBody() ?? Data()
                self?.queue.async {
                    self?.broadcastState(body)
                }
            }
        }
    }

    private func broadcastState(_ body: Data) {
        guard !subscribers.isEmpty else { return }
        var frame: [String: Any] = [:]
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            frame = object
        }
        frame["type"] = "state"
        core.broadcast(frame)
    }

    // ----------------------------------------------------------
    // Static pairing page (no scripts: usable as a QR destination)
    // ----------------------------------------------------------

    private static func pairingPage(token: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>MicSync Remote</title></head>
        <body>
        <h1>MicSync is paired.</h1>
        <p>Open this URL in the MicSync app.</p>
        <p>Host: \(hostName).local</p>
        </body>
        </html>
        """
    }
}
