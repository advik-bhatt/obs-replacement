import Foundation

/// Canvas and output presets. Base = where sources are composited, Output = what
/// gets encoded and shown. Unlike OBS, output may be LARGER than base: the final
/// pass upscales with MetalFX. The recommended layout for a Continuity Camera is
/// base == output == 4K so that overlays render at native 4K and only the
/// camera is upscaled (per-source), but a 1080p base with 4K output also works.
public enum CanvasPreset: String, Codable, CaseIterable, Hashable {
    case landscape4K
    case landscape1080p
    case landscape1440p
    case portrait4K
    case portrait1080p
    case square1080
    case square2160

    public var size: Size2D {
        switch self {
        case .landscape4K: return Size2D(3840, 2160)
        case .landscape1080p: return Size2D(1920, 1080)
        case .landscape1440p: return Size2D(2560, 1440)
        case .portrait4K: return Size2D(2160, 3840)
        case .portrait1080p: return Size2D(1080, 1920)
        case .square1080: return Size2D(1080, 1080)
        case .square2160: return Size2D(2160, 2160)
        }
    }

    public var label: String {
        switch self {
        case .landscape4K: return "4K UHD 3840x2160 (16:9)"
        case .landscape1080p: return "1080p 1920x1080 (16:9)"
        case .landscape1440p: return "1440p 2560x1440 (16:9)"
        case .portrait4K: return "Portrait 4K 2160x3840 (9:16)"
        case .portrait1080p: return "Portrait 1080p 1080x1920 (9:16)"
        case .square1080: return "Square 1080x1080 (1:1)"
        case .square2160: return "Square 2160x2160 (1:1)"
        }
    }

    public static func matching(_ size: Size2D) -> CanvasPreset? {
        allCases.first { $0.size == size }
    }
}

public enum UpscalerKind: String, Codable, CaseIterable, Hashable {
    case metalFX
    case lanczos
    case bilinear

    public var label: String {
        switch self {
        case .metalFX: return "MetalFX spatial (recommended)"
        case .lanczos: return "Lanczos"
        case .bilinear: return "Bilinear"
        }
    }
}

public struct VideoSettings: Codable, Equatable, Hashable {
    public var baseSize: Size2D
    public var outputSize: Size2D
    public var frameRate: Double
    /// Used for the base -> output pass when they differ.
    public var upscaler: UpscalerKind
    /// Default for new video sources.
    public var sourceUpscale: UpscaleMode

    public init(baseSize: Size2D = CanvasPreset.landscape4K.size,
                outputSize: Size2D = CanvasPreset.landscape4K.size,
                frameRate: Double = 30,
                upscaler: UpscalerKind = .metalFX,
                sourceUpscale: UpscaleMode = .auto) {
        self.baseSize = baseSize
        self.outputSize = outputSize
        self.frameRate = frameRate
        self.upscaler = upscaler
        self.sourceUpscale = sourceUpscale
    }

    public static let commonFrameRates: [Double] = [24, 25, 29.97, 30, 48, 50, 59.94, 60]

    public var isPortrait: Bool { outputSize.isPortrait }

    /// Both sizes must be even for every hardware encoder and for 4:2:0 chroma.
    public var validationErrors: [String] {
        var errs: [String] = []
        for (label, s) in [("Base", baseSize), ("Output", outputSize)] {
            if s.width < 64 || s.height < 64 { errs.append("\(label) resolution is too small (minimum 64x64).") }
            if s.width > 8192 || s.height > 8192 { errs.append("\(label) resolution exceeds 8192 on a side.") }
            if s.width % 2 != 0 || s.height % 2 != 0 { errs.append("\(label) resolution must use even numbers.") }
        }
        if frameRate < 1 || frameRate > 240 { errs.append("Frame rate must be between 1 and 240.") }
        return errs
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Hashable {
    case h264
    case hevc
    case proRes422
    case proRes4444

    public var label: String {
        switch self {
        case .h264: return "H.264 (hardware)"
        case .hevc: return "HEVC / H.265 (hardware)"
        case .proRes422: return "Apple ProRes 422"
        case .proRes4444: return "Apple ProRes 4444"
        }
    }

    public var isProRes: Bool { self == .proRes422 || self == .proRes4444 }
    public var supportsStreaming: Bool { self == .h264 }
}

public enum ContainerFormat: String, Codable, CaseIterable, Hashable {
    case mp4
    case mov

    public var fileExtension: String { rawValue }
    public var label: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "QuickTime MOV (required for ProRes)"
        }
    }
}

public enum RateControl: Codable, Equatable, Hashable {
    /// Average bitrate in kbps.
    case bitrate(Int)
    /// Constant quality 0...1 (VideoToolbox quality key).
    case quality(Double)

    public var isBitrate: Bool {
        if case .bitrate = self { return true }
        return false
    }
}

public struct RecordingSettings: Codable, Equatable, Hashable {
    /// Directory path; `~` is expanded by the app.
    public var directory: String
    /// strftime-style tokens: %Y %m %d %H %M %S plus %SCENE.
    public var filenameFormat: String
    public var container: ContainerFormat
    public var codec: VideoCodec
    public var rateControl: RateControl
    public var keyframeIntervalSeconds: Double
    public var audioBitrateKbps: Int
    /// Which mix track is recorded (1-based).
    public var audioTrack: Int

    public init(directory: String = "~/Movies/Upstage",
                filenameFormat: String = "%Y-%m-%d %H-%M-%S",
                container: ContainerFormat = .mp4,
                codec: VideoCodec = .hevc,
                rateControl: RateControl = .bitrate(40_000),
                keyframeIntervalSeconds: Double = 2,
                audioBitrateKbps: Int = 256,
                audioTrack: Int = 1) {
        self.directory = directory
        self.filenameFormat = filenameFormat
        self.container = container
        self.codec = codec
        self.rateControl = rateControl
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.audioBitrateKbps = audioBitrateKbps
        self.audioTrack = audioTrack
    }

    public var validationErrors: [String] {
        var errs: [String] = []
        if codec.isProRes && container != .mov { errs.append("ProRes requires the MOV container.") }
        if case .bitrate(let kbps) = rateControl, kbps < 500 { errs.append("Video bitrate below 500 kbps.") }
        return errs
    }

    /// Expands the filename format for the given date and scene name.
    public func filename(date: Date, sceneName: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone.current, from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        var s = filenameFormat
        s = s.replacingOccurrences(of: "%SCENE", with: sceneName)
        s = s.replacingOccurrences(of: "%Y", with: String(c.year ?? 0))
        s = s.replacingOccurrences(of: "%m", with: two(c.month))
        s = s.replacingOccurrences(of: "%d", with: two(c.day))
        s = s.replacingOccurrences(of: "%H", with: two(c.hour))
        s = s.replacingOccurrences(of: "%M", with: two(c.minute))
        s = s.replacingOccurrences(of: "%S", with: two(c.second))
        let illegal = CharacterSet(charactersIn: "/:\\")
        s = s.components(separatedBy: illegal).joined(separator: "-")
        return s + "." + container.fileExtension
    }
}

public enum StreamService: String, Codable, CaseIterable, Hashable {
    case twitch
    case youtube
    case kick
    case facebook
    case custom

    public var label: String {
        switch self {
        case .twitch: return "Twitch"
        case .youtube: return "YouTube"
        case .kick: return "Kick"
        case .facebook: return "Facebook Live"
        case .custom: return "Custom RTMP/RTMPS"
        }
    }

    /// Ingest URLs. Twitch and YouTube publish stable ingest hosts; Kick hands
    /// each account its own URL in the dashboard, so it stays a custom entry
    /// with a hint.
    public var servers: [(name: String, url: String)] {
        switch self {
        case .twitch:
            return [
                ("Auto (nearest)", "rtmp://live.twitch.tv/app"),
                ("Auto (nearest, RTMPS)", "rtmps://live.twitch.tv:443/app"),
            ]
        case .youtube:
            return [
                ("Primary (RTMPS)", "rtmps://a.rtmps.youtube.com:443/live2"),
                ("Primary (RTMP)", "rtmp://a.rtmp.youtube.com/live2"),
                ("Backup (RTMPS)", "rtmps://b.rtmps.youtube.com:443/live2?backup=1"),
            ]
        case .kick:
            return [("Paste the Stream URL from Kick > Creator Dashboard > Settings > Stream Key", "")]
        case .facebook:
            return [("Default (RTMPS)", "rtmps://live-api-s.facebook.com:443/rtmp/")]
        case .custom:
            return []
        }
    }

    public var recommendedMaxVideoKbps: Int? {
        switch self {
        case .twitch: return 8000
        case .youtube: return 51_000
        case .kick: return 8000
        case .facebook: return 8000
        case .custom: return nil
        }
    }
}

public struct StreamSettings: Codable, Equatable, Hashable {
    public var service: StreamService
    public var serverURL: String
    /// Kept in the profile file (user-only readable). Blank = not configured.
    public var streamKey: String
    public var videoBitrateKbps: Int
    public var audioBitrateKbps: Int
    public var keyframeIntervalSeconds: Double
    /// Encoded stream size. nil = same as output.
    public var scaledSize: Size2D?
    public var autoReconnect: Bool
    public var reconnectDelaySeconds: Int
    public var maxReconnectAttempts: Int
    public var audioTrack: Int

    public init(service: StreamService = .twitch,
                serverURL: String = "rtmp://live.twitch.tv/app",
                streamKey: String = "",
                videoBitrateKbps: Int = 6000,
                audioBitrateKbps: Int = 160,
                keyframeIntervalSeconds: Double = 2,
                scaledSize: Size2D? = nil,
                autoReconnect: Bool = true,
                reconnectDelaySeconds: Int = 5,
                maxReconnectAttempts: Int = 20,
                audioTrack: Int = 1) {
        self.service = service
        self.serverURL = serverURL
        self.streamKey = streamKey
        self.videoBitrateKbps = videoBitrateKbps
        self.audioBitrateKbps = audioBitrateKbps
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.scaledSize = scaledSize
        self.autoReconnect = autoReconnect
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.maxReconnectAttempts = maxReconnectAttempts
        self.audioTrack = audioTrack
    }

    public var isConfigured: Bool { !serverURL.isEmpty && !streamKey.isEmpty }

    public var validationErrors: [String] {
        var errs: [String] = []
        if serverURL.isEmpty { errs.append("Stream server URL is empty.") }
        else if RTMPURL(string: serverURL) == nil { errs.append("Stream server URL is not a valid rtmp:// or rtmps:// URL.") }
        if streamKey.isEmpty { errs.append("Stream key is empty.") }
        if let cap = service.recommendedMaxVideoKbps, videoBitrateKbps > cap {
            errs.append("\(service.label) recommends at most \(cap) kbps of video.")
        }
        return errs
    }
}

public enum AudioChannelLayout: String, Codable, CaseIterable, Hashable {
    case mono
    case stereo

    public var channelCount: Int { self == .mono ? 1 : 2 }
}

public struct GlobalAudioSettings: Codable, Equatable, Hashable {
    public var sampleRate: Double
    public var layout: AudioChannelLayout
    /// CoreAudio device UID for monitoring; nil = system default output.
    public var monitoringDeviceUID: String?
    public var monitoringDeviceName: String?
    /// Peak meter fall rate in dB per second.
    public var meterDecayDBPerSecond: Double

    public init(sampleRate: Double = 48_000, layout: AudioChannelLayout = .stereo,
                monitoringDeviceUID: String? = nil, monitoringDeviceName: String? = nil,
                meterDecayDBPerSecond: Double = 23.53) {
        self.sampleRate = sampleRate
        self.layout = layout
        self.monitoringDeviceUID = monitoringDeviceUID
        self.monitoringDeviceName = monitoringDeviceName
        self.meterDecayDBPerSecond = meterDecayDBPerSecond
    }
}

public struct ReplayBufferSettings: Codable, Equatable, Hashable {
    public var enabled: Bool
    public var seconds: Int
    public var filenamePrefix: String

    public init(enabled: Bool = false, seconds: Int = 30, filenamePrefix: String = "Replay") {
        self.enabled = enabled
        self.seconds = seconds
        self.filenamePrefix = filenamePrefix
    }
}

public struct RemoteControlSettings: Codable, Equatable, Hashable {
    public var enabled: Bool
    public var port: UInt16
    public var password: String

    public init(enabled: Bool = false, port: UInt16 = 4455, password: String = "") {
        self.enabled = enabled
        self.port = port
        self.password = password
    }
}

public struct GeneralSettings: Codable, Equatable, Hashable {
    public var confirmBeforeStoppingStream: Bool
    public var confirmBeforeStoppingRecording: Bool
    public var showPreviewSafeAreas: Bool
    public var snapToEdges: Bool
    public var autoSaveIntervalSeconds: Int

    public init(confirmBeforeStoppingStream: Bool = true, confirmBeforeStoppingRecording: Bool = false,
                showPreviewSafeAreas: Bool = false, snapToEdges: Bool = true, autoSaveIntervalSeconds: Int = 5) {
        self.confirmBeforeStoppingStream = confirmBeforeStoppingStream
        self.confirmBeforeStoppingRecording = confirmBeforeStoppingRecording
        self.showPreviewSafeAreas = showPreviewSafeAreas
        self.snapToEdges = snapToEdges
        self.autoSaveIntervalSeconds = autoSaveIntervalSeconds
    }
}

/// A profile is everything that is not scene content: output, encoding, audio,
/// control surfaces. Saved as one JSON document, like OBS profiles.
public struct Profile: Codable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var name: String
    public var general: GeneralSettings
    public var video: VideoSettings
    public var recording: RecordingSettings
    public var stream: StreamSettings
    public var audio: GlobalAudioSettings
    public var replay: ReplayBufferSettings
    public var remote: RemoteControlSettings
    public var hotkeys: HotkeyBindings
    public var midi: [MIDIBinding]

    public init(name: String = "Default",
                general: GeneralSettings = GeneralSettings(),
                video: VideoSettings = VideoSettings(),
                recording: RecordingSettings = RecordingSettings(),
                stream: StreamSettings = StreamSettings(),
                audio: GlobalAudioSettings = GlobalAudioSettings(),
                replay: ReplayBufferSettings = ReplayBufferSettings(),
                remote: RemoteControlSettings = RemoteControlSettings(),
                hotkeys: HotkeyBindings = .defaults,
                midi: [MIDIBinding] = []) {
        self.version = Profile.formatVersion
        self.name = name
        self.general = general
        self.video = video
        self.recording = recording
        self.stream = stream
        self.audio = audio
        self.replay = replay
        self.remote = remote
        self.hotkeys = hotkeys
        self.midi = midi
    }

    /// Portrait 4K preset: what an iPhone mounted vertically as a Continuity Camera wants.
    public static func portrait4K() -> Profile {
        var p = Profile(name: "Portrait 4K")
        p.video.baseSize = CanvasPreset.portrait4K.size
        p.video.outputSize = CanvasPreset.portrait4K.size
        return p
    }

    public var validationErrors: [String] {
        video.validationErrors + recording.validationErrors
    }
}
