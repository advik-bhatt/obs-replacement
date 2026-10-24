import AudioToolbox
import AVFoundation
import Foundation
import UpstageCore

struct EncodedAudioPacket {
    let data: [UInt8]
    /// Seconds on the engine clock for the first sample of this packet.
    let timestamp: Double
    let frames: Int
}

/// Float32 stereo 48 kHz -> AAC-LC with AudioConverter. Produces raw AAC
/// access units (no ADTS), which is what RTMP/FLV wants, plus the
/// AudioSpecificConfig for the sequence header.
final class AACEncoder {
    let sampleRate: Double
    let channels: Int
    let bitrate: Int
    private var converter: AudioConverterRef?
    private var inputFormat: AudioStreamBasicDescription
    private(set) var outputFormat: AudioStreamBasicDescription
    private var pending: [Float] = []        // interleaved
    private var pendingStart: Double = 0
    private var fedFrames: Int64 = 0
    private(set) var magicCookie: [UInt8] = []
    private let framesPerPacket = 1024
    private var feedBuffer: UnsafeMutablePointer<Float>
    private var feedFrames = 0
    private var feedConsumed = false
    private(set) var audioSpecificConfig: [UInt8]

    init?(sampleRate: Double = 48_000, channels: Int = 2, bitrateKbps: Int = 160) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrateKbps * 1000
        inputFormat = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                  mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                  mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        outputFormat = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                   mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                   mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let asc = AudioSpecificConfig.make(sampleRate: Int(sampleRate), channels: channels) else { return nil }
        audioSpecificConfig = asc
        feedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * channels)
        feedBuffer.initialize(repeating: 0, count: 1024 * channels)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inputFormat, &outputFormat, &conv) == noErr, let conv else { return nil }
        converter = conv
        var br = UInt32(self.bitrate)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        var cookieSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(conv, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioConverterGetProperty(conv, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie) == noErr {
                magicCookie = cookie
            }
        }
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
        feedBuffer.deallocate()
    }

    /// Feeds planar audio; returns every complete AAC packet produced.
    func encode(planes: [[Float]], frames: Int, timestamp: Double) -> [EncodedAudioPacket] {
        guard converter != nil, frames > 0 else { return [] }
        if pending.isEmpty { pendingStart = timestamp - Double(fedFrames % Int64(framesPerPacket)) / sampleRate }
        pending.reserveCapacity(pending.count + frames * channels)
        for f in 0..<frames {
            for c in 0..<channels { pending.append(c < planes.count ? planes[c][f] : 0) }
        }
        var out: [EncodedAudioPacket] = []
        while pending.count >= framesPerPacket * channels {
            let chunk = Array(pending[0..<framesPerPacket * channels])
            pending.removeFirst(framesPerPacket * channels)
            if let packet = encodeChunk(chunk) {
                out.append(EncodedAudioPacket(data: packet, timestamp: pendingStart, frames: framesPerPacket))
            }
            pendingStart += Double(framesPerPacket) / sampleRate
            fedFrames += Int64(framesPerPacket)
        }
        return out
    }

    private func encodeChunk(_ interleaved: [Float]) -> [UInt8]? {
        guard let conv = converter else { return nil }
        let n = min(interleaved.count, framesPerPacket * channels)
        interleaved.withUnsafeBufferPointer { src in feedBuffer.update(from: src.baseAddress!, count: n) }
        feedFrames = n / channels
        feedConsumed = false
        let outCapacity = 8192
        let outMem = UnsafeMutableRawPointer.allocate(byteCount: outCapacity, alignment: 16)
        defer { outMem.deallocate() }
        var outABL = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(outCapacity), mData: outMem))
        var packetCount: UInt32 = 1
        var packetDesc = AudioStreamPacketDescription()
        let status = AudioConverterFillComplexBuffer(conv, aacInputProc, Unmanaged.passUnretained(self).toOpaque(), &packetCount, &outABL, &packetDesc)
        guard status == noErr || status == kAACEncoderNoMoreData, packetCount > 0 else { return nil }
        let size = Int(packetDesc.mDataByteSize > 0 ? packetDesc.mDataByteSize : outABL.mBuffers.mDataByteSize)
        guard size > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: outMem.assumingMemoryBound(to: UInt8.self), count: size))
    }

    fileprivate func provideInput(_ ioNumberDataPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        if feedConsumed {
            ioNumberDataPackets.pointee = 0
            return kAACEncoderNoMoreData
        }
        feedConsumed = true
        let bytes = feedFrames * channels * 4
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        abl[0].mNumberChannels = UInt32(channels)
        abl[0].mDataByteSize = UInt32(bytes)
        abl[0].mData = UnsafeMutableRawPointer(feedBuffer)
        ioNumberDataPackets.pointee = UInt32(feedFrames)
        return noErr
    }

    /// Format description for AVAssetWriter passthrough of these packets.
    func formatDescription() -> CMAudioFormatDescription? {
        var desc: CMAudioFormatDescription?
        var fmt = outputFormat
        let st = magicCookie.withUnsafeBytes { cookie -> OSStatus in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &fmt, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: cookie.count > 0 ? cookie.baseAddress : nil,
                                           extensions: nil, formatDescriptionOut: &desc)
        }
        return st == noErr ? desc : nil
    }
}

private let kAACEncoderNoMoreData: OSStatus = -50_001

private func aacInputProc(_ inAudioConverter: AudioConverterRef,
                          _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                          _ ioData: UnsafeMutablePointer<AudioBufferList>,
                          _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                          _ inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let inUserData else { return -1 }
    let enc = Unmanaged<AACEncoder>.fromOpaque(inUserData).takeUnretainedValue()
    return enc.provideInput(ioNumberDataPackets, ioData)
}
