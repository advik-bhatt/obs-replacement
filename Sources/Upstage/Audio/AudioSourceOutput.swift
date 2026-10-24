import AVFoundation
import Foundation
import UpstageCore

/// Converts whatever a device delivers (N channels, any rate, any sample
/// format) into the mix format (planar Float32, stereo, 48 kHz) and queues it
/// for the mixer. One per audio-producing source.
final class AudioSourceOutput {
    let mixSampleRate: Double
    let mixChannels: Int
    let ring: AudioRingBuffer
    private let lock = NSLock()
    private var matrix: ChannelMatrix
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var scratchIn: AVAudioPCMBuffer?
    private var scratchOut: AVAudioPCMBuffer?
    private var scratchPlanes: [UnsafeMutablePointer<Float>] = []
    private var scratchCapacity = 0
    /// Milliseconds of extra delay requested by the user (sync offset).
    var syncOffsetMs: Int = 0
    private(set) var inputChannels: Int = 0
    private(set) var inputSampleRate: Double = 0
    private(set) var framesReceived: UInt64 = 0
    /// Peak of the most recent input block per mix channel (for meters before the fader).
    private(set) var lastPeak: [Float] = [0, 0]

    init(mixSampleRate: Double = 48_000, mixChannels: Int = 2, bufferSeconds: Double = 3, matrix: ChannelMatrix = .defaultMapping(inputChannels: 2)) {
        self.mixSampleRate = mixSampleRate
        self.mixChannels = mixChannels
        self.matrix = matrix
        ring = AudioRingBuffer(channels: mixChannels, capacityFrames: Int(mixSampleRate * bufferSeconds))
    }

    deinit {
        scratchPlanes.forEach { $0.deallocate() }
    }

    private func ensureScratch(frames: Int) {
        if scratchPlanes.count != mixChannels || scratchCapacity < frames {
            scratchPlanes.forEach { $0.deallocate() }
            scratchCapacity = max(frames, 4096)
            scratchPlanes = (0..<mixChannels).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
                p.initialize(repeating: 0, count: scratchCapacity)
                return p
            }
        }
    }

    var channelMatrix: ChannelMatrix {
        get { lock.lock(); defer { lock.unlock() }; return matrix }
        set { lock.lock(); matrix = newValue; lock.unlock() }
    }

    /// Called when the device format becomes known. Resizes the matrix to the device's channel count.
    func configureInput(channels: Int, sampleRate: Double) {
        lock.lock()
        inputChannels = channels
        inputSampleRate = sampleRate
        if matrix.inputChannels != channels { matrix = matrix.resized(toInputChannels: channels) }
        converter = nil
        lock.unlock()
    }

    /// Planar Float32 input at the device's rate. `planes.count` may exceed the matrix's inputs.
    func push(planes: [UnsafePointer<Float>], frames: Int, sampleRate: Double) {
        guard frames > 0, !planes.isEmpty else { return }
        lock.lock()
        if inputChannels != planes.count || inputSampleRate != sampleRate {
            inputChannels = planes.count
            inputSampleRate = sampleRate
            if matrix.inputChannels != planes.count { matrix = matrix.resized(toInputChannels: planes.count) }
            converter = nil
        }
        let m = matrix
        // 1. channel matrix -> mix channels at input rate
        ensureScratch(frames: frames)
        let outPtrs = scratchPlanes
        m.apply(input: planes, output: outPtrs, frames: frames)
        var peaks = [Float](repeating: 0, count: mixChannels)
        for ch in 0..<mixChannels {
            peaks[ch] = AudioMath.peak(UnsafeBufferPointer(start: outPtrs[ch], count: frames))
        }
        lastPeak = peaks
        framesReceived &+= UInt64(frames)

        // 2. resample if needed
        if abs(sampleRate - mixSampleRate) < 0.5 {
            ring.write(planes: outPtrs.map { UnsafePointer($0) }, frames: frames)
        } else {
            resampleAndWrite(outPtrs, frames: frames, sampleRate: sampleRate)
        }
        lock.unlock()
    }

    /// Interleaved or planar input in any common integer/float format (CMSampleBuffer audio).
    func push(audioBufferList abl: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription, frames: Int) {
        guard frames > 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isSigned = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bits = Int(asbd.mBitsPerChannel)
        var planes = Array(repeating: [Float](repeating: 0, count: frames), count: channels)

        func convertSample(_ p: UnsafeRawPointer, _ index: Int) -> Float {
            if isFloat {
                if bits == 32 { return p.load(fromByteOffset: index * 4, as: Float.self) }
                if bits == 64 { return Float(p.load(fromByteOffset: index * 8, as: Double.self)) }
                return 0
            }
            if bits == 16 {
                return Float(p.load(fromByteOffset: index * 2, as: Int16.self)) / 32768
            }
            if bits == 32 {
                if isSigned { return Float(p.load(fromByteOffset: index * 4, as: Int32.self)) / 2147483648 }
                return (Float(p.load(fromByteOffset: index * 4, as: UInt32.self)) / 2147483648) - 1
            }
            if bits == 24 {
                let b = p.advanced(by: index * 3).assumingMemoryBound(to: UInt8.self)
                let v = Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16
                let s = (v & 0x800000) != 0 ? v - 0x1000000 : v
                return Float(s) / 8388608
            }
            if bits == 8 {
                return (Float(p.load(fromByteOffset: index, as: UInt8.self)) / 128) - 1
            }
            return 0
        }

        if isNonInterleaved {
            for ch in 0..<min(channels, abl.count) {
                guard let data = abl[ch].mData else { continue }
                let n = min(frames, Int(abl[ch].mDataByteSize) / max(1, bits / 8))
                for f in 0..<n { planes[ch][f] = convertSample(UnsafeRawPointer(data), f) }
            }
        } else if abl.count > 0, let data = abl[0].mData {
            let n = min(frames, Int(abl[0].mDataByteSize) / max(1, (bits / 8) * channels))
            for f in 0..<n {
                for ch in 0..<channels {
                    planes[ch][f] = convertSample(UnsafeRawPointer(data), f * channels + ch)
                }
            }
        }
        withPlanePointers(planes) { ptrs in
            push(planes: ptrs, frames: frames, sampleRate: asbd.mSampleRate)
        }
    }

    private func resampleAndWrite(_ input: [UnsafeMutablePointer<Float>], frames: Int, sampleRate: Double) {
        let inFmt: AVAudioFormat
        if let f = converterInputFormat, f.sampleRate == sampleRate, Int(f.channelCount) == mixChannels, converter != nil {
            inFmt = f
        } else {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(mixChannels), interleaved: false),
                  let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: mixSampleRate, channels: AVAudioChannelCount(mixChannels), interleaved: false),
                  let c = AVAudioConverter(from: f, to: o) else { return }
            c.sampleRateConverterQuality = .max
            converter = c
            converterInputFormat = f
            scratchIn = nil
            scratchOut = nil
            inFmt = f
        }
        guard let converter, let outFmt = Optional(converter.outputFormat) else { return }
        if scratchIn == nil || scratchIn!.frameCapacity < AVAudioFrameCount(frames) {
            scratchIn = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
        }
        let outCap = AVAudioFrameCount(Double(frames) * mixSampleRate / sampleRate) + 64
        if scratchOut == nil || scratchOut!.frameCapacity < outCap {
            scratchOut = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: max(outCap, 4096))
        }
        guard let inBuf = scratchIn, let outBuf = scratchOut, let inData = inBuf.floatChannelData, let outData = outBuf.floatChannelData else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<mixChannels { inData[ch].update(from: input[ch], count: frames) }
        var consumed = false
        var error: NSError?
        outBuf.frameLength = 0
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, outBuf.frameLength > 0 else { return }
        var ptrs: [UnsafePointer<Float>] = []
        for ch in 0..<mixChannels { ptrs.append(UnsafePointer(outData[ch])) }
        ring.write(planes: ptrs, frames: Int(outBuf.frameLength))
    }

    func reset() {
        ring.clear()
    }
}

/// Runs `body` with stable pointers into every plane of `planes`.
func withPlanePointers(_ planes: [[Float]], _ body: ([UnsafePointer<Float>]) -> Void) {
    var ptrs: [UnsafePointer<Float>] = []
    func recurse(_ i: Int) {
        if i == planes.count {
            body(ptrs)
            return
        }
        planes[i].withUnsafeBufferPointer { bp in
            ptrs.append(bp.baseAddress!)
            recurse(i + 1)
        }
    }
    if planes.isEmpty { body([]); return }
    recurse(0)
}
