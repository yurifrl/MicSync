import Foundation
import Network
import CryptoKit

// Shared WebSocket server core, extracted from MeetBridge (behavior
// preserving). Owns the NWListener, connection lifecycle, the RFC 6455
// handshake, frame parse/encode, per-connection receive buffers, and
// broadcast. Delegates everything above the wire to one owner:
//
//   - every HTTP request that is not the WS upgrade (path + headers +
//     a caller-supplied reply callback), and
//   - every complete text frame received on an established connection.
//
// Queue-confined: the delegate callbacks always arrive on `queue`; the
// owner must not hold long work there.

final class WSServerCore {
    // One HTTP request delivered before the WebSocket upgrade. `respond`
    // writes the caller-supplied status line + headers (CRLF-terminated
    // each) + optional body and closes the connection — there is no
    // keep-alive: MicSync's HTTP surface is one-shot commands.
    struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String] // percent-decoded
        let headers: [String: String] // lowercased names
        let connection: NWConnection
        let respond: (_ statusLine: String, _ headers: [String], _ body: Data?) -> Void
    }

    // All callbacks run on `queue`.
    var onAccept: ((NWConnection) -> Void)? // inbound TCP connection, pre-handshake
    var onHTTP: ((HTTPRequest) -> Void)?
    var onWSAccept: ((NWConnection, [String: String]) -> Void)? // upgrade completed; args: connection, query
    var onWSText: ((String, NWConnection) -> Void)?
    var onDrop: ((NWConnection) -> Void)? // connection gone (failure/cancel/EOF)
    var onListenError: ((String) -> Void)? // port unavailable / listener failed

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    // Partial frames / pending HTTP request per connection.
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var handshaken: Set<ObjectIdentifier> = []
    // Replace-on-connect policy (see accept).
    private let singleConnection: Bool

    init(queue: DispatchQueue, singleConnection: Bool = false) {
        self.queue = queue
        self.singleConnection = singleConnection
    }

    // ----------------------------------------------------------
    // Lifecycle
    // ----------------------------------------------------------

    // Binds and starts. `reuse` sets allowLocalEndpointReuse; `loopback`
    // pins the listener to 127.0.0.1 instead of exposing it on the LAN.
    // `bonjour` optionally advertises the service (mDNS).
    func start(port: UInt16, reuse: Bool, loopback: Bool, bonjour: NWListener.Service? = nil) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = reuse
        if loopback {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
        }
        let listener: NWListener
        do {
            if loopback {
                // The port travels inside requiredLocalEndpoint. The `on:`
                // variant would try to override it and Network.framework
                // faults the copy ("Local endpoint has port set").
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            }
        } catch {
            onListenError?("Port \(port) is unavailable (\(error.localizedDescription)). Close the app using it and relaunch MicSync.")
            return
        }
        listener.service = bonjour
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.queue.async {
                    self?.onListenError?("Port \(port) is unavailable (\(error.localizedDescription)). Close the app using it and relaunch MicSync.")
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection)
            }
        }
        self.listener = listener
        listening = true
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listening = false
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
            buffers.removeAll()
            handshaken.removeAll()
        }
    }

    // True while the listener is bound (used by applyEnabledState to
    // avoid double-starts). Read on any queue; set/cleared on core queue.
    private(set) var listening = false

    // WS upgrade request, delivered on the core queue BEFORE the 101 goes
    // out. Return false to reject: the core answers 403 and cancels.
    var onWSUpgrade: ((HTTPRequest) -> Bool)?

    var connectionCount: Int { connections.count }

    // ----------------------------------------------------------
    // Connection lifecycle
    // ----------------------------------------------------------

    // `singleConnection` replaces any existing connection on a new inbound
    // TCP connect (extension semantics: exactly one live Chrome socket;
    // MeetBridge relies on it). The old socket is cancelled; its eventual
    // .cancelled/.failed state is ignored by drop's membership check.
    private func accept(_ connection: NWConnection) {
        if singleConnection {
            for old in connections {
                old.cancel()
            }
        }
        onAccept?(connection)
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    self.drop(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    // Owner-requested close (e.g. MeetBridge replaces its extension socket).
    func close(_ connection: NWConnection) {
        connection.cancel()
    }

    private func drop(_ connection: NWConnection) {
        guard connections.contains(where: { $0 === connection }) else { return }
        connections.removeAll { $0 === connection }
        buffers.removeValue(forKey: ObjectIdentifier(connection))
        handshaken.remove(ObjectIdentifier(connection))
        onDrop?(connection)
    }

    // ----------------------------------------------------------
    // Receive loop
    // ----------------------------------------------------------

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, error == nil else { return }
            if let data, !data.isEmpty {
                self.queue.async {
                    self.ingest(data, from: connection)
                }
            }
            if isComplete {
                self.queue.async {
                    self.drop(connection)
                }
                return
            }
            self.receive(connection)
        }
    }

    private func ingest(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = buffers[key] ?? Data()
        buffer.append(data)
        if connections.first(where: { $0 === connection }) == nil {
            buffers.removeValue(forKey: key)
            return
        }
        if handshaken.contains(key) {
            buffers[key] = parseFrames(buffer, from: connection)
        } else {
            buffers[key] = deliverHTTPorUpgrade(buffer, connection)
        }
    }

    // Pre-handshake bytes: accumulate until the HTTP request is complete,
    // then either hand it to the owner (plain HTTP) or perform the WS
    // upgrade. Returns whatever bytes arrived beyond the response.
    private func deliverHTTPorUpgrade(_ buffer: Data, _ connection: NWConnection) -> Data {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer // wait for the full request
        }
        let header = Data(buffer[..<range.lowerBound])
        guard let headerText = String(data: header, encoding: .utf8) else {
            connection.cancel()
            return Data()
        }
        // Parse request line + headers (lowercased names).
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines[0].split(separator: " ")
        let method = requestParts.count > 0 ? String(requestParts[0]).uppercased() : ""
        let target = requestParts.count > 1 ? String(requestParts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Split target into path + query.
        let rawPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let query: [String: String]
        if let q = target.split(separator: "?", maxSplits: 1).dropFirst().first {
            var parsed: [String: String] = [:]
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                parsed[k] = v
            }
            query = parsed
        } else {
            query = [:]
        }

        if headers["upgrade"]?.lowercased() == "websocket" {
            // RFC 6455 upgrades are GET-only; anything else is garbage.
            guard method == "GET" else {
                connection.cancel()
                return Data()
            }
            let upgrade = HTTPRequest(
                method: method,
                path: rawPath,
                query: query,
                headers: headers,
                connection: connection,
                respond: { _, _, _ in }
            )
            // Owner auth gate: false → 403 + cancel (no 101 goes out).
            if let gate = onWSUpgrade, !gate(upgrade) {
                respondHTTP("HTTP/1.1 403 Forbidden", ["Content-Type: text/plain; charset=utf-8"], Data("forbidden".utf8), to: connection)
                return Data()
            }
            return upgradeWebSocket(headers, buffer, range, connection)
        }
        // Plain HTTP: hand it to the owner with a one-shot respond closure.
        let request = HTTPRequest(
            method: method,
            path: rawPath,
            query: query,
            headers: headers,
            connection: connection,
            respond: { [weak self, weak connection] statusLine, headerLines, body in
                guard let self, let connection else { return }
                self.queue.async {
                    self.respondHTTP(statusLine, headerLines, body, to: connection)
                }
            }
        )
        onHTTP?(request)
        // Extra pipelined bytes after a one-shot HTTP request are ignored.
        return Data()
    }

    // Consumes the upgrade request, writes the 101 response, and returns
    // whatever bytes arrived beyond the handshake (start of frames).
    private func upgradeWebSocket(_ headers: [String: String], _ buffer: Data, _ range: Range<Data.Index>, _ connection: NWConnection) -> Data {
        guard let key = headers["sec-websocket-key"], !key.isEmpty else {
            connection.cancel()
            return Data()
        }
        let accept = Data(Insecure.SHA1.hash(data: Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8)))
            .base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

        handshaken.insert(ObjectIdentifier(connection))
        onWSAccept?(connection, [:])
        return Data(buffer[range.upperBound...])
    }

    private func respondHTTP(_ statusLine: String, _ headerLines: [String], _ body: Data?, to connection: NWConnection) {
        var response = statusLine + "\r\n"
        for line in headerLines {
            response += line + "\r\n"
        }
        if let body, !body.isEmpty {
            response += "Content-Length: \(body.count)\r\n"
            response += "\r\n"
            connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        } else {
            response += "\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        }
    }

    // ----------------------------------------------------------
    // Frame protocol
    // ----------------------------------------------------------

    // Parses zero or more complete frames out of `buffer`, dispatches them,
    // and returns the remaining partial bytes.
    private func parseFrames(_ buffer: Data, from connection: NWConnection) -> Data {
        var rest = buffer
        while let (frame, remainder) = nextFrame(rest) {
            rest = remainder
            switch frame.opcode {
            case 0x1, 0x2: // text (binary never expected, handled the same)
                if let text = String(data: frame.payload, encoding: .utf8) {
                    onWSText?(text, connection)
                }
            case 0x8: // close
                sendFrame(0x8, frame.payload, to: connection)
                connection.cancel()
                return Data()
            case 0x9: // ping → pong with the same payload
                sendFrame(0xA, frame.payload, to: connection)
            case 0xA: // pong → ignore
                break
            default:
                connection.cancel()
                return Data()
            }
        }
        return rest
    }

    // Minimal RFC 6455 read. Client frames are always masked (per spec);
    // unmasked reads still succeed. Continuation/fragmented frames are not
    // produced for the small JSON payloads this protocol exchanges; a
    // continuation frame cancels the connection.
    private func nextFrame(_ data: Data) -> ((opcode: UInt8, payload: Data), Data)? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.index(after: data.startIndex)]
        let opcode = b0 & 0x0F
        var offset = data.startIndex + 2
        var length = Int(b1 & 0x7F)
        let masked = (b1 & 0x80) != 0
        if length == 126 {
            guard data.count >= offset + 2 else { return nil }
            length = Int(beat(data, offset, 2))
            offset += 2
        } else if length == 127 {
            guard data.count >= offset + 8 else { return nil }
            length = Int(beat(data, offset, 8))
            offset += 8
        }
        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = Array(data[offset ..< offset + 4])
            offset += 4
        }
        guard data.count >= offset + length else { return nil }
        var payload = Array(data[offset ..< offset + length])
        offset += length
        for i in payload.indices where masked {
            payload[i] ^= maskKey[i % 4]
        }
        return ((opcode, Data(payload)), Data(data[offset...]))
    }

    private func beat(_ data: Data, _ index: Data.Index, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< count {
            value = (value << 8) | UInt64(data[data.index(index, offsetBy: i)])
        }
        return value
    }

    // ----------------------------------------------------------
    // Sending
    // ----------------------------------------------------------

    // Server → client frames are never masked.
    func sendFrame(_ opcode: UInt8, _ payload: Data, to connection: NWConnection) {
        var header = Data([0x80 | opcode])
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            header.append(126)
            header.append(UInt8((payload.count >> 8) & 0xFF))
            header.append(UInt8(payload.count & 0xFF))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        connection.send(content: header + payload, completion: .contentProcessed { _ in })
    }

    // Encodes one JSON object and sends it as a text frame on every live
    // connection. Any queue: hops to the core queue internally.
    func broadcast(_ object: [String: Any]) {
        queue.async { [self] in
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            for connection in connections {
                sendFrame(0x1, data, to: connection)
            }
        }
    }
}
