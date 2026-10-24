import Foundation

/// Every kind of input the app can bring into a scene. Mirrors OBS's source
/// catalogue for macOS.
public enum SourceKind: String, Codable, CaseIterable, Hashable {
    case camera          // Any AVCaptureDevice: built-in, USB/UVC, capture card, Continuity Camera (wired or wireless), wired iPhone screen
    case display         // ScreenCaptureKit display capture
    case window          // ScreenCaptureKit window capture
    case audioInput      // Any CoreAudio input device, every channel (BlackHole 16ch, interfaces, aggregate devices)
    case systemAudio     // Desktop audio via ScreenCaptureKit
    case media           // Video/audio file playback
    case image
    case text
    case color

    public var displayName: String {
        switch self {
        case .camera: return "Video Capture Device"
        case .display: return "Display Capture"
        case .window: return "Window Capture"
        case .audioInput: return "Audio Input Capture"
        case .systemAudio: return "Desktop Audio"
        case .media: return "Media Source"
        case .image: return "Image"
        case .text: return "Text"
        case .color: return "Color Source"
        }
    }

    public var hasVideo: Bool {
        switch self {
        case .audioInput, .systemAudio: return false
        default: return true
        }
    }

    public var hasAudio: Bool {
        switch self {
        case .audioInput, .systemAudio, .media, .camera: return true
        default: return false
        }
    }
}

/// How a source that is drawn larger than its native size gets upscaled.
public enum UpscaleMode: String, Codable, CaseIterable, Hashable {
    /// MetalFX spatial upscaler when the GPU supports it, Lanczos otherwise.
    case auto
    case metalFX
    case lanczos
    /// Plain bilinear sampling, what a naive compositor does.
    case off

    public var label: String {
        switch self {
        case .auto: return "Auto (MetalFX, Lanczos fallback)"
        case .metalFX: return "MetalFX spatial"
        case .lanczos: return "Lanczos"
        case .off: return "Off (bilinear)"
        }
    }
}

public struct CameraSettings: Codable, Equatable, Hashable {
    /// AVCaptureDevice.uniqueID. nil means "system preferred camera".
    public var deviceUniqueID: String?
    /// Last known localized name, kept so the UI can show something when the device is unplugged.
    public var deviceName: String?
    /// Requested capture size; the largest format at or above this is chosen. nil = largest available.
    public var preferredSize: Size2D?
    public var preferredFrameRate: Double?
    public var rotation: Rotation
    public var mirror: Bool
    /// Capture audio from the same device (muxed devices such as a wired iPhone screen).
    public var captureAudio: Bool
    /// Keep the device's native YCbCr format instead of asking the system for BGRA.
    public var buffering: Bool

    public init(deviceUniqueID: String? = nil,
                deviceName: String? = nil,
                preferredSize: Size2D? = nil,
                preferredFrameRate: Double? = nil,
                rotation: Rotation = .r0,
                mirror: Bool = false,
                captureAudio: Bool = false,
                buffering: Bool = false) {
        self.deviceUniqueID = deviceUniqueID
        self.deviceName = deviceName
        self.preferredSize = preferredSize
        self.preferredFrameRate = preferredFrameRate
        self.rotation = rotation
        self.mirror = mirror
        self.captureAudio = captureAudio
        self.buffering = buffering
    }
}

public struct DisplaySettings: Codable, Equatable, Hashable {
    /// CGDirectDisplayID. nil = main display.
    public var displayID: UInt32?
    public var showCursor: Bool
    public var frameRate: Double

    public init(displayID: UInt32? = nil, showCursor: Bool = true, frameRate: Double = 60) {
        self.displayID = displayID
        self.showCursor = showCursor
        self.frameRate = frameRate
    }
}

public struct WindowSettings: Codable, Equatable, Hashable {
    public var windowID: UInt32?
    public var ownerName: String?
    public var title: String?
    public var showCursor: Bool
    public var frameRate: Double

    public init(windowID: UInt32? = nil, ownerName: String? = nil, title: String? = nil,
                showCursor: Bool = false, frameRate: Double = 60) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.title = title
        self.showCursor = showCursor
        self.frameRate = frameRate
    }
}

public struct AudioInputSettings: Codable, Equatable, Hashable {
    /// CoreAudio device UID (kAudioDevicePropertyDeviceUID). nil = default input.
    public var deviceUID: String?
    public var deviceName: String?
    /// Which of the device's channels feed the mix. Rebuilt when the device's channel count changes.
    public var channelMatrix: ChannelMatrix

    public init(deviceUID: String? = nil, deviceName: String? = nil,
                channelMatrix: ChannelMatrix = .defaultMapping(inputChannels: 2)) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.channelMatrix = channelMatrix
    }
}

public struct SystemAudioSettings: Codable, Equatable, Hashable {
    public var excludeOwnProcess: Bool
    public init(excludeOwnProcess: Bool = true) {
        self.excludeOwnProcess = excludeOwnProcess
    }
}

public struct MediaSettings: Codable, Equatable, Hashable {
    public var path: String?
    public var loop: Bool
    public var restartWhenActivated: Bool
    public var hardwareDecode: Bool

    public init(path: String? = nil, loop: Bool = true, restartWhenActivated: Bool = true, hardwareDecode: Bool = true) {
        self.path = path
        self.loop = loop
        self.restartWhenActivated = restartWhenActivated
        self.hardwareDecode = hardwareDecode
    }
}

public struct ImageSettings: Codable, Equatable, Hashable {
    public var path: String?
    public init(path: String? = nil) { self.path = path }
}

public enum TextAlignment: String, Codable, CaseIterable, Hashable {
    case left, center, right
}

public struct TextSettings: Codable, Equatable, Hashable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var color: RGBA
    public var backgroundColor: RGBA
    public var alignment: TextAlignment
    public var outlineWidth: Double
    public var outlineColor: RGBA
    /// Fixed layout width in pixels; 0 = fit to text.
    public var wrapWidth: Int

    public init(text: String = "Text",
                fontName: String = "Helvetica-Bold",
                fontSize: Double = 96,
                color: RGBA = .white,
                backgroundColor: RGBA = .clear,
                alignment: TextAlignment = .left,
                outlineWidth: Double = 0,
                outlineColor: RGBA = .black,
                wrapWidth: Int = 0) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
        self.alignment = alignment
        self.outlineWidth = outlineWidth
        self.outlineColor = outlineColor
        self.wrapWidth = wrapWidth
    }
}

public struct ColorSettings: Codable, Equatable, Hashable {
    public var color: RGBA
    public var size: Size2D

    public init(color: RGBA = RGBA(r: 0.1, g: 0.1, b: 0.1), size: Size2D = Size2D(1920, 1080)) {
        self.color = color
        self.size = size
    }
}

/// Per-kind settings. Codable synthesis handles the associated values.
public enum SourceSettings: Codable, Equatable, Hashable {
    case camera(CameraSettings)
    case display(DisplaySettings)
    case window(WindowSettings)
    case audioInput(AudioInputSettings)
    case systemAudio(SystemAudioSettings)
    case media(MediaSettings)
    case image(ImageSettings)
    case text(TextSettings)
    case color(ColorSettings)

    public var kind: SourceKind {
        switch self {
        case .camera: return .camera
        case .display: return .display
        case .window: return .window
        case .audioInput: return .audioInput
        case .systemAudio: return .systemAudio
        case .media: return .media
        case .image: return .image
        case .text: return .text
        case .color: return .color
        }
    }

    public static func defaults(for kind: SourceKind) -> SourceSettings {
        switch kind {
        case .camera: return .camera(CameraSettings())
        case .display: return .display(DisplaySettings())
        case .window: return .window(WindowSettings())
        case .audioInput: return .audioInput(AudioInputSettings())
        case .systemAudio: return .systemAudio(SystemAudioSettings())
        case .media: return .media(MediaSettings())
        case .image: return .image(ImageSettings())
        case .text: return .text(TextSettings())
        case .color: return .color(ColorSettings())
        }
    }
}

/// Audio-side state for any source that produces sound.
public struct SourceAudioSettings: Codable, Equatable, Hashable {
    /// Fader position in dB; 0 is unity, -inf (represented as -100) is silent.
    public var volumeDB: Double
    public var muted: Bool
    public var monitoring: MonitoringMode
    /// Milliseconds added to this source's audio timestamps (positive delays it).
    public var syncOffsetMs: Int
    /// Mix tracks this source feeds (bit mask, track 1 = 1). Recording/streaming pick a track.
    public var tracks: UInt8

    public init(volumeDB: Double = 0, muted: Bool = false, monitoring: MonitoringMode = .off,
                syncOffsetMs: Int = 0, tracks: UInt8 = 0b0011_1111) {
        self.volumeDB = volumeDB
        self.muted = muted
        self.monitoring = monitoring
        self.syncOffsetMs = syncOffsetMs
        self.tracks = tracks
    }

    public var linearGain: Float { muted ? 0 : AudioMath.linear(fromDB: volumeDB) }
}

public enum MonitoringMode: String, Codable, CaseIterable, Hashable {
    case off
    case monitorOnly
    case monitorAndOutput

    public var label: String {
        switch self {
        case .off: return "Monitor Off"
        case .monitorOnly: return "Monitor Only (mute output)"
        case .monitorAndOutput: return "Monitor and Output"
        }
    }
}

/// A source as stored in a scene collection. One source can appear in many scenes.
public struct SourceDescriptor: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var settings: SourceSettings
    public var filters: [FilterDescriptor]
    public var audio: SourceAudioSettings
    /// Applies when a scene item draws this source larger than its native pixels.
    public var upscale: UpscaleMode

    public init(id: UUID = UUID(),
                name: String,
                settings: SourceSettings,
                filters: [FilterDescriptor] = [],
                audio: SourceAudioSettings = SourceAudioSettings(),
                upscale: UpscaleMode = .auto) {
        self.id = id
        self.name = name
        self.settings = settings
        self.filters = filters
        self.audio = audio
        self.upscale = upscale
    }

    public var kind: SourceKind { settings.kind }
}
