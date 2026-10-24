import Foundation

/// obs-websocket v5 wire protocol (the one Stream Deck, Touch Portal, Bitfocus
/// Companion and friends speak). This is the transport-independent half: message
/// framing, the Hello/Identify handshake with SHA-256 auth, request routing and
/// event construction. The app plugs in a `OBSWebSocketRequestHandler` that maps
/// request types onto the engine and a WebSocket server for bytes.
public enum OBSWebSocket {
    public static let protocolVersion = 1
    public static let obsWebSocketVersion = "5.5.0"

    public enum OpCode: Int {
        case hello = 0
        case identify = 1
        case identified = 2
        case reidentify = 3
        case event = 5
        case request = 6
        case requestResponse = 7
        case requestBatch = 8
        case requestBatchResponse = 9
    }

    /// RequestStatus codes from the spec that the handler is expected to use.
    public enum StatusCode: Int {
        case unknown = 0
        case noError = 10
        case success = 100
        case missingRequestType = 203
        case unknownRequestType = 204
        case genericError = 205
        case unsupportedRequestType = 206
        case missingRequestField = 300
        case missingRequestData = 301
        case invalidRequestField = 400
        case invalidRequestFieldType = 401
        case requestFieldOutOfRange = 402
        case requestFieldEmpty = 403
        case tooManyRequestFields = 404
        case outputRunning = 500
        case outputNotRunning = 501
        case outputPaused = 502
        case outputNotPaused = 503
        case outputDisabled = 504
        case studioModeActive = 505
        case studioModeNotActive = 506
        case resourceNotFound = 600
        case resourceAlreadyExists = 601
        case invalidResourceType = 602
        case notEnoughResources = 603
        case invalidResourceState = 604
        case invalidInputKind = 605
        case resourceNotConfigurable = 606
        case invalidFilterKind = 607
        case resourceCreationFailed = 700
        case resourceActionFailed = 701
        case requestProcessingFailed = 702
        case cannotAct = 703
    }

    /// Event subscription bit flags.
    public enum EventSubscription {
        public static let none = 0
        public static let general = 1 << 0
        public static let config = 1 << 1
        public static let scenes = 1 << 2
        public static let inputs = 1 << 3
        public static let transitions = 1 << 4
        public static let filters = 1 << 5
        public static let outputs = 1 << 6
        public static let sceneItems = 1 << 7
        public static let mediaInputs = 1 << 8
        public static let vendors = 1 << 9
        public static let ui = 1 << 10
        public static let all = general | config | scenes | inputs | transitions | filters | outputs | sceneItems | mediaInputs | vendors | ui
        public static let inputVolumeMeters = 1 << 16
        public static let inputActiveStateChanged = 1 << 17
        public static let inputShowStateChanged = 1 << 18
        public static let sceneItemTransformChanged = 1 << 19
    }

    public struct RequestResult {
        public var code: StatusCode
        public var comment: String?
        public var data: JSONValue?

        public init(code: StatusCode = .success, comment: String? = nil, data: JSONValue? = nil) {
            self.code = code
            self.comment = comment
            self.data = data
        }

        public static func ok(_ data: JSONValue? = nil) -> RequestResult { RequestResult(data: data) }
        public static func error(_ code: StatusCode, _ comment: String? = nil) -> RequestResult { RequestResult(code: code, comment: comment) }
    }

    /// Authentication helpers (spec section "Creating an authentication string").
    public enum Auth {
        public static func salt() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            return Data(bytes).base64EncodedString()
        }

        public static func challenge() -> String { salt() }

        /// base64(sha256(password + salt))
        public static func secret(password: String, salt: String) -> String {
            SHA256.base64(password + salt)
        }

        /// base64(sha256(secret + challenge))
        public static func authentication(password: String, salt: String, challenge: String) -> String {
            SHA256.base64(secret(password: password, salt: salt) + challenge)
        }
    }

    public static func envelope(op: OpCode, d: JSONValue) -> JSONValue {
        .object(["op": .number(Double(op.rawValue)), "d": d])
    }

    public static func event(type: String, intent: Int, data: JSONValue?) -> JSONValue {
        var d: [String: JSONValue] = ["eventType": .string(type), "eventIntent": .number(Double(intent))]
        if let data { d["eventData"] = data }
        return envelope(op: .event, d: .object(d))
    }
}

public protocol OBSWebSocketRequestHandler: AnyObject {
    func handle(requestType: String, requestData: JSONValue?) -> OBSWebSocket.RequestResult
}

/// Per-connection protocol state. Create one per accepted WebSocket.
public final class OBSWebSocketConnection {
    public enum Phase: Equatable {
        case awaitingIdentify
        case identified
        case closed(code: Int, reason: String)
    }

    public private(set) var phase: Phase = .awaitingIdentify
    public private(set) var eventSubscriptions: Int = OBSWebSocket.EventSubscription.all
    public let password: String
    public let rpcVersion = OBSWebSocket.protocolVersion
    private let challenge: String
    private let salt: String
    public weak var handler: OBSWebSocketRequestHandler?

    public init(password: String, handler: OBSWebSocketRequestHandler?) {
        self.password = password
        self.handler = handler
        challenge = OBSWebSocket.Auth.challenge()
        salt = OBSWebSocket.Auth.salt()
    }

    /// First message the server sends.
    public func hello() -> JSONValue {
        var d: [String: JSONValue] = [
            "obsWebSocketVersion": .string(OBSWebSocket.obsWebSocketVersion),
            "rpcVersion": .number(Double(rpcVersion)),
        ]
        if !password.isEmpty {
            d["authentication"] = .object(["challenge": .string(challenge), "salt": .string(salt)])
        }
        return OBSWebSocket.envelope(op: .hello, d: .object(d))
    }

    public var requiresAuthentication: Bool { !password.isEmpty }

    /// Handles one incoming JSON text frame. Returns zero or more frames to send.
    /// A `.closed` phase afterwards means the server should close the socket with that code.
    public func receive(_ text: String) -> [JSONValue] {
        guard let msg = try? JSONValue.parse(text), let opRaw = msg["op"]?.intValue else {
            phase = .closed(code: 4002, reason: "Message decode error")
            return []
        }
        guard let op = OBSWebSocket.OpCode(rawValue: opRaw) else {
            phase = .closed(code: 4005, reason: "Unknown opcode")
            return []
        }
        let d = msg["d"] ?? .object([:])
        switch (phase, op) {
        case (.awaitingIdentify, .identify):
            return identify(d)
        case (.awaitingIdentify, _):
            phase = .closed(code: 4008, reason: "Not identified")
            return []
        case (.identified, .reidentify):
            if let subs = d["eventSubscriptions"]?.intValue { eventSubscriptions = subs }
            return [OBSWebSocket.envelope(op: .identified, d: .object(["negotiatedRpcVersion": .number(Double(rpcVersion))]))]
        case (.identified, .request):
            return [handleRequest(d)]
        case (.identified, .requestBatch):
            return [handleBatch(d)]
        case (.identified, .identify):
            phase = .closed(code: 4009, reason: "Already identified")
            return []
        case (.identified, _):
            phase = .closed(code: 4005, reason: "Unsupported opcode for client")
            return []
        case (.closed, _):
            return []
        }
    }

    private func identify(_ d: JSONValue) -> [JSONValue] {
        guard let rpc = d["rpcVersion"]?.intValue else {
            phase = .closed(code: 4006, reason: "Missing rpcVersion")
            return []
        }
        guard rpc == rpcVersion else {
            phase = .closed(code: 4010, reason: "Unsupported rpcVersion")
            return []
        }
        if requiresAuthentication {
            let expected = OBSWebSocket.Auth.authentication(password: password, salt: salt, challenge: challenge)
            guard let auth = d["authentication"]?.stringValue else {
                phase = .closed(code: 4007, reason: "Authentication required")
                return []
            }
            guard auth == expected else {
                phase = .closed(code: 4009, reason: "Authentication failed")
                return []
            }
        }
        if let subs = d["eventSubscriptions"]?.intValue { eventSubscriptions = subs }
        phase = .identified
        return [OBSWebSocket.envelope(op: .identified, d: .object(["negotiatedRpcVersion": .number(Double(rpcVersion))]))]
    }

    private func handleRequest(_ d: JSONValue) -> JSONValue {
        let type = d["requestType"]?.stringValue ?? ""
        let id = d["requestId"]?.stringValue ?? ""
        let result = perform(type: type, data: d["requestData"])
        return OBSWebSocket.envelope(op: .requestResponse, d: responseBody(type: type, id: id, result: result))
    }

    private func perform(type: String, data: JSONValue?) -> OBSWebSocket.RequestResult {
        if type.isEmpty { return .error(.missingRequestType) }
        guard let handler else { return .error(.requestProcessingFailed, "No handler") }
        return handler.handle(requestType: type, requestData: data)
    }

    private func responseBody(type: String, id: String, result: OBSWebSocket.RequestResult) -> JSONValue {
        var status: [String: JSONValue] = [
            "result": .bool(result.code == .success),
            "code": .number(Double(result.code.rawValue)),
        ]
        if let c = result.comment { status["comment"] = .string(c) }
        var body: [String: JSONValue] = [
            "requestType": .string(type),
            "requestId": .string(id),
            "requestStatus": .object(status),
        ]
        if let data = result.data { body["responseData"] = data }
        return .object(body)
    }

    private func handleBatch(_ d: JSONValue) -> JSONValue {
        let id = d["requestId"]?.stringValue ?? ""
        let haltOnFailure = d["haltOnFailure"]?.boolValue ?? false
        var results: [JSONValue] = []
        for req in d["requests"]?.arrayValue ?? [] {
            let type = req["requestType"]?.stringValue ?? ""
            let rid = req["requestId"]?.stringValue ?? ""
            let result = perform(type: type, data: req["requestData"])
            results.append(responseBody(type: type, id: rid, result: result))
            if haltOnFailure && result.code != .success { break }
        }
        return OBSWebSocket.envelope(op: .requestBatchResponse, d: .object(["requestId": .string(id), "results": .array(results)]))
    }

    /// Whether this client asked for events in `intent`.
    public func wantsEvent(intent: Int) -> Bool {
        phase == .identified && (eventSubscriptions & intent) != 0
    }
}
