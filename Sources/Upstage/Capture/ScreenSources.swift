import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import UpstageCore

struct DisplayInfo: Identifiable, Hashable {
    var id: UInt32 { displayID }
    var displayID: UInt32
    var name: String
    var width: Int
    var height: Int
    var scale: Double
    var pixelSize: Size2D { Size2D(Int(Double(width) * scale), Int(Double(height) * scale)) }
    var label: String { "\(name) (\(pixelSize.width)x\(pixelSize.height))" }
}

struct WindowInfo: Identifiable, Hashable {
    var id: UInt32 { windowID }
    var windowID: UInt32
    var title: String
    var ownerName: String
    var width: Int
    var height: Int
    var label: String { title.isEmpty ? "\(ownerName)" : "\(ownerName): \(title)" }
}

enum ShareableContent {
    static func fetch(_ completion: @escaping ([DisplayInfo], [WindowInfo]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else {
                DispatchQueue.main.async { completion([], []) }
                return
            }
            let displays = content.displays.map { d -> DisplayInfo in
                let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.backingScaleFactor ?? 2
                let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.localizedName ?? "Display \(d.displayID)"
                return DisplayInfo(displayID: d.displayID, name: name, width: d.width, height: d.height, scale: Double(scale))
            }
            let windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 && ($0.owningApplication?.bundleIdentifier ?? "") != Bundle.main.bundleIdentifier }
                .map { WindowInfo(windowID: $0.windowID, title: $0.title ?? "", ownerName: $0.owningApplication?.applicationName ?? "", width: Int($0.frame.width), height: Int($0.frame.height)) }
                .sorted { $0.ownerName < $1.ownerName }
            DispatchQueue.main.async { completion(displays, windows) }
        }
    }
}

/// Display or window capture through ScreenCaptureKit at native pixel size.
final class ScreenCaptureSource: NSObject, VideoSourceInstance, SCStreamOutput, SCStreamDelegate {
    enum Mode {
        case display(DisplaySettings)
        case window(WindowSettings)
    }

    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var mode: Mode
    private let textureCache: TextureCache
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "upstage.screen", qos: .userInteractive)
    private let slot = FrameSlot()
    private(set) var isActive = false
    @Synchronized private(set) var status = "Not started"
    private var size: Size2D?

    init(descriptor: SourceDescriptor, mode: Mode, textureCache: TextureCache) {
        id = descriptor.id
        self.descriptor = descriptor
        self.mode = mode
        self.textureCache = textureCache
        super.init()
    }

    var displayedSize: Size2D? { size }
    func latestFrame() -> VideoFrame? { slot.get() }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Starting"
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self, self.isActive else { return }
            guard let content else {
                self.status = "Screen Recording permission needed (System Settings > Privacy & Security)\(error.map { ": \($0.localizedDescription)" } ?? "")"
                return
            }
            self.configure(content)
        }
    }

    func stop() {
        isActive = false
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
        slot.clear()
        status = "Stopped"
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        let newMode: Mode
        switch descriptor.settings {
        case .display(let d): newMode = .display(d)
        case .window(let w): newMode = .window(w)
        default: return
        }
        let changed: Bool
        switch (mode, newMode) {
        case (.display(let a), .display(let b)): changed = a != b
        case (.window(let a), .window(let b)): changed = a != b
        default: changed = true
        }
        mode = newMode
        // Filters, name, audio settings etc. change the descriptor too; only capture settings restart the stream.
        guard changed, isActive else { return }
        restart()
    }

    /// Stops the current stream (if any) and configures again from fresh shareable content.
    private func restart() {
        let s = stream
        stream = nil
        let reconfigure: () -> Void = { [weak self] in
            guard let self, self.isActive else { return }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
                guard let content else { return }
                self.configure(content)
            }
        }
        if let s {
            s.stopCapture { _ in reconfigure() }
        } else {
            reconfigure()
        }
    }

    private func configure(_ content: SCShareableContent) {
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var fps: Double = 60
        switch mode {
        case .display(let d):
            guard let display = content.displays.first(where: { $0.displayID == d.displayID }) ?? content.displays.first else {
                status = "Display not found"
                return
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 2
            config.width = Int(Double(display.width) * Double(scale))
            config.height = Int(Double(display.height) * Double(scale))
            config.showsCursor = d.showCursor
            fps = d.frameRate
        case .window(let w):
            guard let window = content.windows.first(where: { $0.windowID == w.windowID })
                    ?? content.windows.first(where: { ($0.title ?? "") == (w.title ?? "") && ($0.owningApplication?.applicationName ?? "") == (w.ownerName ?? "") }) else {
                status = "Window not found: \(w.ownerName ?? "") \(w.title ?? "")"
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = max(2, Int(window.frame.width * scale))
            config.height = max(2, Int(window.frame.height * scale))
            config.showsCursor = w.showCursor
            fps = w.frameRate
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 5
        config.capturesAudio = false
        config.scalesToFit = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            status = "Could not attach output: \(error.localizedDescription)"
            return
        }
        stream = s
        s.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.status = "Capture failed: \(error.localizedDescription)"
            } else {
                self.status = "Capturing \(config.width)x\(config.height) @ \(Int(fps))"
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let frameStatus = SCFrameStatus(rawValue: statusRaw), frameStatus != .complete {
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let pair = textureCache.texture(from: pb) else { return }
        let sz = Size2D(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        size = sz
        slot.set(VideoFrame(texture: pair.0, holder: pair.1, size: sz, timestamp: hostTimeSeconds()))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        status = "Stopped: \(error.localizedDescription)"
        if isActive {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isActive else { return }
                self.stream = nil
                self.restart()
            }
        }
    }
}

/// System ("desktop") audio via ScreenCaptureKit, excluding this app's own output.
final class SystemAudioSource: NSObject, AudioSourceInstance, SCStreamOutput, SCStreamDelegate {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: SystemAudioSettings
    let audioOutput = AudioSourceOutput()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "upstage.sysaudio", qos: .userInitiated)
    private(set) var isActive = false
    @Synchronized private(set) var status = "Not started"

    init(descriptor: SourceDescriptor, settings: SystemAudioSettings) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
        super.init()
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self, self.isActive else { return }
            guard let content, let display = content.displays.first else {
                self.status = "Screen Recording permission needed for desktop audio\(error.map { ": \($0.localizedDescription)" } ?? "")"
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = self.settings.excludeOwnProcess
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                self.status = "Could not attach audio output: \(error.localizedDescription)"
                return
            }
            self.stream = s
            s.startCapture { error in
                self.status = error.map { "Failed: \($0.localizedDescription)" } ?? "Capturing desktop audio"
            }
        }
    }

    func stop() {
        isActive = false
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
        status = "Stopped"
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
        guard case .systemAudio(let s) = descriptor.settings else { return }
        let old = settings
        settings = s
        // excludesCurrentProcessAudio is baked into the stream configuration.
        if old != s, isActive {
            stop()
            start()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let mem = UnsafeMutableRawPointer.allocate(byteCount: max(ablSize, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { mem.deallocate() }
        let abl = mem.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: max(ablSize, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &block) == noErr else { return }
        audioOutput.push(audioBufferList: UnsafeMutableAudioBufferListPointer(abl), asbd: asbdPtr.pointee, frames: frames)
        _ = block
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        status = "Stopped: \(error.localizedDescription)"
    }
}
