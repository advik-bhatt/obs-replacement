import AVFoundation
import CoreMediaIO
import Foundation
import UpstageCore

enum VideoDeviceKind: String {
    case builtIn = "Built-in"
    case continuityCamera = "Continuity Camera"
    case external = "External / USB"
    case iosDevice = "iPhone/iPad (wired screen)"
    case deskView = "Desk View"
    case virtual = "Virtual"

    var sortOrder: Int {
        switch self {
        case .continuityCamera: return 0
        case .iosDevice: return 1
        case .external: return 2
        case .builtIn: return 3
        case .deskView: return 4
        case .virtual: return 5
        }
    }
}

struct VideoFormatInfo: Hashable, Identifiable {
    var id: String { "\(width)x\(height)@\(Int(maxFrameRate))/\(pixelFormat)" }
    var width: Int
    var height: Int
    var maxFrameRate: Double
    var minFrameRate: Double
    var pixelFormat: String
    var size: Size2D { Size2D(width, height) }
    var label: String { "\(width)x\(height) @ \(String(format: "%.4g", maxFrameRate)) fps (\(pixelFormat))" }
}

struct VideoDeviceInfo: Identifiable, Hashable {
    var id: String { uniqueID }
    var uniqueID: String
    var name: String
    var modelID: String
    var kind: VideoDeviceKind
    var hasAudio: Bool
    var formats: [VideoFormatInfo]
    var isConnected: Bool
    var transport: String

    var maxFormat: VideoFormatInfo? {
        formats.max { a, b in
            if a.width * a.height != b.width * b.height { return a.width * a.height < b.width * b.height }
            return a.maxFrameRate < b.maxFrameRate
        }
    }
}

/// Finds every camera-like device macOS can offer: built-in, UVC webcams and
/// capture cards, Continuity Camera iPhones (USB or Wi-Fi, same device either
/// way), and iPhones/iPads attached over USB exposed as screen-capture devices
/// (what QuickTime's "Movie Recording" shows), which needs an explicit CoreMediaIO
/// opt-in.
final class VideoDeviceManager: ObservableObject {
    @Published private(set) var devices: [VideoDeviceInfo] = []
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    init() {
        VideoDeviceManager.allowScreenCaptureDevices()
        refresh()
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                self?.onChange?()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Lets iOS devices connected over USB appear as AVCaptureDevices (their screen).
    static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static var discoveryTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        types.append(.deskViewCamera)
        return types
    }

    static func allDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: discoveryTypes, mediaType: nil, position: .unspecified)
        var seen = Set<String>()
        var out: [AVCaptureDevice] = []
        for d in session.devices where d.hasMediaType(.video) || d.hasMediaType(.muxed) {
            if seen.insert(d.uniqueID).inserted { out.append(d) }
        }
        return out
    }

    static func device(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let d = AVCaptureDevice(uniqueID: uniqueID) { return d }
        if let uniqueID, let d = allDevices().first(where: { $0.uniqueID == uniqueID }) { return d }
        return nil
    }

    static func kind(of d: AVCaptureDevice) -> VideoDeviceKind {
        if d.deviceType == .continuityCamera { return .continuityCamera }
        if d.deviceType == .deskViewCamera { return .deskView }
        if d.hasMediaType(.muxed) || d.modelID.lowercased().contains("ios device") { return .iosDevice }
        if d.deviceType == .builtInWideAngleCamera { return .builtIn }
        if d.manufacturer.lowercased().contains("obs") || d.localizedName.lowercased().contains("virtual") { return .virtual }
        return .external
    }

    static func info(for d: AVCaptureDevice) -> VideoDeviceInfo {
        var formats: [VideoFormatInfo] = []
        var seen = Set<String>()
        for f in d.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let minFPS = f.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let fourcc = fourCCString(sub)
            let info = VideoFormatInfo(width: Int(dims.width), height: Int(dims.height), maxFrameRate: maxFPS, minFrameRate: minFPS, pixelFormat: fourcc)
            if seen.insert(info.id).inserted { formats.append(info) }
        }
        formats.sort { a, b in
            if a.width * a.height != b.width * b.height { return a.width * a.height > b.width * b.height }
            return a.maxFrameRate > b.maxFrameRate
        }
        let transport: String
        switch d.transportType {
        case Int32(upstageTransportTypeUSB): transport = "USB"
        case Int32(upstageTransportTypeBuiltIn): transport = "Built-in"
        default: transport = d.deviceType == .continuityCamera ? "Continuity (USB or Wi-Fi)" : ""
        }
        return VideoDeviceInfo(uniqueID: d.uniqueID, name: d.localizedName, modelID: d.modelID, kind: kind(of: d),
                               hasAudio: d.hasMediaType(.muxed) || d.hasMediaType(.audio), formats: formats,
                               isConnected: d.isConnected, transport: transport)
    }

    func refresh() {
        let list = VideoDeviceManager.allDevices().map(VideoDeviceManager.info(for:))
            .sorted { a, b in
                if a.kind.sortOrder != b.kind.sortOrder { return a.kind.sortOrder < b.kind.sortOrder }
                return a.name < b.name
            }
        if Thread.isMainThread {
            devices = list
        } else {
            DispatchQueue.main.async { self.devices = list }
        }
    }

    static func fourCCString(_ v: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        let s = String(bytes: bytes, encoding: .macOSRoman) ?? ""
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func requestAccess(_ mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: mediaType) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }
}

private let upstageTransportTypeUSB: UInt32 = 0x75736220 // 'usb '
private let upstageTransportTypeBuiltIn: UInt32 = 0x626C746E // 'bltn'
