import CoreVideo
import Foundation
import Network
import UpstageCore

/// RTMP/RTMPS live output: encodes video (H.264) and audio (AAC) and publishes
/// through the core RTMPPublisherSession over Network.framework. Reconnects
/// with backoff; drops non-key video when the socket backs up.
final class StreamOutput: AudioSink {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case reconnecting(attempt: Int)
        case failed(String)
        case stopped
    }

    struct Stats {
        var bytesSent: UInt64 = 0
        var framesSent: Int = 0
        var framesDropped: Int = 0
        var bitrateKbps: Double = 0
        var uptimeSeconds: Double = 0
        var congestion: Double = 0
        var serverMessage: String = ""
    }

    let settings: StreamSettings
    let video: VideoSettings
    private(set) var state: State = .idle
    private(set) var stats = Stats()
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "upstage.stream", qos: .userInitiated)
    private var connection: NWConnection?
    private var session: RTMPPublisherSession?
    private var encoder: VideoEncoder?
    private var aac: AACEncoder?
    private var epoch: Double?
    private var liveSince: Double = 0
    private var attempt = 0
    private var stopping = false
    private var outstandingBytes: Int = 0
    private var bytesWindow: (start: Double, bytes: UInt64) = (0, 0)
    private var sentSequenceHeaders = false
    private var pendingAudioPackets: [EncodedAudioPacket] = []
    private let audioTrackMask: UInt8
    private var lastVideoTS: UInt32 = 0
    private var lastAudioTS: UInt32 = 0
    private let maxOutstandingBytes: Int

    init(settings: StreamSettings, video: VideoSettings) {
        self.settings = settings
        self.video = video
        audioTrackMask = UInt8(1 << max(0, settings.audioTrack - 1))
        maxOutstandingBytes = max(settings.videoBitrateKbps * 1000 / 8 * 3, 2_000_000) // ~3 s of video
    }

    var encodedSize: Size2D { settings.scaledSize ?? video.outputSize }

    func start() {
        queue.async { [self] in
            stopping = false
            attempt = 0
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            stopping = true
            if let s = session, let c = connection {
                let bytes = s.close()
                if !bytes.isEmpty { c.send(content: Data(bytes), completion: .contentProcessed { _ in }) }
            }
            teardown()
            setState(.stopped)
        }
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        session = nil
        encoder?.flush()
        encoder = nil
        aac = nil
        epoch = nil
        sentSequenceHeaders = false
        pendingAudioPackets.removeAll()
        outstandingBytes = 0
    }

    private func connect() {
        guard !stopping else { return }
        guard let url = RTMPURL(string: settings.serverURL) else {
            setState(.failed("Invalid server URL"))
            return
        }
        setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
        let params: NWParameters = url.isTLS ? .tls : .tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
        }
        let conn = NWConnection(host: NWEndpoint.Host(url.host), port: NWEndpoint.Port(rawValue: url.port) ?? 1935, using: params)
        let sess = RTMPPublisherSession(url: url, streamKey: settings.streamKey)
        sess.onServerMessage = { [weak self] msg in self?.stats.serverMessage = msg }
        sess.onStateChange = { [weak self] st in
            guard let self else { return }
            switch st {
            case .publishing:
                self.onPublishing()
            case .failed(let why):
                self.handleFailure(why)
            default: break
            }
        }
        connection = conn
        session = sess
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            self.queue.async {
                switch st {
                case .ready:
                    self.send(sess.start())
                    self.receiveLoop()
                case .failed(let err):
                    self.handleFailure("Connection failed: \(err.localizedDescription)")
                case .cancelled:
                    break
                case .waiting(let err):
                    self.stats.serverMessage = "Waiting: \(err.localizedDescription)"
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop() {
        guard let conn = connection, let sess = session else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let reply = try sess.receive(Array(data))
                    if !reply.isEmpty { self.send(reply) }
                } catch {
                    self.handleFailure("\(error)")
                    return
                }
            }
            if let error {
                self.handleFailure("Receive error: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.handleFailure("Server closed the connection")
                return
            }
            self.receiveLoop()
        }
    }

    private func send(_ bytes: [UInt8], droppable: Bool = false) {
        guard let conn = connection, !bytes.isEmpty else { return }
        if droppable, outstandingBytes > maxOutstandingBytes {
            stats.framesDropped += 1
            return
        }
        outstandingBytes += bytes.count
        let count = bytes.count
        conn.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.outstandingBytes -= count
            if error == nil {
                self.stats.bytesSent &+= UInt64(count)
            }
        })
    }

    private func onPublishing() {
        guard let sess = session else { return }
        attempt = 0
        liveSince = hostTimeSeconds()
        bytesWindow = (liveSince, stats.bytesSent)
        encoder = VideoEncoder(codec: .h264, size: encodedSize, frameRate: video.frameRate, rateControl: .bitrate(settings.videoBitrateKbps), keyframeIntervalSeconds: settings.keyframeIntervalSeconds)
        encoder?.onFrame = { [weak self] frame in self?.queue.async { self?.handleVideo(frame) } }
        aac = AACEncoder(sampleRate: 48_000, channels: 2, bitrateKbps: settings.audioBitrateKbps)
        do {
            let meta = RTMPStreamMetadata(width: encodedSize.width, height: encodedSize.height, frameRate: video.frameRate,
                                          videoBitrateKbps: settings.videoBitrateKbps, audioBitrateKbps: settings.audioBitrateKbps,
                                          encoder: "Upstage \(UpstageVersion.string)")
            send(try sess.metadata(meta))
        } catch {
            handleFailure("\(error)")
            return
        }
        setState(.live)
    }

    private func handleFailure(_ why: String) {
        guard !stopping else { return }
        stats.serverMessage = why
        teardown()
        if settings.autoReconnect, attempt < settings.maxReconnectAttempts {
            attempt += 1
            setState(.reconnecting(attempt: attempt))
            let delay = min(60, Double(settings.reconnectDelaySeconds) * Double(attempt))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
        } else {
            setState(.failed(why))
        }
    }

    // MARK: media in

    func receiveVideo(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        queue.async { [self] in
            guard state == .live, let enc = encoder else { return }
            if epoch == nil {
                epoch = pts
                enc.forceKeyframe()
            }
            enc.encode(pixelBuffer, pts: pts)
            updateBitrate()
        }
    }

    private func handleVideo(_ frame: EncodedVideoFrame) {
        guard state == .live, let sess = session, let epoch else { return }
        if !sentSequenceHeaders {
            guard frame.isKeyframe, let avcC = encoder?.avcC ?? VideoEncoder.extractAvcC(from: frame.formatDescription), let asc = aac?.audioSpecificConfig else {
                return
            }
            do {
                send(try sess.videoSequenceHeader(avcC: avcC))
                send(try sess.audioSequenceHeader(audioSpecificConfig: asc))
            } catch {
                handleFailure("\(error)")
                return
            }
            sentSequenceHeaders = true
            flushPendingAudio()
        }
        let ts = UInt32(max(0, (frame.dts - epoch) * 1000))
        let cts = Int32(max(0, (frame.pts - frame.dts) * 1000))
        lastVideoTS = max(lastVideoTS, ts)
        do {
            send(try sess.videoFrame(avcc: frame.data, keyframe: frame.isKeyframe, timestampMs: ts, compositionTimeMs: cts), droppable: !frame.isKeyframe)
            stats.framesSent += 1
        } catch {
            handleFailure("\(error)")
        }
    }

    func receiveAudio(_ block: MixedAudioBlock) {
        guard block.trackMask == audioTrackMask else { return }
        queue.async { [self] in
            guard state == .live, let aac else { return }
            let packets = aac.encode(planes: block.planes, frames: block.frames, timestamp: block.timestamp)
            guard !packets.isEmpty else { return }
            if sentSequenceHeaders {
                for p in packets { sendAudio(p) }
            } else {
                pendingAudioPackets.append(contentsOf: packets)
                if pendingAudioPackets.count > 200 { pendingAudioPackets.removeFirst(pendingAudioPackets.count - 200) }
            }
        }
    }

    private func flushPendingAudio() {
        let packets = pendingAudioPackets
        pendingAudioPackets.removeAll()
        for p in packets { sendAudio(p) }
    }

    private func sendAudio(_ p: EncodedAudioPacket) {
        guard let sess = session, let epoch else { return }
        guard p.timestamp >= epoch - 0.05 else { return }
        let ts = UInt32(max(0, (p.timestamp - epoch) * 1000))
        lastAudioTS = max(lastAudioTS, ts)
        do {
            send(try sess.audioFrame(aac: p.data, timestampMs: ts))
        } catch {
            handleFailure("\(error)")
        }
    }

    private func updateBitrate() {
        let now = hostTimeSeconds()
        stats.uptimeSeconds = now - liveSince
        let elapsed = now - bytesWindow.start
        if elapsed >= 2 {
            let delta = stats.bytesSent &- bytesWindow.bytes
            stats.bitrateKbps = Double(delta) * 8 / elapsed / 1000
            bytesWindow = (now, stats.bytesSent)
        }
        stats.congestion = min(1, Double(outstandingBytes) / Double(maxOutstandingBytes))
    }
}
