import AVFoundation
import CoreMedia
import Foundation
import Metal
import UpstageCore

/// Any AVCaptureDevice as a scene source: built-in camera, UVC webcam or capture
/// card, Continuity Camera (wired or wireless) and wired iPhone screen. Each
/// source owns its own AVCaptureSession so sources never fight over one
/// pipeline. Frames arrive as BGRA pixel buffers and become Metal textures with
/// zero copies through the shared TextureCache.
final class CameraSource: NSObject, VideoSourceInstance, AudioSourceInstance,
                          AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: CameraSettings
    private let textureCache: TextureCache
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "upstage.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "upstage.camera.frames", qos: .userInteractive)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var deviceInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private let slot = FrameSlot()
    private var observers: [NSObjectProtocol] = []
    private var restartAttempts = 0
    private(set) var isActive = false
    private(set) var status = "Not started"
    private var rawSize: Size2D?
    let audioOutput = AudioSourceOutput()

    init(descriptor: SourceDescriptor, settings: CameraSettings, textureCache: TextureCache) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        self.textureCache = textureCache
        super.init()
    }

    // MARK: VideoSourceInstance

    var displayedSize: Size2D? {
        guard let raw = rawSize else { return nil }
        return settings.rotation.apply(to: raw)
    }

    var quarterTurns: Int { settings.rotation.rawValue / 90 }
    var mirror: Bool { settings.mirror }

    func latestFrame() -> VideoFrame? { slot.get() }

    var measuredFPS: Double { slot.measuredFPS }

    // MARK: lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Starting"
        sessionQueue.async { [weak self] in self?.configureAndRun() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.status = "Runtime error: \(err?.localizedDescription ?? "unknown")"
            self?.scheduleRestart()
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice else { return }
            if self.device == nil || d.uniqueID == self.settings.deviceUniqueID { self.scheduleRestart() }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice, d.uniqueID == self.device?.uniqueID else { return }
            self.status = "Disconnected: \(d.localizedName)"
            self.slot.clear()
        })
    }

    func stop() {
        isActive = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            tearDown()
        }
        slot.clear()
        status = "Stopped"
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        guard case .camera(let s) = descriptor.settings else { return }
        let needsRestart = s.deviceUniqueID != settings.deviceUniqueID || s.preferredSize != settings.preferredSize
            || s.preferredFrameRate != settings.preferredFrameRate || s.captureAudio != settings.captureAudio
        settings = s
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
        if needsRestart, isActive {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning { self.session.stopRunning() }
                self.tearDown()
                self.configureAndRun()
            }
        }
    }

    private func scheduleRestart() {
        guard isActive else { return }
        restartAttempts += 1
        let delay = min(10, Double(restartAttempts))
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isActive else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.tearDown()
            self.configureAndRun()
        }
    }

    private func tearDown() {
        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        session.commitConfiguration()
        deviceInput = nil
        videoOutput = nil
        audioDataOutput = nil
        device = nil
    }

    private func resolveDevice() -> AVCaptureDevice? {
        if let d = VideoDeviceManager.device(uniqueID: settings.deviceUniqueID) { return d }
        if settings.deviceUniqueID != nil { return nil }
        if let d = AVCaptureDevice.systemPreferredCamera { return d }
        return VideoDeviceManager.allDevices().first
    }

    private func configureAndRun() {
        guard let d = resolveDevice() else {
            status = "Device not found: \(settings.deviceName ?? settings.deviceUniqueID ?? "any camera")"
            return
        }
        device = d
        do {
            try d.lockForConfiguration()
            selectFormat(d)
            d.unlockForConfiguration()
        } catch {
            status = "Could not configure \(d.localizedName): \(error.localizedDescription)"
        }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        do {
            let input = try AVCaptureDeviceInput(device: d)
            guard session.canAddInput(input) else { throw NSError(domain: "Upstage", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add input"]) }
            session.addInput(input)
            deviceInput = input
        } catch {
            session.commitConfiguration()
            status = "Cannot open \(d.localizedName): \(error.localizedDescription)"
            return
        }
        let vo = AVCaptureVideoDataOutput()
        vo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        vo.alwaysDiscardsLateVideoFrames = true
        vo.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(vo) {
            session.addOutput(vo)
            videoOutput = vo
        }
        if settings.captureAudio, d.hasMediaType(.muxed) || d.hasMediaType(.audio) {
            let ao = AVCaptureAudioDataOutput()
            ao.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(ao) {
                session.addOutput(ao)
                audioDataOutput = ao
            }
        }
        session.commitConfiguration()
        session.startRunning()
        restartAttempts = 0
        let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        rawSize = Size2D(Int(dims.width), Int(dims.height))
        let fps = 1 / CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        status = "\(d.localizedName): \(dims.width)x\(dims.height) @ \(String(format: "%.4g", fps.isFinite ? fps : 0)) fps"
    }

    /// Picks the biggest format (or the smallest at/above the preferred size), then the
    /// closest supported frame rate to the preference.
    private func selectFormat(_ d: AVCaptureDevice) {
        var candidates = d.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video }
        guard !candidates.isEmpty else { return }
        func pixels(_ f: AVCaptureDevice.Format) -> Int {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(dims.width) * Int(dims.height)
        }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        if let pref = settings.preferredSize {
            let atLeast = candidates.filter {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return Int(dims.width) >= pref.width && Int(dims.height) >= pref.height
            }
            if !atLeast.isEmpty { candidates = atLeast }
        }
        let wantFPS = settings.preferredFrameRate ?? 30
        // Prefer: enough fps >= wanted, then more pixels, then higher fps, then 420v (cheaper than 2vuy/yuvs).
        let best = candidates.max { a, b in
            let aOK = maxFPS(a) >= wantFPS - 0.01, bOK = maxFPS(b) >= wantFPS - 0.01
            if aOK != bOK { return !aOK }
            if settings.preferredSize != nil {
                if pixels(a) != pixels(b) { return pixels(a) > pixels(b) } // smallest that satisfies
            } else if pixels(a) != pixels(b) {
                return pixels(a) < pixels(b)
            }
            return maxFPS(a) < maxFPS(b)
        }
        guard let format = best else { return }
        d.activeFormat = format
        let ranges = format.videoSupportedFrameRateRanges
        let maxSupported = ranges.map(\.maxFrameRate).max() ?? wantFPS
        let minSupported = ranges.map(\.minFrameRate).min() ?? 1
        let fps = min(max(wantFPS, minSupported), maxSupported)
        let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        d.activeVideoMinFrameDuration = duration
        d.activeVideoMaxFrameDuration = duration
    }

    // MARK: delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let pair = textureCache.texture(from: pb) else { return }
            let size = Size2D(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
            if rawSize != size { rawSize = size }
            slot.set(VideoFrame(texture: pair.0, holder: pair.1, size: size, timestamp: hostTimeSeconds()))
        } else if output === audioDataOutput {
            pushAudio(sampleBuffer)
        }
    }

    private func pushAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let ablMem = UnsafeMutableRawPointer.allocate(byteCount: max(ablSize, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablMem.deallocate() }
        let abl = ablMem.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: max(ablSize, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &block)
        guard st == noErr else { return }
        audioOutput.push(audioBufferList: UnsafeMutableAudioBufferListPointer(abl), asbd: asbd, frames: frames)
        _ = block
    }
}
