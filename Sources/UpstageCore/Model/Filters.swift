import Foundation

public struct ColorCorrectionFilter: Codable, Equatable, Hashable {
    /// -1...1 added to RGB.
    public var brightness: Double
    /// 0...4, 1 = unchanged.
    public var contrast: Double
    /// 0...4, 1 = unchanged.
    public var saturation: Double
    /// 0.1...4, 1 = unchanged.
    public var gamma: Double
    /// Degrees, -180...180.
    public var hueShift: Double
    public var opacity: Double

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
                gamma: Double = 1, hueShift: Double = 0, opacity: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.hueShift = hueShift
        self.opacity = opacity
    }
}

public struct ChromaKeyFilter: Codable, Equatable, Hashable {
    public var keyColor: RGBA
    /// 0...1 how far from the key colour still counts as background.
    public var similarity: Double
    /// 0...1 softness of the edge.
    public var smoothness: Double
    /// 0...1 how much of the key colour to pull out of edge pixels.
    public var spillReduction: Double

    public init(keyColor: RGBA = .chromaGreen, similarity: Double = 0.4,
                smoothness: Double = 0.08, spillReduction: Double = 0.5) {
        self.keyColor = keyColor
        self.similarity = similarity
        self.smoothness = smoothness
        self.spillReduction = spillReduction
    }
}

public struct SharpenFilter: Codable, Equatable, Hashable {
    /// 0...1
    public var amount: Double
    public init(amount: Double = 0.3) { self.amount = amount }
}

public struct BlurFilter: Codable, Equatable, Hashable {
    /// Pixels, 0...64
    public var radius: Double
    public init(radius: Double = 8) { self.radius = radius }
}

public struct CropPadFilter: Codable, Equatable, Hashable {
    public var crop: Crop
    public init(crop: Crop = .none) { self.crop = crop }
}

public struct LumaKeyFilter: Codable, Equatable, Hashable {
    public var lumaMin: Double
    public var lumaMax: Double
    public var smooth: Double
    public init(lumaMin: Double = 0, lumaMax: Double = 1, smooth: Double = 0.05) {
        self.lumaMin = lumaMin
        self.lumaMax = lumaMax
        self.smooth = smooth
    }
}

public enum FilterType: Codable, Equatable, Hashable {
    case colorCorrection(ColorCorrectionFilter)
    case chromaKey(ChromaKeyFilter)
    case lumaKey(LumaKeyFilter)
    case sharpen(SharpenFilter)
    case blur(BlurFilter)
    case cropPad(CropPadFilter)

    public var displayName: String {
        switch self {
        case .colorCorrection: return "Color Correction"
        case .chromaKey: return "Chroma Key"
        case .lumaKey: return "Luma Key"
        case .sharpen: return "Sharpen"
        case .blur: return "Blur"
        case .cropPad: return "Crop/Pad"
        }
    }

    public static let allDefaults: [FilterType] = [
        .colorCorrection(ColorCorrectionFilter()),
        .chromaKey(ChromaKeyFilter()),
        .lumaKey(LumaKeyFilter()),
        .sharpen(SharpenFilter()),
        .blur(BlurFilter()),
        .cropPad(CropPadFilter()),
    ]
}

public struct FilterDescriptor: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var type: FilterType

    public init(id: UUID = UUID(), name: String? = nil, enabled: Bool = true, type: FilterType) {
        self.id = id
        self.name = name ?? type.displayName
        self.enabled = enabled
        self.type = type
    }
}
