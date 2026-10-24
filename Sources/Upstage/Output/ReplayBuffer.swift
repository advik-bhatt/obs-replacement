import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UpstageCore

/// Keeps the last N seconds encoded in memory; `save` writes them to a file
/// starting from the oldest keyframe in the window.
final class ReplayBuffer: AudioSink {
    private let settings: ReplayBufferSettings
    private let recording: RecordingSettings
    private let video: VideoSettings
    private let queue = DispatchQueue(label: "upstage.replay", qos: .utility)
    private var encoder: VideoEncoder?
    private var frames: [EncodedVideoFrame] = []
    private var audio: [MixedAudioBlock] = []
    private(set) var isRunning = false
    private let audioTrackMask: UInt8

    init(settings: ReplayBufferSettings, recording: RecordingSettings, video: VideoSettings) {
        self.settings = settings
        self.recording = recording
        self.video = video
        audioTrackMask = UInt8(1 << min(5, max(0, recording.audioTrack - 1)))
    }

    func start() {
        queue.async { [self] in
            let codec: VideoCodec = recording.codec.isProRes ? .hevc : recording.codec
            encoder = VideoEncoder(codec: codec, size: video.outputSize, frameRate: video.frameRate,
                                   rateControl: recording.rateControl, keyframeIntervalSeconds: min(2, recording.keyframeIntervalSeconds))
            encoder?.onFrame = { [weak self] f in self?.queue.async { self?.store(f) } }
            isRunning = true
        }
    }

    func stop() {
        queue.async { [self] in
            isRunning = false
            encoder?.flush()
            encoder = nil
            frames.removeAll()
            audio.removeAll()
        }
    }

    func receiveVideo(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        queue.async { [self] in
            guard isRunning else { return }
            encoder?.encode(pixelBuffer, pts: pts)
        }
    }

    func receiveAudio(_ block: MixedAudioBlock) {
        guard block.trackMask == audioTrackMask else { return }
        queue.async { [self] in
            guard isRunning else { return }
            audio.append(block)
            trim()
        }
    }

    private func store(_ f: EncodedVideoFrame) {
        frames.append(f)
        trim()
    }

    private func trim() {
        let horizon = Double(settings.seconds)
        if let last = frames.last {
            // Keep whole GOPs: drop from the front only up to the first keyframe inside the window.
            let cutoff = last.pts - horizon
            if let idx = frames.firstIndex(where: { $0.isKeyframe && $0.pts >= cutoff }), idx > 0 {
                frames.removeFirst(idx)
            }
        }
        if let first = frames.first {
            audio.removeAll { $0.timestamp < first.pts - 0.1 }
        } else if let lastAudio = audio.last {
            audio.removeAll { $0.timestamp < lastAudio.timestamp - horizon }
        }
    }

    /// Writes the buffer to `<directory>/<prefix> <date>.<ext>`. Completion runs on an arbitrary queue.
    func save(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard isRunning, let startIdx = frames.firstIndex(where: { $0.isKeyframe }) else {
                completion(.failure(NSError(domain: "Upstage", code: 10, userInfo: [NSLocalizedDescriptionKey: "Replay buffer is empty"])))
                return
            }
            let snapshotVideo = Array(frames[startIdx...])
            let snapshotAudio = audio.filter { $0.timestamp >= snapshotVideo[0].pts - 0.05 }
            do {
                let dir = URL(fileURLWithPath: (recording.directory as NSString).expandingTildeInPath, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var fmt = recording
                fmt.filenameFormat = settings.filenamePrefix + " " + recording.filenameFormat
                if fmt.codec.isProRes { fmt.container = .mp4 }
                let url = dir.appendingPathComponent(fmt.filename(date: Date(), sceneName: "replay"))
                try write(video: snapshotVideo, audio: snapshotAudio, to: url, container: fmt.container, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func write(video frames: [EncodedVideoFrame], audio blocks: [MixedAudioBlock], to url: URL, container: ContainerFormat, completion: @escaping (Result<URL, Error>) -> Void) throws {
        guard let first = frames.first else { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: container == .mov ? .mov : .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: first.formatDescription)
        vi.expectsMediaDataInRealTime = false
        guard writer.canAdd(vi) else { throw NSError(domain: "Upstage", code: 11, userInfo: [NSLocalizedDescriptionKey: "cannot add passthrough video"]) }
        writer.add(vi)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: recording.audioBitrateKbps * 1000]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        ai.expectsMediaDataInRealTime = false
        if writer.canAdd(ai) { writer.add(ai) }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Upstage", code: 12) }
        let base = first.pts
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        // requestMediaDataWhenReady re-invokes its block whenever the input is
        // ready again, so the cursors must live outside the blocks.
        var videoIndex = 0
        var audioIndex = 0
        group.enter()
        vi.requestMediaDataWhenReady(on: queue) {
            while vi.isReadyForMoreMediaData {
                if videoIndex >= frames.count {
                    vi.markAsFinished()
                    group.leave()
                    return
                }
                let f = frames[videoIndex]
                videoIndex += 1
                if let sb = ReplayBuffer.retimed(f.sampleBuffer, by: -base) {
                    vi.append(sb)
                }
            }
        }
        group.enter()
        ai.requestMediaDataWhenReady(on: queue) {
            while ai.isReadyForMoreMediaData {
                if audioIndex >= blocks.count {
                    ai.markAsFinished()
                    group.leave()
                    return
                }
                let b = blocks[audioIndex]
                audioIndex += 1
                if let fd, let sb = Recorder.makeSampleBuffer(b, format: fd, pts: CMTime(seconds: max(0, b.timestamp - base), preferredTimescale: 90_000)) {
                    ai.append(sb)
                }
            }
        }
        group.notify(queue: queue) {
            writer.finishWriting {
                if let e = writer.error { completion(.failure(e)) } else { completion(.success(url)) }
            }
        }
    }

    private static func retimed(_ sb: CMSampleBuffer, by offset: Double) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        let delta = CMTime(seconds: offset, preferredTimescale: 90_000)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, delta)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, delta) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb, sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
