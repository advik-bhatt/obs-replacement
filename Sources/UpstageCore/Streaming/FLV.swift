import Foundation

/// FLV tag bodies as they travel inside RTMP audio/video messages.
public enum FLVVideo {
    public static let codecAVC: UInt8 = 7

    /// AVCDecoderConfigurationRecord as the first video message.
    public static func avcSequenceHeader(avcC: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: avcC.count + 5)
        w.u8(0x10 | codecAVC) // keyframe, AVC
        w.u8(0)               // AVCPacketType: sequence header
        w.u24(0)              // composition time
        w.append(avcC)
        return w.bytes
    }

    /// One access unit in AVCC format (4-byte length prefixed NAL units).
    public static func avcNALU(keyframe: Bool, compositionTimeMs: Int32, avcc: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: avcc.count + 5)
        w.u8((keyframe ? 0x10 : 0x20) | codecAVC)
        w.u8(1)
        w.u24(UInt32(bitPattern: compositionTimeMs) & 0xFFFFFF)
        w.append(avcc)
        return w.bytes
    }

    public static func avcEndOfSequence() -> [UInt8] {
        [0x10 | codecAVC, 2, 0, 0, 0]
    }
}

public enum FLVAudio {
    /// SoundFormat AAC (10), SoundRate 44kHz flag (3, mandatory for AAC), 16-bit, stereo.
    public static let aacHeader: UInt8 = 0xAF

    public static func aacSequenceHeader(audioSpecificConfig: [UInt8]) -> [UInt8] {
        [aacHeader, 0] + audioSpecificConfig
    }

    public static func aacRaw(_ frame: [UInt8]) -> [UInt8] {
        [aacHeader, 1] + frame
    }
}

/// MPEG-4 AudioSpecificConfig for AAC-LC, the two bytes RTMP servers expect in
/// the AAC sequence header.
public enum AudioSpecificConfig {
    public static let sampleRateIndex: [Int: UInt8] = [
        96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5, 24000: 6, 22050: 7,
        16000: 8, 12000: 9, 11025: 10, 8000: 11, 7350: 12,
    ]

    /// `objectType` 2 = AAC-LC. Returns nil for unsupported sample rates.
    public static func make(objectType: UInt8 = 2, sampleRate: Int, channels: Int) -> [UInt8]? {
        guard let idx = sampleRateIndex[sampleRate], channels >= 1, channels <= 7 else { return nil }
        let b0 = (objectType << 3) | (idx >> 1)
        let b1 = ((idx & 1) << 7) | (UInt8(channels) << 3)
        return [b0, b1]
    }

    public static func parse(_ asc: [UInt8]) -> (objectType: UInt8, sampleRate: Int, channels: Int)? {
        guard asc.count >= 2 else { return nil }
        let objectType = asc[0] >> 3
        let idx = Int((asc[0] & 0x7) << 1 | (asc[1] >> 7))
        let channels = Int((asc[1] >> 3) & 0xF)
        guard let rate = sampleRateIndex.first(where: { $0.value == UInt8(idx) })?.key else { return nil }
        return (objectType, rate, channels)
    }
}

/// H.264 helpers: build/parse the AVCDecoderConfigurationRecord and walk AVCC payloads.
public enum H264 {
    public enum NALType: UInt8 {
        case nonIDR = 1, partitionA = 2, partitionB = 3, partitionC = 4, idr = 5, sei = 6, sps = 7, pps = 8, aud = 9
    }

    public static func nalType(_ firstByte: UInt8) -> UInt8 { firstByte & 0x1F }

    /// Builds avcC from one SPS and one PPS. `lengthSize` is normally 4.
    public static func avcC(sps: [UInt8], pps: [UInt8], lengthSize: Int = 4) -> [UInt8] {
        var w = ByteWriter(capacity: sps.count + pps.count + 16)
        w.u8(1)
        w.u8(sps.count > 1 ? sps[1] : 0x42) // profile_idc
        w.u8(sps.count > 2 ? sps[2] : 0x00) // constraint flags
        w.u8(sps.count > 3 ? sps[3] : 0x1E) // level_idc
        w.u8(0xFC | UInt8((lengthSize - 1) & 0x3))
        w.u8(0xE0 | 1)
        w.u16(UInt16(sps.count))
        w.append(sps)
        w.u8(1)
        w.u16(UInt16(pps.count))
        w.append(pps)
        return w.bytes
    }

    public struct DecoderConfig: Equatable {
        public var sps: [[UInt8]]
        public var pps: [[UInt8]]
        public var lengthSize: Int
        public var profile: UInt8
        public var level: UInt8
    }

    public static func parseAvcC(_ bytes: [UInt8]) throws -> DecoderConfig {
        var r = ByteReader(bytes)
        guard try r.u8() == 1 else { throw ByteReaderError.malformed("avcC version") }
        let profile = try r.u8()
        _ = try r.u8()
        let level = try r.u8()
        let lengthSize = Int(try r.u8() & 0x3) + 1
        let spsCount = Int(try r.u8() & 0x1F)
        var sps: [[UInt8]] = []
        for _ in 0..<spsCount { sps.append(try r.take(Int(try r.u16()))) }
        let ppsCount = Int(try r.u8())
        var pps: [[UInt8]] = []
        for _ in 0..<ppsCount { pps.append(try r.take(Int(try r.u16()))) }
        return DecoderConfig(sps: sps, pps: pps, lengthSize: lengthSize, profile: profile, level: level)
    }

    /// Splits a length-prefixed (AVCC) access unit into NAL units.
    public static func nalUnits(avcc: [UInt8], lengthSize: Int = 4) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i + lengthSize <= avcc.count {
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(avcc[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= avcc.count else { break }
            out.append(Array(avcc[i..<i + len]))
            i += len
        }
        return out
    }

    /// Joins NAL units with 4-byte length prefixes.
    public static func avcc(nalUnits: [[UInt8]]) -> [UInt8] {
        var w = ByteWriter()
        for n in nalUnits {
            w.u32(UInt32(n.count))
            w.append(n)
        }
        return w.bytes
    }

    /// Converts Annex B (start-code delimited) to AVCC.
    public static func annexBToAVCC(_ data: [UInt8]) -> [UInt8] {
        var units: [[UInt8]] = []
        var i = 0
        var start: Int? = nil
        while i + 2 < data.count {
            if data[i] == 0 && data[i + 1] == 0 && (data[i + 2] == 1 || (i + 3 < data.count && data[i + 2] == 0 && data[i + 3] == 1)) {
                if let s = start {
                    var end = i
                    while end > s && data[end - 1] == 0 { end -= 1 }
                    if end > s { units.append(Array(data[s..<end])) }
                }
                i += data[i + 2] == 1 ? 3 : 4
                start = i
                continue
            }
            i += 1
        }
        if let s = start, s < data.count { units.append(Array(data[s..<data.count])) }
        return avcc(nalUnits: units)
    }

    public static func containsIDR(avcc: [UInt8], lengthSize: Int = 4) -> Bool {
        nalUnits(avcc: avcc, lengthSize: lengthSize).contains { !$0.isEmpty && nalType($0[0]) == NALType.idr.rawValue }
    }
}
