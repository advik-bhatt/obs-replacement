import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UpstageCore

/// Writes MP4/MOV with AVAssetWriter: H.264/HEVC (hardware) or ProRes, AAC audio.
/// Video arrives as BGRA pixel buffers from the engine; audio from the mixer.
final class Recorder: AudioSink {
    enum State: Equatable {
        case idle, recording, paused, stopping, failed(String)
    }

    let url: URL
    private let settings: RecordingSettings
    private let video: VideoSettings
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioFormat: CMAudioFormatDescription?
    private let queue = DispatchQueue(label: "upstage.recorder", qos: .userInitiated)
    private var sessionStarted = false
    private var firstPTS: Double?
    @Synchronized private(set) var state: State = .idle
    private var pauseStart: Double?
    private var pausedTotal: Double = 0
    private(set) var videoFramesWritten = 0
    private(set) var startedAt: Double = 0
    private let audioTrackMask: UInt8
    var onStateChange: ((State) -> Void)?
    private var lastAudioPTS: Double = -1

    init(settings: RecordingSettings, video: VideoSettings, sceneName: String) throws {
        self.settings = settings
        self.video = video
        audioTrackMask = UInt8(1 << min(5, max(0, settings.audioTrack - 1)))
        let dir = URL(fileURLWithPath: (settings.directory as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(settings.filename(date: Date(), sceneName: sceneName))
    }

    var duration: Double {
        guard state == .recording || state == .paused, let f = firstPTS else { return 0 }
        let now = hostTimeSeconds() - startedAt + f
        return max(0, now - f - pausedTotal - (pauseStart.map { hostTimeSeconds() - $0 } ?? 0))
    }

    var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    func start() throws {
        let fileType: AVFileType = settings.container == .mov ? .mov : .mp4
        let w = try AVAssetWriter(outputURL: url, fileType: fileType)
        w.shouldOptimizeForNetworkUse = false
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) // survive a crash with a playable file

        var videoSettings: [String: Any] = [
            AVVideoWidthKey: video.outputSize.width,
            AVVideoHeightKey: video.outputSize.height,
        ]
        var compression: [String: Any] = [:]
        switch settings.codec {
        case .h264:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAllowFrameReorderingKey] = true
        case .hevc:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoAllowFrameReorderingKey] = true
        case .proRes422:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes4444:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        if !settings.codec.isProRes {
            switch settings.rateControl {
            case .bitrate(let kbps): compression[AVVideoAverageBitRateKey] = kbps * 1000
            case .quality(let q): compression[AVVideoQualityKey] = q
            }
            compression[AVVideoMaxKeyFrameIntervalKey] = Int(video.frameRate * settings.keyframeIntervalSeconds)
            compression[AVVideoExpectedSourceFrameRateKey] = video.frameRate
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        guard w.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw NSError(domain: "Upstage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported video settings for \(settings.codec.label) in \(settings.container.label)"])
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: video.outputSize.width,
            kCVPixelBufferHeightKey as String: video.outputSize.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: pbAttrs)
        guard w.canAdd(vi) else { throw NSError(domain: "Upstage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]) }
        w.add(vi)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: settings.audioBitrateKbps * 1000,
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        ai.expectsMediaDataInRealTime = true
        if w.canAdd(ai) { w.add(ai) }

        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        audioFormat = fd

        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "Upstage", code: 4, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer = w
        videoInput = vi
        audioInput = ai
        adaptor = ad
        startedAt = hostTimeSeconds()
        setState(.recording)
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    func pause() {
        queue.async { [self] in
            guard state == .recording else { return }
            pauseStart = hostTimeSeconds()
            setState(.paused)
        }
    }

    func resume() {
        queue.async { [self] in
            guard state == .paused, let ps = pauseStart else { return }
            pausedTotal += hostTimeSeconds() - ps
            pauseStart = nil
            setState(.recording)
        }
    }

    /// Maps engine time to the file timeline (removes paused spans).
    private func fileTime(_ pts: Double) -> CMTime {
        CMTime(seconds: max(0, pts - pausedTotal), preferredTimescale: 90_000)
    }

    func receiveVideo(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        queue.async { [self] in
            guard state == .recording, let w = writer, let vi = videoInput, let ad = adaptor else { return }
            if !sessionStarted {
                firstPTS = pts
                w.startSession(atSourceTime: fileTime(pts))
                sessionStarted = true
            }
            guard vi.isReadyForMoreMediaData else { return }
            if ad.append(pixelBuffer, withPresentationTime: fileTime(pts)) {
                videoFramesWritten += 1
            } else if w.status == .failed {
                setState(.failed(w.error?.localizedDescription ?? "writer failed"))
            }
        }
    }

    func receiveAudio(_ block: MixedAudioBlock) {
        guard block.trackMask == audioTrackMask else { return }
        queue.async { [self] in
            guard state == .recording, sessionStarted, let ai = audioInput, ai.isReadyForMoreMediaData, let fd = audioFormat else { return }
            guard block.timestamp >= (firstPTS ?? 0) else { return }
            let t = fileTime(block.timestamp)
            if CMTimeGetSeconds(t) <= lastAudioPTS { return }
            lastAudioPTS = CMTimeGetSeconds(t)
            if let sb = Recorder.makeSampleBuffer(block, format: fd, pts: t) {
                ai.append(sb)
            }
        }
    }

    static func makeSampleBuffer(_ block: MixedAudioBlock, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let frames = block.frames
        let channels = 2
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            for c in 0..<channels { interleaved[f * channels + c] = c < block.planes.count ? block.planes[c][f] : 0 }
        }
        var blockBuffer: CMBlockBuffer?
        let byteCount = frames * channels * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr, let bb = blockBuffer else { return nil }
        let st = interleaved.withUnsafeBytes { src in
            CMBlockBufferReplaceDataBytes(with: src.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard st == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    func stop(completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard let w = writer, state == .recording || state == .paused else {
                completion(nil)
                return
            }
            setState(.stopping)
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            if w.status == .writing {
                w.finishWriting {
                    self.setState(.idle)
                    completion(w.error)
                }
            } else {
                setState(.idle)
                completion(w.error)
            }
        }
    }
}
