import Foundation

/// Integer pixel size. Used for canvas, output and source dimensions.
public struct Size2D: Codable, Equatable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = Size2D(0, 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }
    public var isPortrait: Bool { height > width }
    public var pixelCount: Int { width * height }
    public var description: String { "\(width)x\(height)" }

    /// Same pixels with width and height exchanged (what a 90 degree rotation does).
    public var transposed: Size2D { Size2D(height, width) }

    public func scaled(by factor: Double) -> Size2D {
        Size2D(Int((Double(width) * factor).rounded()), Int((Double(height) * factor).rounded()))
    }
}

public struct Vec2: Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)
    public static let one = Vec2(1, 1)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
}

public struct Rect2D: Codable, Equatable, Hashable {
    public var origin: Vec2
    public var size: Vec2

    public init(origin: Vec2, size: Vec2) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Vec2(x, y)
        size = Vec2(width, height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.x }
    public var maxY: Double { origin.y + size.y }
    public var center: Vec2 { Vec2(origin.x + size.x / 2, origin.y + size.y / 2) }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

/// Source-space crop in pixels, applied before scaling and rotation.
public struct Crop: Codable, Equatable, Hashable {
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let none = Crop()
    public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }

    /// Size that remains after cropping `source`, never smaller than 1x1.
    public func apply(to source: Size2D) -> Size2D {
        Size2D(max(1, source.width - left - right), max(1, source.height - top - bottom))
    }
}

/// Rotation in 90 degree steps, used for sources whose sensor orientation does
/// not match how the device is mounted (an iPhone used as a Continuity Camera
/// in portrait, for example).
public enum Rotation: Int, Codable, CaseIterable, Hashable {
    case r0 = 0
    case r90 = 90
    case r180 = 180
    case r270 = 270

    public var degrees: Double { Double(rawValue) }
    public var swapsAxes: Bool { self == .r90 || self == .r270 }

    public func apply(to size: Size2D) -> Size2D { swapsAxes ? size.transposed : size }

    public var next: Rotation {
        switch self {
        case .r0: return .r90
        case .r90: return .r180
        case .r180: return .r270
        case .r270: return .r0
        }
    }

    public var label: String {
        switch self {
        case .r0: return "0°"
        case .r90: return "90° (portrait)"
        case .r180: return "180°"
        case .r270: return "270° (portrait, flipped)"
        }
    }
}

/// How a scene item sits on the canvas. Position is the item's centre in canvas
/// pixels, which keeps rotation and scaling about the centre trivial.
public struct Transform: Codable, Equatable, Hashable {
    public var position: Vec2
    public var scale: Vec2
    /// Degrees, clockwise.
    public var rotation: Double
    public var crop: Crop
    public var opacity: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(position: Vec2 = .zero,
                scale: Vec2 = .one,
                rotation: Double = 0,
                crop: Crop = .none,
                opacity: Double = 1,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.crop = crop
        self.opacity = opacity
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public static let identity = Transform()

    /// Size on the canvas before rotation, in canvas pixels.
    public func renderedSize(for source: Size2D) -> Vec2 {
        let cropped = crop.apply(to: source)
        return Vec2(Double(cropped.width) * scale.x, Double(cropped.height) * scale.y)
    }

    /// Axis-aligned bounding box on the canvas, including rotation.
    public func boundingBox(for source: Size2D) -> Rect2D {
        let s = renderedSize(for: source)
        let r = rotation * .pi / 180
        let c = abs(cos(r)), sn = abs(sin(r))
        let w = s.x * c + s.y * sn
        let h = s.x * sn + s.y * c
        return Rect2D(x: position.x - w / 2, y: position.y - h / 2, width: w, height: h)
    }

    public enum FitMode: String, Codable, CaseIterable {
        /// Largest size that fits inside the canvas, aspect preserved, centred.
        case fit
        /// Smallest size that covers the canvas, aspect preserved, centred (edges cropped visually).
        case fill
        /// Stretch to the canvas, aspect not preserved.
        case stretch
        /// Native size, centred.
        case center
    }

    /// Builds a transform that places `source` on `canvas` according to `mode`.
    /// `rotation` is honoured: a 90 degree item fits by its rotated footprint.
    public static func fitting(source: Size2D,
                               in canvas: Size2D,
                               mode: FitMode,
                               rotation: Double = 0,
                               crop: Crop = .none) -> Transform {
        var t = Transform()
        t.rotation = rotation
        t.crop = crop
        t.position = Vec2(Double(canvas.width) / 2, Double(canvas.height) / 2)
        let cropped = crop.apply(to: source)
        guard !cropped.isEmpty, !canvas.isEmpty else { return t }
        let quarterTurns = Int((rotation / 90).rounded()) % 2 != 0
        let footprint = quarterTurns ? cropped.transposed : cropped
        let sx = Double(canvas.width) / Double(footprint.width)
        let sy = Double(canvas.height) / Double(footprint.height)
        switch mode {
        case .fit:
            let s = min(sx, sy)
            t.scale = Vec2(s, s)
        case .fill:
            let s = max(sx, sy)
            t.scale = Vec2(s, s)
        case .stretch:
            t.scale = quarterTurns ? Vec2(sy, sx) : Vec2(sx, sy)
        case .center:
            t.scale = .one
        }
        return t
    }
}

/// RGBA colour with components in 0...1.
public struct RGBA: Codable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    public static let chromaGreen = RGBA(r: 0, g: 1, b: 0)

    /// Parses `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        }
    }

    public var hexString: String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }
}
