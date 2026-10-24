import CoreMedia
import CoreVideo
import Foundation
import UpstageCore
import VideoToolbox

struct EncodedVideoFrame {
    /// AVCC / HVCC formatted access unit (length-prefixed NAL units).
    let data: [UInt8]
    let isKeyframe: Bool
    /// Seconds on the engine clock.
    let pts: Double
    let dts: Double
    let formatDescription: CMFormatDescription
    let sampleBuffer: CMSampleBuffer
}

/// Hardware H.264/HEVC encoder (VideoToolbox) for streaming and the replay
/// buffer. Low-latency configuration: no B-frames, fixed GOP, real-time.
final class VideoEncoder {
    let codec: VideoCodec
    let size: Size2D
    let frameRate: Double
    let rateControl: RateControl
    let keyframeIntervalSeconds: Double
    private var session: VTCompressionSession?
    private let callbackQueue = DispatchQueue(label: "upstage.vt", qos: .userInitiated)
    var onFrame: ((EncodedVideoFrame) -> Void)?
    private(set) var framesIn: Int = 0
    private(set) var framesOut: Int = 0
    private(set) var framesDropped: Int = 0
    private var forceKey = false
    /// SPS/PPS (H.264) extracted from the first keyframe's format description.
    private(set) var avcC: [UInt8]?

    init?(codec: VideoCodec, size: Size2D, frameRate: Double, rateControl: RateControl, keyframeIntervalSeconds: Double) {
        guard codec == .h264 || codec == .hevc else { return nil }
        self.codec = codec
        self.size = size
        self.frameRate = frameRate
        self.rateControl = rateControl
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        let srcAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferWidthKey as String: size.width,
                                       kCVPixelBufferHeightKey as String: size.height]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(size.width), height: Int32(size.height),
                                            codecType: codecType, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: srcAttrs as CFDictionary, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { return nil }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(frameRate * keyframeIntervalSeconds) as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeIntervalSeconds as CFNumber)
        if codec == .h264 {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        } else {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        switch rateControl {
        case .bitrate(let kbps):
            let bps = kbps * 1000
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
            // Cap bursts at ~1.5x the average per second so RTMP ingest stays happy.
            let limits: [Any] = [Int(Double(bps) * 1.5 / 8), 1]
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        case .quality(let q):
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit {
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
    }

    func forceKeyframe() { forceKey = true }

    /// Submits one frame. `pts` seconds on the engine clock.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        guard let s = session else { return }
        framesIn += 1
        let time = CMTime(seconds: pts, preferredTimescale: 90_000)
        let duration = CMTime(seconds: 1 / frameRate, preferredTimescale: 90_000)
        var props: [String: Any] = [:]
        if forceKey {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
            forceKey = false
        }
        var flags = VTEncodeInfoFlags()
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: duration,
                                                 frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: &flags) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sb = sampleBuffer, !infoFlags.contains(.frameDropped) else {
                self.framesDropped += 1
                return
            }
            self.handle(sb)
        }
        if st != noErr { framesDropped += 1 }
    }

    func flush() {
        guard let s = session else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    }

    private func handle(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb), let fd = CMSampleBufferGetFormatDescription(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { isKey = !notSync }
        }
        if isKey, avcC == nil, codec == .h264 {
            avcC = VideoEncoder.extractAvcC(from: fd)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: length)
        // A VideoToolbox block buffer may be non-contiguous; copy instead of taking a pointer.
        let copyStatus = bytes.withUnsafeMutableBytes { dst in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: dst.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let dtsTime = CMSampleBufferGetDecodeTimeStamp(sb)
        let dts = dtsTime.isValid ? CMTimeGetSeconds(dtsTime) : pts
        framesOut += 1
        onFrame?(EncodedVideoFrame(data: bytes, isKeyframe: isKey, pts: pts, dts: dts, formatDescription: fd, sampleBuffer: sb))
    }

    /// Pulls SPS/PPS out of the format description and rebuilds an avcC record.
    static func extractAvcC(from fd: CMFormatDescription) -> [UInt8]? {
        var count = 0
        var nalLength: Int32 = 4
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr, count >= 2 else { return nil }
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
        }
        let sps = sets.first { H264.nalType($0[0]) == H264.NALType.sps.rawValue } ?? sets[0]
        let pps = sets.first { H264.nalType($0[0]) == H264.NALType.pps.rawValue } ?? sets[1]
        return H264.avcC(sps: sps, pps: pps, lengthSize: Int(nalLength))
    }
}
