import Foundation

public enum RTMPMessageType: UInt8 {
    case setChunkSize = 1
    case abort = 2
    case acknowledgement = 3
    case userControl = 4
    case windowAckSize = 5
    case setPeerBandwidth = 6
    case audio = 8
    case video = 9
    case dataAMF3 = 15
    case sharedObjectAMF3 = 16
    case commandAMF3 = 17
    case dataAMF0 = 18
    case sharedObjectAMF0 = 19
    case commandAMF0 = 20
    case aggregate = 22
}

/// A complete RTMP message, before chunking or after reassembly.
public struct RTMPMessage: Equatable {
    public var type: UInt8
    public var chunkStreamID: Int
    public var messageStreamID: UInt32
    /// Absolute timestamp in milliseconds.
    public var timestamp: UInt32
    public var payload: [UInt8]

    public init(type: UInt8, chunkStreamID: Int, messageStreamID: UInt32, timestamp: UInt32, payload: [UInt8]) {
        self.type = type
        self.chunkStreamID = chunkStreamID
        self.messageStreamID = messageStreamID
        self.timestamp = timestamp
        self.payload = payload
    }

    public init(type: RTMPMessageType, chunkStreamID: Int, messageStreamID: UInt32, timestamp: UInt32, payload: [UInt8]) {
        self.init(type: type.rawValue, chunkStreamID: chunkStreamID, messageStreamID: messageStreamID, timestamp: timestamp, payload: payload)
    }

    public var messageType: RTMPMessageType? { RTMPMessageType(rawValue: type) }

    /// Chunk stream IDs by convention (what every major client uses).
    public enum ChunkStream {
        public static let control = 2
        public static let command = 3
        public static let audio = 4
        public static let video = 6
        public static let data = 5
    }
}

/// Serialises messages into chunks. Uses a type-0 header for the first chunk of
/// every message (12 bytes) and type-3 for continuations; simple, correct, and
/// the overhead is noise next to video payloads.
public struct RTMPChunkWriter {
    public var chunkSize: Int

    public init(chunkSize: Int = 128) {
        self.chunkSize = chunkSize
    }

    public func serialize(_ m: RTMPMessage) -> [UInt8] {
        var w = ByteWriter(capacity: m.payload.count + 32)
        let extended = m.timestamp >= 0xFFFFFF
        RTMPChunkWriter.basicHeader(fmt: 0, csid: m.chunkStreamID, into: &w)
        w.u24(extended ? 0xFFFFFF : m.timestamp)
        w.u24(UInt32(m.payload.count))
        w.u8(m.type)
        w.u32le(m.messageStreamID)
        if extended { w.u32(m.timestamp) }

        var offset = 0
        var first = true
        while offset < m.payload.count || (first && m.payload.isEmpty) {
            if !first {
                RTMPChunkWriter.basicHeader(fmt: 3, csid: m.chunkStreamID, into: &w)
                // Type-3 chunks of a message with an extended timestamp repeat it.
                if extended { w.u32(m.timestamp) }
            }
            let n = min(chunkSize, m.payload.count - offset)
            if n > 0 { w.append(contentsOf: m.payload[offset..<offset + n]) }
            offset += n
            first = false
            if m.payload.isEmpty { break }
        }
        return w.bytes
    }

    static func basicHeader(fmt: UInt8, csid: Int, into w: inout ByteWriter) {
        if csid < 64 {
            w.u8(fmt << 6 | UInt8(csid))
        } else if csid < 320 {
            w.u8(fmt << 6)
            w.u8(UInt8(csid - 64))
        } else {
            w.u8(fmt << 6 | 1)
            let v = csid - 64
            w.u8(UInt8(v & 0xFF))
            w.u8(UInt8((v >> 8) & 0xFF))
        }
    }
}

/// Incremental chunk parser: feed bytes as they arrive, get complete messages.
/// Handles all four header formats, extended timestamps and interleaving across
/// chunk streams.
public final class RTMPChunkReader {
    public var chunkSize: Int

    private struct StreamState {
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var length: Int = 0
        var type: UInt8 = 0
        var messageStreamID: UInt32 = 0
        var payload: [UInt8] = []
        var hadExtendedTimestamp = false
    }

    private var streams: [Int: StreamState] = [:]
    private var buffer: [UInt8] = []

    public init(chunkSize: Int = 128) {
        self.chunkSize = chunkSize
    }

    /// Returns every message completed by this input; keeps partial data for next time.
    public func feed(_ incoming: [UInt8]) throws -> [RTMPMessage] {
        buffer.append(contentsOf: incoming)
        var messages: [RTMPMessage] = []
        while true {
            guard let consumed = try parseOne(into: &messages) else { break }
            buffer.removeFirst(consumed)
        }
        return messages
    }

    /// Parses one chunk from `buffer` if fully available. Returns bytes consumed or nil to wait.
    private func parseOne(into messages: inout [RTMPMessage]) throws -> Int? {
        var r = ByteReader(buffer)
        guard r.remaining >= 1 else { return nil }
        let b0 = try r.u8()
        let fmt = b0 >> 6
        var csid = Int(b0 & 0x3F)
        if csid == 0 {
            guard r.remaining >= 1 else { return nil }
            csid = Int(try r.u8()) + 64
        } else if csid == 1 {
            guard r.remaining >= 2 else { return nil }
            let lo = Int(try r.u8()), hi = Int(try r.u8())
            csid = (hi << 8 | lo) + 64
        }

        var state = streams[csid] ?? StreamState()
        let headerLen: Int
        switch fmt {
        case 0: headerLen = 11
        case 1: headerLen = 7
        case 2: headerLen = 3
        default: headerLen = 0
        }
        guard r.remaining >= headerLen else { return nil }

        var extended = false
        switch fmt {
        case 0:
            let ts = try r.u24()
            state.length = Int(try r.u24())
            state.type = try r.u8()
            state.messageStreamID = try r.u32le()
            if ts == 0xFFFFFF {
                extended = true
            } else {
                state.timestamp = ts
                state.timestampDelta = 0
            }
        case 1:
            let delta = try r.u24()
            state.length = Int(try r.u24())
            state.type = try r.u8()
            if delta == 0xFFFFFF {
                extended = true
            } else {
                state.timestampDelta = delta
                if state.payload.isEmpty { state.timestamp = state.timestamp &+ delta }
            }
        case 2:
            let delta = try r.u24()
            if delta == 0xFFFFFF {
                extended = true
            } else {
                state.timestampDelta = delta
                if state.payload.isEmpty { state.timestamp = state.timestamp &+ delta }
            }
        default:
            // Type 3: a continuation chunk carries an extended timestamp field only
            // if the message's first chunk did. A fresh message (payload empty)
            // reuses the previous delta.
            if state.payload.isEmpty {
                if state.hadExtendedTimestamp {
                    extended = true
                } else {
                    state.timestamp = state.timestamp &+ state.timestampDelta
                }
            } else if state.hadExtendedTimestamp {
                extended = true
            }
        }

        if extended {
            guard r.remaining >= 4 else { return nil }
            let full = try r.u32()
            if fmt == 0 {
                state.timestamp = full
                state.timestampDelta = 0
            } else if fmt == 1 || fmt == 2 {
                state.timestampDelta = full
                if state.payload.isEmpty { state.timestamp = state.timestamp &+ full }
            } else if state.payload.isEmpty {
                // type 3 with extended: the field is the absolute (fmt 0) or delta (fmt 1/2) of the original.
                state.timestamp = state.timestamp &+ state.timestampDelta
            }
            state.hadExtendedTimestamp = true
        } else if fmt != 3 {
            state.hadExtendedTimestamp = false
        }

        let remainingPayload = state.length - state.payload.count
        let take = min(chunkSize, max(0, remainingPayload))
        guard r.remaining >= take else { return nil }
        if take > 0 { state.payload.append(contentsOf: try r.take(take)) }

        if state.payload.count >= state.length {
            let message = RTMPMessage(type: state.type, chunkStreamID: csid, messageStreamID: state.messageStreamID,
                                      timestamp: state.timestamp, payload: state.payload)
            messages.append(message)
            state.payload = []
            // A Set Chunk Size message takes effect for every chunk that follows
            // it, including ones already sitting in our buffer, so apply it here.
            if message.type == RTMPMessageType.setChunkSize.rawValue, message.payload.count >= 4 {
                var sr = ByteReader(message.payload)
                if let size = try? sr.u32(), size & 0x7FFF_FFFF > 0 { chunkSize = Int(size & 0x7FFF_FFFF) }
            }
        }
        streams[csid] = state
        return r.offset
    }
}

public enum RTMPHandshake {
    public static let packetSize = 1536

    /// C0 (version 3) followed by C1 (time + zero + 1528 random bytes).
    public static func c0c1(time: UInt32 = 0) -> [UInt8] {
        var w = ByteWriter(capacity: 1 + packetSize)
        w.u8(3)
        w.u32(time)
        w.u32(0)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<(packetSize - 8) { w.u8(UInt8.random(in: 0...255, using: &rng)) }
        return w.bytes
    }

    /// Given S0+S1+S2 (3073 bytes), validates the version and returns C2 (an echo of S1).
    public static func c2(fromServerResponse bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 1 + packetSize * 2 else {
            throw ByteReaderError.outOfBounds(needed: 1 + packetSize * 2, available: bytes.count)
        }
        guard bytes[0] == 3 else { throw ByteReaderError.malformed("server RTMP version \(bytes[0]) != 3") }
        return Array(bytes[1..<1 + packetSize])
    }

    public static var expectedServerBytes: Int { 1 + packetSize * 2 }
}
