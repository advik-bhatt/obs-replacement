import Foundation

/// Parsed rtmp:// or rtmps:// ingest URL.
public struct RTMPURL: Equatable {
    public var isTLS: Bool
    public var host: String
    public var port: UInt16
    /// Application name, may contain slashes and a query string (YouTube backup uses `live2?backup=1`).
    public var app: String

    public init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("rtmps://") {
            isTLS = true
            s.removeFirst("rtmps://".count)
        } else if s.lowercased().hasPrefix("rtmp://") {
            isTLS = false
            s.removeFirst("rtmp://".count)
        } else {
            return nil
        }
        guard !s.isEmpty else { return nil }
        let slash = s.firstIndex(of: "/")
        let authority = slash.map { String(s[..<$0]) } ?? s
        var appPart = slash.map { String(s[s.index(after: $0)...]) } ?? ""
        guard !authority.isEmpty else { return nil }
        if let colon = authority.lastIndex(of: ":"), authority[authority.index(after: colon)...].allSatisfy(\.isNumber),
           let p = UInt16(authority[authority.index(after: colon)...]) {
            host = String(authority[..<colon])
            port = p
        } else {
            host = authority
            port = isTLS ? 443 : 1935
        }
        guard !host.isEmpty else { return nil }
        while appPart.hasSuffix("/") { appPart.removeLast() }
        app = appPart
    }

    public var tcUrl: String {
        let scheme = isTLS ? "rtmps" : "rtmp"
        let defaultPort: UInt16 = isTLS ? 443 : 1935
        let portPart = port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portPart)/\(app)"
    }
}

/// Stream-level metadata sent as @setDataFrame/onMetaData.
public struct RTMPStreamMetadata: Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoBitrateKbps: Int
    public var audioBitrateKbps: Int
    public var audioSampleRate: Int
    public var audioChannels: Int
    public var encoder: String

    public init(width: Int, height: Int, frameRate: Double, videoBitrateKbps: Int, audioBitrateKbps: Int,
                audioSampleRate: Int = 48000, audioChannels: Int = 2, encoder: String = "Upstage") {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrateKbps = videoBitrateKbps
        self.audioBitrateKbps = audioBitrateKbps
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.encoder = encoder
    }

    public var amf: AMF0Value {
        .ecmaArray([
            ("duration", .number(0)),
            ("width", .number(Double(width))),
            ("height", .number(Double(height))),
            ("videodatarate", .number(Double(videoBitrateKbps))),
            ("framerate", .number(frameRate)),
            ("videocodecid", .number(7)),
            ("audiodatarate", .number(Double(audioBitrateKbps))),
            ("audiosamplerate", .number(Double(audioSampleRate))),
            ("audiosamplesize", .number(16)),
            ("audiochannels", .number(Double(audioChannels))),
            ("stereo", .bool(audioChannels == 2)),
            ("audiocodecid", .number(10)),
            ("encoder", .string(encoder)),
            ("filesize", .number(0)),
        ])
    }
}

public enum RTMPSessionError: Error, Equatable, CustomStringConvertible {
    case handshakeFailed(String)
    case connectRejected(String)
    case publishRejected(String)
    case protocolError(String)
    case notPublishing

    public var description: String {
        switch self {
        case .handshakeFailed(let s): return "RTMP handshake failed: \(s)"
        case .connectRejected(let s): return "Server rejected connect: \(s)"
        case .publishRejected(let s): return "Server rejected publish: \(s)"
        case .protocolError(let s): return "RTMP protocol error: \(s)"
        case .notPublishing: return "Not publishing yet"
        }
    }
}

/// Transport-agnostic RTMP publishing state machine. The app owns the socket
/// and calls `start()` for the bytes to send first, then `receive(_:)` with
/// whatever arrives; each returns bytes that must be written back. Once
/// `state == .publishing`, `video/audio/metadata` return chunked bytes to send.
public final class RTMPPublisherSession {
    public enum State: Equatable {
        case idle
        case handshaking
        case connecting
        case creatingStream
        case publishRequested
        case publishing
        case closed
        case failed(String)
    }

    public private(set) var state: State = .idle
    public let url: RTMPURL
    public let streamKey: String
    public var onStateChange: ((State) -> Void)?
    public var onServerMessage: ((String) -> Void)?

    private var handshakeBuffer: [UInt8] = []
    private let reader = RTMPChunkReader(chunkSize: 128)
    private let writer = RTMPChunkWriter(chunkSize: 4096)
    private var transactionID: Double = 1
    private var pendingTransactions: [Double: String] = [:]
    private var messageStreamID: UInt32 = 0
    private var bytesReceived: UInt64 = 0
    private var lastAckSent: UInt64 = 0
    private var windowAckSize: UInt32 = 2_500_000
    private var sentVideoHeader = false
    private var sentAudioHeader = false

    /// Milliseconds since the stream started that the last video/audio packet carried.
    public private(set) var lastVideoTimestamp: UInt32 = 0
    public private(set) var lastAudioTimestamp: UInt32 = 0

    public init(url: RTMPURL, streamKey: String) {
        self.url = url
        self.streamKey = streamKey
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    /// Bytes to send to open the connection (C0+C1).
    public func start() -> [UInt8] {
        setState(.handshaking)
        handshakeBuffer = []
        return RTMPHandshake.c0c1(time: 0)
    }

    /// Feed bytes from the socket. Returns bytes to send back (may be empty).
    public func receive(_ bytes: [UInt8]) throws -> [UInt8] {
        bytesReceived &+= UInt64(bytes.count)
        var out: [UInt8] = []
        switch state {
        case .handshaking:
            handshakeBuffer.append(contentsOf: bytes)
            guard handshakeBuffer.count >= RTMPHandshake.expectedServerBytes else { return [] }
            let c2: [UInt8]
            do {
                c2 = try RTMPHandshake.c2(fromServerResponse: handshakeBuffer)
            } catch {
                setState(.failed("\(error)"))
                throw RTMPSessionError.handshakeFailed("\(error)")
            }
            out.append(contentsOf: c2)
            let leftover = Array(handshakeBuffer[RTMPHandshake.expectedServerBytes...])
            handshakeBuffer = []
            // Negotiate a bigger chunk size, then connect.
            out.append(contentsOf: setChunkSizeMessage())
            out.append(contentsOf: connectMessage())
            setState(.connecting)
            if !leftover.isEmpty { out.append(contentsOf: try processMessages(leftover)) }
        case .idle, .closed, .failed:
            return []
        default:
            out.append(contentsOf: try processMessages(bytes))
        }
        if let ack = acknowledgementIfDue() { out.append(contentsOf: ack) }
        return out
    }

    private func processMessages(_ bytes: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        let messages: [RTMPMessage]
        do {
            messages = try reader.feed(bytes)
        } catch {
            setState(.failed("\(error)"))
            throw RTMPSessionError.protocolError("\(error)")
        }
        for m in messages {
            switch m.messageType {
            case .setChunkSize:
                if m.payload.count >= 4 {
                    var r = ByteReader(m.payload)
                    let size = Int((try? r.u32()) ?? 128) & 0x7FFF_FFFF
                    if size > 0 { reader.chunkSize = size }
                }
            case .windowAckSize:
                if m.payload.count >= 4 {
                    var r = ByteReader(m.payload)
                    windowAckSize = (try? r.u32()) ?? windowAckSize
                }
            case .setPeerBandwidth:
                // Reply with our own window ack size as the spec asks.
                if m.payload.count >= 4 {
                    var r = ByteReader(m.payload)
                    let size = (try? r.u32()) ?? windowAckSize
                    var w = ByteWriter()
                    w.u32(size)
                    out.append(contentsOf: writer.serialize(RTMPMessage(type: .windowAckSize, chunkStreamID: RTMPMessage.ChunkStream.control, messageStreamID: 0, timestamp: 0, payload: w.bytes)))
                }
            case .userControl:
                // PingRequest (6) -> PingResponse (7) with the same payload.
                if m.payload.count >= 6 {
                    var r = ByteReader(m.payload)
                    if (try? r.u16()) == 6 {
                        var w = ByteWriter()
                        w.u16(7)
                        w.append(Array(m.payload[2...]))
                        out.append(contentsOf: writer.serialize(RTMPMessage(type: .userControl, chunkStreamID: RTMPMessage.ChunkStream.control, messageStreamID: 0, timestamp: 0, payload: w.bytes)))
                    }
                }
            case .commandAMF0:
                out.append(contentsOf: try handleCommand(m))
            case .acknowledgement, .abort, .audio, .video, .dataAMF0, .dataAMF3, .commandAMF3, .sharedObjectAMF0, .sharedObjectAMF3, .aggregate, .none:
                break
            }
        }
        return out
    }

    private func handleCommand(_ m: RTMPMessage) throws -> [UInt8] {
        let values: [AMF0Value]
        do { values = try AMF0Value.decodeAll(m.payload) } catch { return [] }
        guard let name = values.first?.stringValue else { return [] }
        let txn = values.count > 1 ? (values[1].numberValue ?? 0) : 0
        let info = values.count > 3 ? values[3] : (values.count > 2 ? values[2] : .null)

        switch name {
        case "_result":
            guard let pending = pendingTransactions.removeValue(forKey: txn) else { return [] }
            switch pending {
            case "connect":
                let code = info["code"]?.stringValue ?? ""
                if code.isEmpty || code == "NetConnection.Connect.Success" {
                    setState(.creatingStream)
                    var out: [UInt8] = []
                    out.append(contentsOf: command("releaseStream", args: [.null, .string(streamKey)]))
                    out.append(contentsOf: command("FCPublish", args: [.null, .string(streamKey)]))
                    out.append(contentsOf: command("createStream", args: [.null], track: true))
                    return out
                } else {
                    let desc = info["description"]?.stringValue ?? code
                    setState(.failed(desc))
                    throw RTMPSessionError.connectRejected(desc)
                }
            case "createStream":
                guard let sid = (values.count > 3 ? values[3].numberValue : nil) else {
                    setState(.failed("createStream returned no stream id"))
                    throw RTMPSessionError.protocolError("createStream returned no stream id")
                }
                messageStreamID = UInt32(sid)
                setState(.publishRequested)
                return command("publish", args: [.null, .string(streamKey), .string("live")], streamID: messageStreamID, chunkStream: RTMPMessage.ChunkStream.command)
            default:
                return []
            }
        case "_error":
            let desc = info["description"]?.stringValue ?? info["code"]?.stringValue ?? "unknown error"
            if let pending = pendingTransactions.removeValue(forKey: txn) {
                setState(.failed(desc))
                if pending == "connect" { throw RTMPSessionError.connectRejected(desc) }
                throw RTMPSessionError.publishRejected("\(pending) failed: \(desc)")
            }
            onServerMessage?(desc)
            return []
        case "onStatus":
            let code = info["code"]?.stringValue ?? ""
            let desc = info["description"]?.stringValue ?? code
            let level = info["level"]?.stringValue ?? "status"
            onServerMessage?(desc)
            if code == "NetStream.Publish.Start" {
                setState(.publishing)
            } else if level == "error" || code.hasPrefix("NetStream.Publish.BadName") || code.hasPrefix("NetStream.Failed") || code.hasPrefix("NetStream.Publish.Failed") || code.hasPrefix("NetConnection.Connect.Rejected") {
                setState(.failed(desc))
                throw RTMPSessionError.publishRejected(desc)
            }
            return []
        case "onBWDone":
            return []
        default:
            return []
        }
    }

    // MARK: outgoing

    private func setChunkSizeMessage() -> [UInt8] {
        var w = ByteWriter()
        w.u32(UInt32(writer.chunkSize))
        // The set-chunk-size message itself must travel with the OLD size, but it
        // is 4 bytes so it always fits in one chunk.
        return RTMPChunkWriter(chunkSize: 128).serialize(RTMPMessage(type: .setChunkSize, chunkStreamID: RTMPMessage.ChunkStream.control, messageStreamID: 0, timestamp: 0, payload: w.bytes))
    }

    private func connectMessage() -> [UInt8] {
        let obj: AMF0Value = .object([
            ("app", .string(url.app)),
            ("type", .string("nonprivate")),
            ("flashVer", .string("FMLE/3.0 (compatible; Upstage)")),
            ("swfUrl", .string(url.tcUrl)),
            ("tcUrl", .string(url.tcUrl)),
        ])
        return command("connect", args: [obj], track: true)
    }

    private func command(_ name: String, args: [AMF0Value], track: Bool = false, streamID: UInt32 = 0, chunkStream: Int = RTMPMessage.ChunkStream.command) -> [UInt8] {
        let txn = transactionID
        transactionID += 1
        if track { pendingTransactions[txn] = name }
        let payload = AMF0Value.encodeAll([.string(name), .number(track ? txn : 0)] + args)
        return writer.serialize(RTMPMessage(type: .commandAMF0, chunkStreamID: chunkStream, messageStreamID: streamID, timestamp: 0, payload: payload))
    }

    private func acknowledgementIfDue() -> [UInt8]? {
        guard bytesReceived - lastAckSent >= UInt64(windowAckSize) else { return nil }
        lastAckSent = bytesReceived
        var w = ByteWriter()
        w.u32(UInt32(truncatingIfNeeded: bytesReceived))
        return writer.serialize(RTMPMessage(type: .acknowledgement, chunkStreamID: RTMPMessage.ChunkStream.control, messageStreamID: 0, timestamp: 0, payload: w.bytes))
    }

    /// @setDataFrame onMetaData. Send once right after `.publishing`.
    public func metadata(_ meta: RTMPStreamMetadata) throws -> [UInt8] {
        guard state == .publishing else { throw RTMPSessionError.notPublishing }
        let payload = AMF0Value.encodeAll([.string("@setDataFrame"), .string("onMetaData"), meta.amf])
        return writer.serialize(RTMPMessage(type: .dataAMF0, chunkStreamID: RTMPMessage.ChunkStream.data, messageStreamID: messageStreamID, timestamp: 0, payload: payload))
    }

    /// Sends the AVC sequence header (avcC). Must precede the first frame; resend after a reconnect.
    public func videoSequenceHeader(avcC: [UInt8], timestampMs: UInt32 = 0) throws -> [UInt8] {
        guard state == .publishing else { throw RTMPSessionError.notPublishing }
        sentVideoHeader = true
        return writer.serialize(RTMPMessage(type: .video, chunkStreamID: RTMPMessage.ChunkStream.video, messageStreamID: messageStreamID, timestamp: timestampMs, payload: FLVVideo.avcSequenceHeader(avcC: avcC)))
    }

    public func videoFrame(avcc: [UInt8], keyframe: Bool, timestampMs: UInt32, compositionTimeMs: Int32 = 0) throws -> [UInt8] {
        guard state == .publishing else { throw RTMPSessionError.notPublishing }
        guard sentVideoHeader else { throw RTMPSessionError.protocolError("video sequence header not sent") }
        lastVideoTimestamp = timestampMs
        return writer.serialize(RTMPMessage(type: .video, chunkStreamID: RTMPMessage.ChunkStream.video, messageStreamID: messageStreamID, timestamp: timestampMs, payload: FLVVideo.avcNALU(keyframe: keyframe, compositionTimeMs: compositionTimeMs, avcc: avcc)))
    }

    public func audioSequenceHeader(audioSpecificConfig: [UInt8], timestampMs: UInt32 = 0) throws -> [UInt8] {
        guard state == .publishing else { throw RTMPSessionError.notPublishing }
        sentAudioHeader = true
        return writer.serialize(RTMPMessage(type: .audio, chunkStreamID: RTMPMessage.ChunkStream.audio, messageStreamID: messageStreamID, timestamp: timestampMs, payload: FLVAudio.aacSequenceHeader(audioSpecificConfig: audioSpecificConfig)))
    }

    public func audioFrame(aac: [UInt8], timestampMs: UInt32) throws -> [UInt8] {
        guard state == .publishing else { throw RTMPSessionError.notPublishing }
        guard sentAudioHeader else { throw RTMPSessionError.protocolError("audio sequence header not sent") }
        lastAudioTimestamp = timestampMs
        return writer.serialize(RTMPMessage(type: .audio, chunkStreamID: RTMPMessage.ChunkStream.audio, messageStreamID: messageStreamID, timestamp: timestampMs, payload: FLVAudio.aacRaw(aac)))
    }

    /// Graceful teardown: FCUnpublish + deleteStream. Send, then close the socket.
    public func close() -> [UInt8] {
        guard state == .publishing || state == .publishRequested else {
            setState(.closed)
            return []
        }
        var out: [UInt8] = []
        out.append(contentsOf: command("FCUnpublish", args: [.null, .string(streamKey)]))
        out.append(contentsOf: command("deleteStream", args: [.null, .number(Double(messageStreamID))]))
        setState(.closed)
        return out
    }
}
