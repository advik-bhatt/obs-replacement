import XCTest
@testable import UpstageCore

final class StreamingTests: XCTestCase {
    func testAMF0RoundTrip() throws {
        let v: AMF0Value = .object([
            ("app", .string("live2")),
            ("n", .number(42.5)),
            ("ok", .bool(true)),
            ("nil", .null),
            ("arr", .strictArray([.number(1), .string("x")])),
            ("ecma", .ecmaArray([("w", .number(3840))])),
        ])
        let encoded = AMF0Value.encodeAll([.string("connect"), .number(1), v])
        let decoded = try AMF0Value.decodeAll(encoded)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0], .string("connect"))
        XCTAssertEqual(decoded[1], .number(1))
        XCTAssertEqual(decoded[2], v)
        XCTAssertEqual(decoded[2]["app"]?.stringValue, "live2")
    }

    func testAMF0KnownBytes() {
        // "connect" as AMF0 string: 0x02, len 7, bytes
        XCTAssertEqual(AMF0Value.string("connect").encoded, [0x02, 0x00, 0x07] + Array("connect".utf8))
        XCTAssertEqual(AMF0Value.number(1).encoded, [0x00, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(AMF0Value.bool(true).encoded, [0x01, 0x01])
        XCTAssertEqual(AMF0Value.null.encoded, [0x05])
    }

    func testChunkWriterReaderRoundTripAcrossChunkBoundaries() throws {
        let writer = RTMPChunkWriter(chunkSize: 128)
        let reader = RTMPChunkReader(chunkSize: 128)
        let payload = (0..<1000).map { UInt8($0 & 0xFF) }
        let m = RTMPMessage(type: .video, chunkStreamID: 6, messageStreamID: 1, timestamp: 1234, payload: payload)
        let bytes = writer.serialize(m)
        // 12 byte header + 1000 payload + 7 continuation headers of 1 byte
        XCTAssertEqual(bytes.count, 12 + 1000 + 7)
        // Feed in awkward slices
        var out: [RTMPMessage] = []
        var i = 0
        while i < bytes.count {
            let n = min(37, bytes.count - i)
            out.append(contentsOf: try reader.feed(Array(bytes[i..<i + n])))
            i += n
        }
        XCTAssertEqual(out, [m])
    }

    func testChunkReaderHandlesInterleavedStreamsAndExtendedTimestamps() throws {
        let writer = RTMPChunkWriter(chunkSize: 64)
        let reader = RTMPChunkReader(chunkSize: 64)
        let a = RTMPMessage(type: .audio, chunkStreamID: 4, messageStreamID: 1, timestamp: 0xFFFFFF + 10, payload: [UInt8](repeating: 1, count: 100))
        let v = RTMPMessage(type: .video, chunkStreamID: 6, messageStreamID: 1, timestamp: 5, payload: [UInt8](repeating: 2, count: 130))
        let aBytes = writer.serialize(a)
        let vBytes = writer.serialize(v)
        // Interleave: first chunk of a, first chunk of v, rest of a, rest of v.
        let aFirst = Array(aBytes[0..<(12 + 4 + 64)])
        let aRest = Array(aBytes[(12 + 4 + 64)...])
        let vFirst = Array(vBytes[0..<(12 + 64)])
        let vRest = Array(vBytes[(12 + 64)...])
        let msgs = try reader.feed(aFirst + vFirst + aRest + vRest)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertTrue(msgs.contains(a))
        XCTAssertTrue(msgs.contains(v))
    }

    func testChunkReaderTypeThreeContinuationOfSameStream() throws {
        // Two consecutive messages on the same chunk stream; the second uses our
        // fmt-0 header but a server may send fmt 1/2/3. Build a fmt-3 message by hand.
        let reader = RTMPChunkReader(chunkSize: 128)
        var w = ByteWriter()
        w.u8(0x03)              // fmt 0, csid 3
        w.u24(100)              // ts
        w.u24(2)                // len
        w.u8(20)                // command
        w.u32le(0)
        w.append([0xAA, 0xBB])
        w.u8(0xC3)              // fmt 3, csid 3 -> same len/type, ts += delta (0)
        w.append([0xCC, 0xDD])
        w.u8(0x83)              // fmt 2, csid 3: delta only
        w.u24(50)
        w.append([0xEE, 0xFF])
        let msgs = try reader.feed(w.bytes)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].payload, [0xAA, 0xBB])
        XCTAssertEqual(msgs[1].payload, [0xCC, 0xDD])
        XCTAssertEqual(msgs[1].timestamp, 100)
        XCTAssertEqual(msgs[2].timestamp, 150)
    }

    func testHandshakeShapes() throws {
        let c0c1 = RTMPHandshake.c0c1()
        XCTAssertEqual(c0c1.count, 1537)
        XCTAssertEqual(c0c1[0], 3)
        var server = [UInt8](repeating: 0, count: 3073)
        server[0] = 3
        for i in 1..<1537 { server[i] = UInt8(i & 0xFF) }
        let c2 = try RTMPHandshake.c2(fromServerResponse: server)
        XCTAssertEqual(c2, Array(server[1..<1537]))
        server[0] = 6
        XCTAssertThrowsError(try RTMPHandshake.c2(fromServerResponse: server))
    }

    func testRTMPURLParsing() {
        let u = RTMPURL(string: "rtmps://a.rtmps.youtube.com:443/live2?backup=1")!
        XCTAssertTrue(u.isTLS)
        XCTAssertEqual(u.host, "a.rtmps.youtube.com")
        XCTAssertEqual(u.port, 443)
        XCTAssertEqual(u.app, "live2?backup=1")
        XCTAssertEqual(u.tcUrl, "rtmps://a.rtmps.youtube.com/live2?backup=1")
        let t = RTMPURL(string: "rtmp://live.twitch.tv/app/")!
        XCTAssertEqual(t.port, 1935)
        XCTAssertEqual(t.app, "app")
        XCTAssertEqual(t.tcUrl, "rtmp://live.twitch.tv/app")
        XCTAssertNil(RTMPURL(string: "https://example.com"))
        XCTAssertNil(RTMPURL(string: "rtmp://"))
        let custom = RTMPURL(string: "rtmp://192.168.1.10:1936/live")!
        XCTAssertEqual(custom.port, 1936)
        XCTAssertEqual(custom.tcUrl, "rtmp://192.168.1.10:1936/live")
    }

    func testFLVTags() {
        let avcC: [UInt8] = [1, 0x64, 0, 0x28, 0xFF, 0xE1, 0, 2, 0x67, 0x64, 1, 0, 2, 0x68, 0xEE]
        let seq = FLVVideo.avcSequenceHeader(avcC: avcC)
        XCTAssertEqual(Array(seq[0..<5]), [0x17, 0x00, 0, 0, 0])
        XCTAssertEqual(Array(seq[5...]), avcC)
        let frame = FLVVideo.avcNALU(keyframe: false, compositionTimeMs: 0, avcc: [0, 0, 0, 1, 0x65])
        XCTAssertEqual(frame[0], 0x27)
        XCTAssertEqual(frame[1], 0x01)
        XCTAssertEqual(FLVAudio.aacSequenceHeader(audioSpecificConfig: [0x11, 0x90]), [0xAF, 0x00, 0x11, 0x90])
        XCTAssertEqual(FLVAudio.aacRaw([1, 2]), [0xAF, 0x01, 1, 2])
    }

    func testAudioSpecificConfig() {
        // AAC-LC, 48 kHz, stereo = 0x11 0x90
        XCTAssertEqual(AudioSpecificConfig.make(sampleRate: 48000, channels: 2), [0x11, 0x90])
        // 44.1 kHz stereo = 0x12 0x10
        XCTAssertEqual(AudioSpecificConfig.make(sampleRate: 44100, channels: 2), [0x12, 0x10])
        let p = AudioSpecificConfig.parse([0x11, 0x90])
        XCTAssertEqual(p?.sampleRate, 48000)
        XCTAssertEqual(p?.channels, 2)
        XCTAssertEqual(p?.objectType, 2)
        XCTAssertNil(AudioSpecificConfig.make(sampleRate: 12345, channels: 2))
    }

    func testAvcCBuildAndParseAndNALUs() throws {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9]
        let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB]
        let avcC = H264.avcC(sps: sps, pps: pps)
        let cfg = try H264.parseAvcC(avcC)
        XCTAssertEqual(cfg.sps, [sps])
        XCTAssertEqual(cfg.pps, [pps])
        XCTAssertEqual(cfg.lengthSize, 4)
        XCTAssertEqual(cfg.profile, 0x64)
        XCTAssertEqual(cfg.level, 0x28)
        let au = H264.avcc(nalUnits: [[0x06, 1, 2], [0x65, 9, 9, 9]])
        XCTAssertEqual(H264.nalUnits(avcc: au), [[0x06, 1, 2], [0x65, 9, 9, 9]])
        XCTAssertTrue(H264.containsIDR(avcc: au))
        XCTAssertFalse(H264.containsIDR(avcc: H264.avcc(nalUnits: [[0x41, 1]])))
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]
        XCTAssertEqual(H264.nalUnits(avcc: H264.annexBToAVCC(annexB)), [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
    }

    /// Drives the publisher through a fake server conversation.
    func testPublisherSessionHappyPath() throws {
        let url = RTMPURL(string: "rtmp://live.twitch.tv/app")!
        let session = RTMPPublisherSession(url: url, streamKey: "live_key")
        var states: [RTMPPublisherSession.State] = []
        session.onStateChange = { states.append($0) }

        let c0c1 = session.start()
        XCTAssertEqual(c0c1.count, 1537)
        XCTAssertEqual(session.state, .handshaking)

        // Server: S0 S1 S2
        var s = [UInt8](repeating: 7, count: 3073)
        s[0] = 3
        let afterHandshake = try session.receive(Array(s[0..<2000]))
        XCTAssertTrue(afterHandshake.isEmpty, "waits for the whole handshake")
        let reply = try session.receive(Array(s[2000...]))
        XCTAssertEqual(session.state, .connecting)
        // reply = C2 (1536) + set chunk size + connect command
        XCTAssertGreaterThan(reply.count, 1536 + 16)
        XCTAssertEqual(Array(reply[0..<1536]), Array(s[1..<1537]))
        let clientReader = RTMPChunkReader(chunkSize: 128)
        let clientMsgs = try clientReader.feed(Array(reply[1536...]))
        XCTAssertEqual(clientMsgs.count, 2)
        XCTAssertEqual(clientMsgs[0].messageType, .setChunkSize)
        XCTAssertEqual(clientMsgs[1].messageType, .commandAMF0)
        let connect = try AMF0Value.decodeAll(clientMsgs[1].payload)
        XCTAssertEqual(connect[0], .string("connect"))
        XCTAssertEqual(connect[1], .number(1))
        XCTAssertEqual(connect[2]["app"]?.stringValue, "app")
        XCTAssertEqual(connect[2]["tcUrl"]?.stringValue, "rtmp://live.twitch.tv/app")

        // Server: window ack, peer bw, set chunk size, _result for connect
        let serverWriter = RTMPChunkWriter(chunkSize: 128)
        var w = ByteWriter(); w.u32(2_500_000)
        var serverBytes = serverWriter.serialize(RTMPMessage(type: .windowAckSize, chunkStreamID: 2, messageStreamID: 0, timestamp: 0, payload: w.bytes))
        var pb = ByteWriter(); pb.u32(2_500_000); pb.u8(2)
        serverBytes += serverWriter.serialize(RTMPMessage(type: .setPeerBandwidth, chunkStreamID: 2, messageStreamID: 0, timestamp: 0, payload: pb.bytes))
        var cs = ByteWriter(); cs.u32(4096)
        serverBytes += serverWriter.serialize(RTMPMessage(type: .setChunkSize, chunkStreamID: 2, messageStreamID: 0, timestamp: 0, payload: cs.bytes))
        let result = AMF0Value.encodeAll([.string("_result"), .number(1), .object([("fmsVer", .string("FMS/3,0,1,123"))]), .object([("level", .string("status")), ("code", .string("NetConnection.Connect.Success"))])])
        let bigWriter = RTMPChunkWriter(chunkSize: 4096)
        serverBytes += bigWriter.serialize(RTMPMessage(type: .commandAMF0, chunkStreamID: 3, messageStreamID: 0, timestamp: 0, payload: result))

        let out2 = try session.receive(serverBytes)
        XCTAssertEqual(session.state, .creatingStream)
        clientReader.chunkSize = 4096
        let msgs2 = try clientReader.feed(out2)
        let names = msgs2.compactMap { try? AMF0Value.decodeAll($0.payload).first?.stringValue }
        XCTAssertTrue(names.contains("releaseStream"))
        XCTAssertTrue(names.contains("FCPublish"))
        XCTAssertTrue(names.contains("createStream"))
        // find createStream txn id
        let commands = try msgs2.filter { $0.messageType == .commandAMF0 }.map { try AMF0Value.decodeAll($0.payload) }
        let createStream = commands.first { $0.first == .string("createStream") }!
        let txn = createStream[1].numberValue!

        // Server: _result createStream -> stream id 1
        let csResult = AMF0Value.encodeAll([.string("_result"), .number(txn), .null, .number(1)])
        let out3 = try session.receive(bigWriter.serialize(RTMPMessage(type: .commandAMF0, chunkStreamID: 3, messageStreamID: 0, timestamp: 0, payload: csResult)))
        XCTAssertEqual(session.state, .publishRequested)
        let publish = try clientReader.feed(out3)
        XCTAssertEqual(publish.count, 1)
        XCTAssertEqual(publish[0].messageStreamID, 1)
        let pubCmd = try AMF0Value.decodeAll(publish[0].payload)
        XCTAssertEqual(pubCmd[0], .string("publish"))
        XCTAssertEqual(pubCmd[3], .string("live_key"))
        XCTAssertEqual(pubCmd[4], .string("live"))

        // Server: onStatus publish start
        let status = AMF0Value.encodeAll([.string("onStatus"), .number(0), .null, .object([("level", .string("status")), ("code", .string("NetStream.Publish.Start")), ("description", .string("Publishing live_key."))])])
        _ = try session.receive(bigWriter.serialize(RTMPMessage(type: .commandAMF0, chunkStreamID: 3, messageStreamID: 1, timestamp: 0, payload: status)))
        XCTAssertEqual(session.state, .publishing)

        // Now media flows.
        let meta = try session.metadata(RTMPStreamMetadata(width: 3840, height: 2160, frameRate: 30, videoBitrateKbps: 6000, audioBitrateKbps: 160))
        let metaMsg = try clientReader.feed(meta)
        XCTAssertEqual(metaMsg[0].messageType, .dataAMF0)
        XCTAssertThrowsError(try session.videoFrame(avcc: [0, 0, 0, 1, 0x65], keyframe: true, timestampMs: 0), "header first")
        _ = try session.videoSequenceHeader(avcC: H264.avcC(sps: [0x67, 0x64, 0, 0x28], pps: [0x68, 0xEE]))
        let vf = try clientReader.feed(try session.videoFrame(avcc: [0, 0, 0, 1, 0x65], keyframe: true, timestampMs: 33))
        XCTAssertEqual(vf[0].messageType, .video)
        XCTAssertEqual(vf[0].timestamp, 33)
        XCTAssertEqual(vf[0].payload[0], 0x17)
        _ = try session.audioSequenceHeader(audioSpecificConfig: AudioSpecificConfig.make(sampleRate: 48000, channels: 2)!)
        let af = try clientReader.feed(try session.audioFrame(aac: [1, 2, 3], timestampMs: 21))
        XCTAssertEqual(af[0].payload, [0xAF, 1, 1, 2, 3])

        let closing = session.close()
        XCTAssertEqual(session.state, .closed)
        XCTAssertFalse(closing.isEmpty)
        XCTAssertEqual(states.first, .handshaking)
        XCTAssertTrue(states.contains(.publishing))
    }

    func testPublisherSessionRejectedConnect() throws {
        let session = RTMPPublisherSession(url: RTMPURL(string: "rtmp://x/app")!, streamKey: "k")
        _ = session.start()
        var s = [UInt8](repeating: 0, count: 3073); s[0] = 3
        _ = try session.receive(s)
        let err = AMF0Value.encodeAll([.string("_error"), .number(1), .null, .object([("code", .string("NetConnection.Connect.Rejected")), ("description", .string("bad app"))])])
        XCTAssertThrowsError(try session.receive(RTMPChunkWriter(chunkSize: 128).serialize(RTMPMessage(type: .commandAMF0, chunkStreamID: 3, messageStreamID: 0, timestamp: 0, payload: err)))) { e in
            XCTAssertEqual(e as? RTMPSessionError, .connectRejected("bad app"))
        }
        XCTAssertEqual(session.state, .failed("bad app"))
    }

    func testPingRequestGetsPingResponse() throws {
        let session = RTMPPublisherSession(url: RTMPURL(string: "rtmp://x/app")!, streamKey: "k")
        _ = session.start()
        var s = [UInt8](repeating: 0, count: 3073); s[0] = 3
        _ = try session.receive(s)
        var w = ByteWriter(); w.u16(6); w.u32(777)
        let out = try session.receive(RTMPChunkWriter(chunkSize: 128).serialize(RTMPMessage(type: .userControl, chunkStreamID: 2, messageStreamID: 0, timestamp: 0, payload: w.bytes)))
        let msgs = try RTMPChunkReader(chunkSize: 4096).feed(out)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].messageType, .userControl)
        XCTAssertEqual(msgs[0].payload, [0, 7, 0, 0, 3, 9])
    }
}
