import Foundation
import Network
import UpstageCore

/// What the app exposes to remote control. Every call runs on the main queue.
protocol RemoteControlHost: AnyObject {
    func rcVersionInfo() -> JSONValue
    func rcStats() -> JSONValue
    func rcSceneList() -> (current: String, preview: String?, scenes: [String])
    func rcSetProgramScene(_ name: String) -> Bool
    func rcSetPreviewScene(_ name: String) -> Bool
    func rcStudioMode() -> Bool
    func rcSetStudioMode(_ on: Bool)
    func rcTriggerTransition()
    func rcInputs() -> [(name: String, kind: String, muted: Bool, volumeDB: Double)]
    func rcSetMute(_ input: String, muted: Bool?) -> Bool
    func rcSetVolume(_ input: String, db: Double?, mul: Double?) -> Bool
    func rcStreamStatus() -> (active: Bool, reconnecting: Bool, seconds: Double, bytes: UInt64, skipped: Int, total: Int, congestion: Double)
    func rcStartStream() -> Bool
    func rcStopStream() -> Bool
    func rcRecordStatus() -> (active: Bool, paused: Bool, seconds: Double, bytes: Int64, path: String?)
    func rcStartRecord() -> Bool
    func rcStopRecord() -> String?
    func rcPauseRecord(_ pause: Bool) -> Bool
    func rcReplayStatus() -> Bool
    func rcSetReplay(_ on: Bool) -> Bool
    func rcSaveReplay() -> Bool
    func rcSceneItems(_ scene: String) -> [(id: Int, name: String, enabled: Bool)]?
    func rcSetSceneItemEnabled(_ scene: String, id: Int, enabled: Bool) -> Bool
    func rcHotkeyByName(_ name: String) -> Bool
}

/// obs-websocket v5 compatible server on top of Network.framework's WebSocket.
/// Stream Deck, Touch Portal, Bitfocus Companion and other obs-websocket
/// clients can connect to it as if it were OBS.
final class RemoteControlServer: OBSWebSocketRequestHandler {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "upstage.remote")
    private var connections: [ObjectIdentifier: (NWConnection, OBSWebSocketConnection)] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    private var password = ""
    weak var host: RemoteControlHost?
    private(set) var isRunning = false
    private(set) var lastError: String?
    var onClientCountChanged: ((Int) -> Void)?

    func start(port: UInt16, password: String) {
        stop()
        self.port = port
        self.password = password
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 * 1024 * 1024
        // obs-websocket-js (Companion, Touch Portal, browsers) requires this subprotocol.
        ws.setSubprotocols(["obswebsocket.json"])
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? 4455)
            l.service = NWListener.Service(name: "Upstage", type: "_obsws._tcp")
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .failed(let e): self?.lastError = e.localizedDescription; self?.isRunning = false
                case .ready: self?.isRunning = true; self?.lastError = nil
                case .cancelled: self?.isRunning = false
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let conns = connections.values.map { $0.0 }
        connections.removeAll()
        lock.unlock()
        conns.forEach { $0.cancel() }
        isRunning = false
    }

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    private func accept(_ conn: NWConnection) {
        let proto = OBSWebSocketConnection(password: password, handler: self)
        lock.lock()
        connections[ObjectIdentifier(conn)] = (conn, proto)
        lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                self.sendText(conn, proto.hello().serializedString)
                self.receive(conn, proto)
                self.onClientCountChanged?(self.clientCount)
            case .failed, .cancelled:
                self.lock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                self.lock.unlock()
                self.onClientCountChanged?(self.clientCount)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, _ proto: OBSWebSocketConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, isComplete, error in
            guard let self, let conn else { return }
            if let error {
                _ = error
                conn.cancel()
                return
            }
            // EOF without a close frame (client vanished): stop re-arming.
            if data == nil && isComplete {
                conn.cancel()
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .close {
                    conn.cancel()
                    return
                }
                if meta.opcode != .text {
                    // ping/pong/binary: nothing for the protocol layer
                    self.receive(conn, proto)
                    return
                }
            }
            if let data, let text = String(data: data, encoding: .utf8) {
                let replies = proto.receive(text)
                for r in replies { self.sendText(conn, r.serializedString) }
                if case .closed(let code, let reason) = proto.phase {
                    self.close(conn, code: code, reason: reason)
                    return
                }
            }
            self.receive(conn, proto)
        }
    }

    private func sendText(_ conn: NWConnection, _ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func close(_ conn: NWConnection, code: Int, reason: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .applicationCode(UInt16(code))
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        conn.send(content: Data(reason.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Broadcasts an event to every identified client that subscribed to it.
    func broadcast(event type: String, intent: Int, data: JSONValue?) {
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        let msg = OBSWebSocket.event(type: type, intent: intent, data: data).serializedString
        for (conn, proto) in conns where proto.wantsEvent(intent: intent) {
            sendText(conn, msg)
        }
    }

    // MARK: request routing (runs on the server queue; hops to main for the host)

    func handle(requestType: String, requestData: JSONValue?) -> OBSWebSocket.RequestResult {
        var result = OBSWebSocket.RequestResult.error(.unknownRequestType)
        let work = { result = self.route(requestType, requestData) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    private func route(_ type: String, _ d: JSONValue?) -> OBSWebSocket.RequestResult {
        guard let host else { return .error(.requestProcessingFailed, "No host") }
        func str(_ k: String) -> String? { d?[k]?.stringValue }
        func bool(_ k: String) -> Bool? { d?[k]?.boolValue }
        func num(_ k: String) -> Double? { d?[k]?.doubleValue }

        switch type {
        case "GetVersion":
            return .ok(host.rcVersionInfo())
        case "GetStats":
            return .ok(host.rcStats())
        case "BroadcastCustomEvent":
            broadcast(event: "CustomEvent", intent: OBSWebSocket.EventSubscription.general, data: d?["eventData"])
            return .ok()
        case "GetHotkeyList":
            return .ok(["hotkeys": .array(ControlAction.global.map { .string($0.label) })])
        case "TriggerHotkeyByName":
            guard let name = str("hotkeyName") else { return .error(.missingRequestField, "hotkeyName") }
            return host.rcHotkeyByName(name) ? .ok() : .error(.resourceNotFound, "No hotkey \(name)")
        case "Sleep":
            return .ok()

        case "GetSceneList":
            let l = host.rcSceneList()
            let scenes = l.scenes.enumerated().reversed().map { (i, name) -> JSONValue in
                .object(["sceneName": .string(name), "sceneIndex": .number(Double(i)), "sceneUuid": .string(name)])
            }
            var out: [String: JSONValue] = ["currentProgramSceneName": .string(l.current), "currentProgramSceneUuid": .string(l.current), "scenes": .array(scenes)]
            out["currentPreviewSceneName"] = l.preview.map { .string($0) } ?? .null
            out["currentPreviewSceneUuid"] = l.preview.map { .string($0) } ?? .null
            return .ok(.object(out))
        case "GetCurrentProgramScene":
            let l = host.rcSceneList()
            return .ok(["currentProgramSceneName": .string(l.current), "sceneName": .string(l.current), "sceneUuid": .string(l.current)])
        case "SetCurrentProgramScene":
            guard let name = str("sceneName") else { return .error(.missingRequestField, "sceneName") }
            return host.rcSetProgramScene(name) ? .ok() : .error(.resourceNotFound, "No scene named \(name)")
        case "GetCurrentPreviewScene":
            let l = host.rcSceneList()
            guard host.rcStudioMode(), let p = l.preview else { return .error(.studioModeNotActive) }
            return .ok(["currentPreviewSceneName": .string(p), "sceneName": .string(p), "sceneUuid": .string(p)])
        case "SetCurrentPreviewScene":
            guard host.rcStudioMode() else { return .error(.studioModeNotActive) }
            guard let name = str("sceneName") else { return .error(.missingRequestField, "sceneName") }
            return host.rcSetPreviewScene(name) ? .ok() : .error(.resourceNotFound, "No scene named \(name)")
        case "GetStudioModeEnabled":
            return .ok(["studioModeEnabled": .bool(host.rcStudioMode())])
        case "SetStudioModeEnabled":
            guard let on = bool("studioModeEnabled") else { return .error(.missingRequestField, "studioModeEnabled") }
            host.rcSetStudioMode(on)
            return .ok()
        case "TriggerStudioModeTransition":
            guard host.rcStudioMode() else { return .error(.studioModeNotActive) }
            host.rcTriggerTransition()
            return .ok()

        case "GetInputList":
            let inputs = host.rcInputs().map { i -> JSONValue in
                .object(["inputName": .string(i.name), "inputUuid": .string(i.name), "inputKind": .string(i.kind), "unversionedInputKind": .string(i.kind)])
            }
            return .ok(["inputs": .array(inputs)])
        case "GetInputMute":
            guard let name = str("inputName"), let i = host.rcInputs().first(where: { $0.name == name }) else { return .error(.resourceNotFound) }
            return .ok(["inputMuted": .bool(i.muted)])
        case "SetInputMute":
            guard let name = str("inputName"), let m = bool("inputMuted") else { return .error(.missingRequestField) }
            return host.rcSetMute(name, muted: m) ? .ok() : .error(.resourceNotFound)
        case "ToggleInputMute":
            guard let name = str("inputName") else { return .error(.missingRequestField, "inputName") }
            guard host.rcSetMute(name, muted: nil) else { return .error(.resourceNotFound) }
            let muted = host.rcInputs().first { $0.name == name }?.muted ?? false
            return .ok(["inputMuted": .bool(muted)])
        case "GetInputVolume":
            guard let name = str("inputName"), let i = host.rcInputs().first(where: { $0.name == name }) else { return .error(.resourceNotFound) }
            return .ok(["inputVolumeMul": .number(Double(AudioMath.linear(fromDB: i.volumeDB))), "inputVolumeDb": .number(i.volumeDB)])
        case "SetInputVolume":
            guard let name = str("inputName") else { return .error(.missingRequestField, "inputName") }
            let db = num("inputVolumeDb"), mul = num("inputVolumeMul")
            guard db != nil || mul != nil else { return .error(.missingRequestField, "inputVolumeDb or inputVolumeMul") }
            return host.rcSetVolume(name, db: db, mul: mul) ? .ok() : .error(.resourceNotFound)

        case "GetStreamStatus":
            let s = host.rcStreamStatus()
            return .ok(["outputActive": .bool(s.active), "outputReconnecting": .bool(s.reconnecting), "outputTimecode": .string(RemoteControlServer.timecode(s.seconds)),
                        "outputDuration": .number(s.seconds * 1000), "outputCongestion": .number(s.congestion), "outputBytes": .number(Double(s.bytes)),
                        "outputSkippedFrames": .number(Double(s.skipped)), "outputTotalFrames": .number(Double(s.total))])
        case "StartStream":
            if host.rcStreamStatus().active { return .error(.outputRunning) }
            return host.rcStartStream() ? .ok() : .error(.invalidResourceState, "The stream could not start; check Settings > Stream")
        case "StopStream":
            return host.rcStopStream() ? .ok() : .error(.outputNotRunning)
        case "ToggleStream":
            let active = host.rcStreamStatus().active
            if active { _ = host.rcStopStream() } else { _ = host.rcStartStream() }
            return .ok(["outputActive": .bool(host.rcStreamStatus().active)])

        case "GetRecordStatus":
            let r = host.rcRecordStatus()
            return .ok(["outputActive": .bool(r.active), "outputPaused": .bool(r.paused), "outputTimecode": .string(RemoteControlServer.timecode(r.seconds)),
                        "outputDuration": .number(r.seconds * 1000), "outputBytes": .number(Double(r.bytes))])
        case "StartRecord":
            if host.rcRecordStatus().active { return .error(.outputRunning) }
            return host.rcStartRecord() ? .ok() : .error(.invalidResourceState, "Recording could not start; check Settings > Output")
        case "StopRecord":
            guard let path = host.rcStopRecord() else { return .error(.outputNotRunning) }
            return .ok(["outputPath": .string(path)])
        case "ToggleRecord":
            let r = host.rcRecordStatus()
            if r.active { _ = host.rcStopRecord() } else { _ = host.rcStartRecord() }
            return .ok(["outputActive": .bool(host.rcRecordStatus().active)])
        case "PauseRecord":
            return host.rcPauseRecord(true) ? .ok() : .error(.outputNotRunning)
        case "ResumeRecord":
            return host.rcPauseRecord(false) ? .ok() : .error(.outputNotPaused)
        case "ToggleRecordPause":
            let r = host.rcRecordStatus()
            return host.rcPauseRecord(!r.paused) ? .ok(["outputPaused": .bool(!r.paused)]) : .error(.outputNotRunning)

        case "GetReplayBufferStatus":
            return .ok(["outputActive": .bool(host.rcReplayStatus())])
        case "StartReplayBuffer":
            return host.rcSetReplay(true) ? .ok() : .error(.outputRunning)
        case "StopReplayBuffer":
            return host.rcSetReplay(false) ? .ok() : .error(.outputNotRunning)
        case "ToggleReplayBuffer":
            let on = host.rcReplayStatus()
            return host.rcSetReplay(!on) ? .ok(["outputActive": .bool(!on)]) : .error(.outputRunning)
        case "SaveReplayBuffer":
            return host.rcSaveReplay() ? .ok() : .error(.outputNotRunning)

        case "GetVirtualCamStatus":
            return .ok(["outputActive": .bool(false)])
        case "StartVirtualCam", "StopVirtualCam", "ToggleVirtualCam":
            return .error(.outputDisabled, "Virtual camera is not available in this version")

        case "GetSceneItemList":
            guard let scene = str("sceneName") else { return .error(.missingRequestField, "sceneName") }
            guard let items = host.rcSceneItems(scene) else { return .error(.resourceNotFound) }
            return .ok(["sceneItems": .array(items.enumerated().map { (i, it) in
                .object(["sceneItemId": .number(Double(it.id)), "sceneItemIndex": .number(Double(i)), "sourceName": .string(it.name), "sceneItemEnabled": .bool(it.enabled), "sourceType": .string("OBS_SOURCE_TYPE_INPUT")])
            })])
        case "SetSceneItemEnabled":
            guard let scene = str("sceneName"), let id = num("sceneItemId"), let on = bool("sceneItemEnabled") else { return .error(.missingRequestField) }
            return host.rcSetSceneItemEnabled(scene, id: Int(id), enabled: on) ? .ok() : .error(.resourceNotFound)
        case "GetSceneItemEnabled":
            guard let scene = str("sceneName"), let id = num("sceneItemId") else { return .error(.missingRequestField) }
            guard let it = host.rcSceneItems(scene)?.first(where: { $0.id == Int(id) }) else { return .error(.resourceNotFound) }
            return .ok(["sceneItemEnabled": .bool(it.enabled)])

        case "GetProfileList", "GetSceneCollectionList", "GetSceneTransitionList", "GetCurrentSceneTransition":
            return .error(.unsupportedRequestType, "\(type) is not implemented in Upstage yet")
        default:
            return .error(.unknownRequestType, "Unknown or unsupported request type: \(type)")
        }
    }

    static func timecode(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s / 3600), m = Int(s / 60) % 60, sec = Int(s) % 60, ms = Int((s - floor(s)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms)
    }
}
