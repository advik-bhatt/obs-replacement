import Foundation

public enum AudioMath {
    /// dB floor used to represent silence on faders and meters.
    public static let silenceDB: Double = -100

    public static func dB(fromLinear linear: Double) -> Double {
        guard linear > 0 else { return silenceDB }
        return max(silenceDB, 20 * log10(linear))
    }

    public static func linear(fromDB db: Double) -> Float {
        guard db > silenceDB else { return 0 }
        return Float(pow(10, db / 20))
    }

    /// OBS's cubic fader: position 0...1 maps to a perceptually even gain curve.
    public static func gain(fromFaderPosition pos: Double) -> Float {
        let p = min(1, max(0, pos))
        return Float(p * p * p)
    }

    public static func faderPosition(fromGain gain: Float) -> Double {
        guard gain > 0 else { return 0 }
        return min(1, pow(Double(gain), 1.0 / 3.0))
    }

    public static func faderPosition(fromDB db: Double) -> Double {
        faderPosition(fromGain: linear(fromDB: db))
    }

    public static func dB(fromFaderPosition pos: Double) -> Double {
        dB(fromLinear: Double(gain(fromFaderPosition: pos)))
    }

    public static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var m: Float = 0
        for s in samples {
            let a = abs(s)
            if a > m { m = a }
        }
        return m
    }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return sqrt(acc / Float(samples.count))
    }
}

/// Peak meter with instant attack and a configurable fall rate, one value per channel.
public struct PeakMeter: Equatable {
    public private(set) var peakDB: [Double]
    public private(set) var holdDB: [Double]
    public var decayDBPerSecond: Double
    private var holdTimer: [Double]
    private let holdSeconds: Double = 1.5

    public init(channels: Int, decayDBPerSecond: Double = 23.53) {
        peakDB = Array(repeating: AudioMath.silenceDB, count: channels)
        holdDB = Array(repeating: AudioMath.silenceDB, count: channels)
        holdTimer = Array(repeating: 0, count: channels)
        self.decayDBPerSecond = decayDBPerSecond
    }

    public var channels: Int { peakDB.count }

    public mutating func update(peaks linear: [Float], elapsed seconds: Double) {
        for ch in 0..<channels {
            let fall = decayDBPerSecond * seconds
            let incoming = ch < linear.count ? AudioMath.dB(fromLinear: Double(linear[ch])) : AudioMath.silenceDB
            let fallen = max(AudioMath.silenceDB, peakDB[ch] - fall)
            peakDB[ch] = max(fallen, incoming)
            if incoming >= holdDB[ch] {
                holdDB[ch] = incoming
                holdTimer[ch] = holdSeconds
            } else {
                holdTimer[ch] -= seconds
                if holdTimer[ch] <= 0 { holdDB[ch] = max(AudioMath.silenceDB, holdDB[ch] - fall) }
            }
        }
    }

    public mutating func reset() {
        for ch in 0..<channels {
            peakDB[ch] = AudioMath.silenceDB
            holdDB[ch] = AudioMath.silenceDB
            holdTimer[ch] = 0
        }
    }
}

/// Routes N device channels into the mix's output channels with a gain per pair.
/// `gains[out][in]`. This is how a 16-channel BlackHole device becomes a stereo
/// source: pick channels 1 and 2 (default), or sum any subset.
public struct ChannelMatrix: Codable, Equatable, Hashable {
    public var inputChannels: Int
    public var outputChannels: Int
    public var gains: [[Float]]

    public init(inputChannels: Int, outputChannels: Int = 2, gains: [[Float]]? = nil) {
        let inputs = max(0, inputChannels)
        let outputs = max(1, outputChannels)
        self.inputChannels = inputs
        self.outputChannels = outputs
        if let g = gains, g.count == outputs, g.allSatisfy({ $0.count == inputs }) {
            self.gains = g
        } else {
            self.gains = Array(repeating: Array(repeating: 0, count: inputs), count: outputs)
        }
    }

    /// Channel 1 -> L, channel 2 -> R. A mono device feeds both outputs.
    public static func defaultMapping(inputChannels: Int, outputChannels: Int = 2) -> ChannelMatrix {
        var m = ChannelMatrix(inputChannels: inputChannels, outputChannels: outputChannels)
        guard inputChannels > 0 else { return m }
        if inputChannels == 1 {
            for o in 0..<outputChannels { m.gains[o][0] = 1 }
        } else {
            for o in 0..<outputChannels where o < inputChannels { m.gains[o][o] = 1 }
        }
        return m
    }

    /// Every input channel summed into every output at equal power.
    public static func sumAll(inputChannels: Int, outputChannels: Int = 2) -> ChannelMatrix {
        var m = ChannelMatrix(inputChannels: inputChannels, outputChannels: outputChannels)
        guard inputChannels > 0 else { return m }
        let g = Float(1 / sqrt(Double(inputChannels)))
        for o in 0..<outputChannels { for i in 0..<inputChannels { m.gains[o][i] = g } }
        return m
    }

    /// Keeps the user's choices where they still make sense when a device reports a
    /// different channel count (e.g. BlackHole 2ch swapped for BlackHole 16ch).
    public func resized(toInputChannels n: Int) -> ChannelMatrix {
        if n == inputChannels { return self }
        var m = ChannelMatrix(inputChannels: n, outputChannels: outputChannels)
        var any = false
        for o in 0..<outputChannels {
            for i in 0..<min(n, inputChannels) {
                m.gains[o][i] = gains[o][i]
                if gains[o][i] != 0 { any = true }
            }
        }
        return any ? m : .defaultMapping(inputChannels: n, outputChannels: outputChannels)
    }

    public func isRouted(input: Int, output: Int) -> Bool {
        guard output < outputChannels, input < inputChannels else { return false }
        return gains[output][input] != 0
    }

    public mutating func setRouted(input: Int, output: Int, _ on: Bool) {
        guard output < outputChannels, input < inputChannels else { return }
        gains[output][input] = on ? 1 : 0
    }

    public var isSilent: Bool { gains.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    /// Applies the matrix to planar input. `input[channel][frame]`; result is `[output][frame]`.
    public func apply(_ input: [[Float]], frames: Int) -> [[Float]] {
        var out = Array(repeating: [Float](repeating: 0, count: frames), count: outputChannels)
        for o in 0..<outputChannels {
            for i in 0..<min(inputChannels, input.count) {
                let g = gains[o][i]
                if g == 0 { continue }
                let src = input[i]
                let n = min(frames, src.count)
                for f in 0..<n { out[o][f] += src[f] * g }
            }
        }
        return out
    }

    /// Applies the matrix into caller-owned planar buffers (no allocation, usable on the audio thread).
    public func apply(input: [UnsafePointer<Float>], output: [UnsafeMutablePointer<Float>], frames: Int, accumulate: Bool = false, gain: Float = 1) {
        for o in 0..<min(outputChannels, output.count) {
            let dst = output[o]
            if !accumulate { for f in 0..<frames { dst[f] = 0 } }
            for i in 0..<min(inputChannels, input.count) {
                let g = gains[o][i] * gain
                if g == 0 { continue }
                let src = input[i]
                for f in 0..<frames { dst[f] += src[f] * g }
            }
        }
    }
}

/// Lock-free-enough planar ring buffer for one audio source. Writers (device
/// callbacks) push; the mixer pulls fixed blocks. Overflow drops the oldest audio
/// so a stalled consumer never grows memory; underflow yields silence.
public final class AudioRingBuffer {
    public let channels: Int
    public let capacity: Int
    private var storage: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let lock = NSLock()
    public private(set) var overruns = 0
    public private(set) var underruns = 0

    public init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacity = max(1, capacityFrames)
        storage = Array(repeating: [Float](repeating: 0, count: self.capacity), count: self.channels)
    }

    public var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// `planes[channel]` each with at least `frames` samples. Extra channels are ignored, missing ones are silent.
    public func write(planes: [UnsafePointer<Float>], frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var toWrite = frames
        var offset = 0
        if toWrite > capacity {
            offset = toWrite - capacity
            toWrite = capacity
        }
        if count + toWrite > capacity {
            let drop = count + toWrite - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
            overruns += 1
        }
        for ch in 0..<channels {
            let src: UnsafePointer<Float>? = ch < planes.count ? planes[ch] : nil
            var w = writeIndex
            for f in 0..<toWrite {
                storage[ch][w] = src?[offset + f] ?? 0
                w += 1
                if w == capacity { w = 0 }
            }
        }
        writeIndex = (writeIndex + toWrite) % capacity
        count += toWrite
    }

    public func write(planes: [[Float]], frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var toWrite = frames
        var offset = 0
        if toWrite > capacity {
            offset = toWrite - capacity
            toWrite = capacity
        }
        if count + toWrite > capacity {
            let drop = count + toWrite - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
            overruns += 1
        }
        for ch in 0..<channels {
            var w = writeIndex
            let hasSrc = ch < planes.count
            for f in 0..<toWrite {
                let idx = offset + f
                storage[ch][w] = (hasSrc && idx < planes[ch].count) ? planes[ch][idx] : 0
                w += 1
                if w == capacity { w = 0 }
            }
        }
        writeIndex = (writeIndex + toWrite) % capacity
        count += toWrite
    }

    /// Reads exactly `frames` into `out[channel]`, zero-filling on underrun. Returns frames actually available.
    @discardableResult
    public func read(into out: [UnsafeMutablePointer<Float>], frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let have = min(count, frames)
        if have < frames { underruns += 1 }
        for ch in 0..<min(channels, out.count) {
            var r = readIndex
            for f in 0..<have {
                out[ch][f] = storage[ch][r]
                r += 1
                if r == capacity { r = 0 }
            }
            for f in have..<frames { out[ch][f] = 0 }
        }
        readIndex = (readIndex + have) % capacity
        count -= have
        return have
    }

    /// Drops everything but the newest `keepFrames`, used to bound latency after a stall.
    public func trim(keepFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard count > keepFrames else { return }
        let drop = count - keepFrames
        readIndex = (readIndex + drop) % capacity
        count -= drop
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        count = 0
    }
}
