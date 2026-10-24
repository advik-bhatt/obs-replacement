import AVFoundation
import CoreMedia
import Foundation
import UpstageCore

/// Plays a video/audio file into the scene. Decodes with AVAssetReader on its
/// own queue and paces output against the host clock, so video frames go to the
/// compositor as textures and audio goes into the mixer like any other source.
final class MediaSource: VideoSourceInstance, AudioSourceInstance {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: MediaSettings
    private let textureCache: TextureCache
    let audioOutput = AudioSourceOutput()
    private let slot = FrameSlot()
    private let queue = DispatchQueue(label: "upstage.media", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var reader: AVAssetReader?
    private var videoTrackOutput: AVAssetReaderTrackOutput?
    private var audioTrackOutput: AVAssetReaderTrackOutput?
    private var pendingVideo: CMSampleBuffer?
    private var startHostTime: Double = 0
    private var assetDuration: Double = 0
    private var naturalSize: Size2D?
    private(set) var isActive = false
    @Synchronized private(set) var status = "Not started"
    private var playbackOffset: Double = 0
    private var finished = false

    init(descriptor: SourceDescriptor, settings: MediaSettings, textureCache: TextureCache) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        self.textureCache = textureCache
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
    }

    var displayedSize: Size2D? { naturalSize }
    func latestFrame() -> VideoFrame? { slot.get() }

    func start() {
        guard !isActive else { return }
        isActive = true
        queue.async { [weak self] in
            self?.openReader(seekTo: 0)
            self?.startTimer()
        }
    }

    func stop() {
        isActive = false
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            reader?.cancelReading()
            reader = nil
            pendingVideo = nil
        }
        slot.clear()
        status = "Stopped"
    }

    func restart() {
        queue.async { [weak self] in
            guard let self, self.isActive else { return }
            self.openReader(seekTo: 0)
        }
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        guard case .media(let s) = descriptor.settings else { return }
        let pathChanged = s.path != settings.path
        settings = s
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
        if pathChanged, isActive { restart() }
    }

    private func openReader(seekTo seconds: Double) {
        reader?.cancelReading()
        reader = nil
        pendingVideo = nil
        finished = false
        guard let path = settings.path, !path.isEmpty else {
            status = "No file selected"
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let asset = AVURLAsset(url: url)
        do {
            let r = try AVAssetReader(asset: asset)
            let videoTracks = asset.tracks(withMediaType: .video)
            let audioTracks = asset.tracks(withMediaType: .audio)
            assetDuration = CMTimeGetSeconds(asset.duration)
            if let v = videoTracks.first {
                let out = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                              kCVPixelBufferMetalCompatibilityKey as String: true])
                out.alwaysCopiesSampleData = false
                if r.canAdd(out) {
                    r.add(out)
                    videoTrackOutput = out
                }
                let size = v.naturalSize.applying(v.preferredTransform)
                naturalSize = Size2D(Int(abs(size.width)), Int(abs(size.height)))
            } else {
                videoTrackOutput = nil
                naturalSize = nil
            }
            if let a = audioTracks.first {
                let out = AVAssetReaderTrackOutput(track: a, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                ])
                if r.canAdd(out) {
                    r.add(out)
                    audioTrackOutput = out
                }
            } else {
                audioTrackOutput = nil
            }
            r.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: .positiveInfinity)
            guard r.startReading() else {
                status = "Cannot read \(url.lastPathComponent): \(r.error?.localizedDescription ?? "unknown")"
                return
            }
            reader = r
            startHostTime = hostTimeSeconds()
            playbackOffset = seconds
            audioOutput.reset()
            status = "Playing \(url.lastPathComponent)"
        } catch {
            status = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Media time that should be on screen right now.
    private var playbackTime: Double { playbackOffset + (hostTimeSeconds() - startHostTime) }

    private func tick() {
        guard isActive, let reader else { return }
        if reader.status == .failed {
            status = "Decode failed: \(reader.error?.localizedDescription ?? "")"
            return
        }
        let now = playbackTime
        // Video: present the newest frame whose pts <= now.
        if let vo = videoTrackOutput {
            var presented: CMSampleBuffer?
            while true {
                if pendingVideo == nil { pendingVideo = vo.copyNextSampleBuffer() }
                guard let sb = pendingVideo else { break }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
                if pts <= now {
                    presented = sb
                    pendingVideo = nil
                } else {
                    break
                }
            }
            if let sb = presented, let pb = CMSampleBufferGetImageBuffer(sb), let pair = textureCache.texture(from: pb) {
                let sz = Size2D(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
                naturalSize = sz
                slot.set(VideoFrame(texture: pair.0, holder: pair.1, size: sz, timestamp: hostTimeSeconds()))
            }
        }
        // Audio: keep roughly 200 ms queued ahead of the mixer.
        if let ao = audioTrackOutput {
            while audioOutput.ring.availableFrames < 48_000 / 5, let sb = ao.copyNextSampleBuffer() {
                pushAudio(sb)
            }
        }
        let videoDone = videoTrackOutput == nil || (pendingVideo == nil && reader.status == .completed)
        let audioDone = audioTrackOutput == nil || reader.status == .completed
        if videoDone && audioDone && (assetDuration <= 0 || now >= assetDuration - 0.05) {
            if settings.loop {
                openReader(seekTo: 0)
            } else if !finished {
                finished = true
                status = "Finished"
            }
        }
    }

    private func pushAudio(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let mem = UnsafeMutableRawPointer.allocate(byteCount: max(ablSize, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { mem.deallocate() }
        let abl = mem.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: max(ablSize, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &block) == noErr else { return }
        audioOutput.push(audioBufferList: UnsafeMutableAudioBufferListPointer(abl), asbd: asbd.pointee, frames: frames)
        _ = block
    }
}
