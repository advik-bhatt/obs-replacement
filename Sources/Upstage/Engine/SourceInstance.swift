import CoreVideo
import Foundation
import Metal
import UpstageCore

/// A decoded video frame ready for the compositor. `holder` keeps the backing
/// CVMetalTexture / pixel buffer alive for as long as the texture is used.
struct VideoFrame {
    let texture: MTLTexture
    let holder: AnyObject?
    let size: Size2D
    /// Host time (seconds) when the frame arrived.
    let timestamp: Double
}

/// Runtime object behind a SourceDescriptor: owns the capture session or
/// decoder and hands the engine its latest frame / audio.
protocol SourceInstance: AnyObject {
    var id: UUID { get }
    var descriptor: SourceDescriptor { get }
    var isActive: Bool { get }
    /// Human readable status for the UI ("1920x1080 @ 30", "Device not found", ...).
    var status: String { get }
    func start()
    func stop()
    func update(descriptor: SourceDescriptor)
}

protocol VideoSourceInstance: SourceInstance {
    /// Size as displayed, i.e. after the source's own rotation setting. nil until the first frame.
    var displayedSize: Size2D? { get }
    /// Clockwise quarter turns to apply when drawing the raw texture.
    var quarterTurns: Int { get }
    var mirror: Bool { get }
    /// Solid colour sources have no texture.
    var solidColor: RGBA? { get }
    func latestFrame() -> VideoFrame?
}

protocol AudioSourceInstance: SourceInstance {
    var audioOutput: AudioSourceOutput { get }
}

extension VideoSourceInstance {
    var solidColor: RGBA? { nil }
    var mirror: Bool { false }
    var quarterTurns: Int { 0 }
}

/// Lock-guarded value for properties written on capture/encoder queues and
/// read on the main thread (Swift strings and structs are not safe to tear).
@propertyWrapper
final class Synchronized<Value> {
    private var value: Value
    private let lock = NSLock()

    init(wrappedValue: Value) { value = wrappedValue }

    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Thread-safe slot for the newest frame of a source.
final class FrameSlot {
    private let lock = NSLock()
    private var frame: VideoFrame?
    private(set) var frameCount: Int = 0
    private var fpsWindowStart: Double = 0
    private var fpsWindowCount = 0
    private(set) var measuredFPS: Double = 0

    func set(_ f: VideoFrame) {
        lock.lock()
        frame = f
        frameCount += 1
        fpsWindowCount += 1
        let now = f.timestamp
        if fpsWindowStart == 0 { fpsWindowStart = now }
        let elapsed = now - fpsWindowStart
        if elapsed >= 1 {
            measuredFPS = Double(fpsWindowCount) / elapsed
            fpsWindowStart = now
            fpsWindowCount = 0
        }
        lock.unlock()
    }

    func get() -> VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func clear() {
        lock.lock()
        frame = nil
        lock.unlock()
    }
}

func hostTimeSeconds() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let t = mach_absolute_time()
    return Double(t) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}
