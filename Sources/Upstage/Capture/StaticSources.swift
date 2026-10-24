import AppKit
import CoreText
import Foundation
import ImageIO
import Metal
import UpstageCore

/// Rasterises CoreGraphics content into a premultiplied BGRA Metal texture.
enum Rasterizer {
    static func texture(device: MTLDevice, size: Size2D, label: String, draw: (CGContext) -> Void) -> MTLTexture? {
        guard size.width > 0, size.height > 0 else { return nil }
        let w = min(size.width, 8192), h = min(size.height, 8192)
        let bytesPerRow = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // Flip so y goes down like the rest of the pipeline expects at upload time.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.label = label
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    static func cgImage(fromFile path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

final class ImageSource: VideoSourceInstance {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: ImageSettings
    private let device: MTLDevice
    private let slot = FrameSlot()
    private(set) var isActive = false
    @Synchronized private(set) var status = "Not started"
    private var size: Size2D?

    init(descriptor: SourceDescriptor, settings: ImageSettings, device: MTLDevice) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        self.device = device
    }

    var displayedSize: Size2D? { size }
    func latestFrame() -> VideoFrame? { slot.get() }

    func start() {
        isActive = true
        load()
    }

    func stop() {
        isActive = false
        slot.clear()
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        guard case .image(let s) = descriptor.settings else { return }
        let changed = s.path != settings.path
        settings = s
        if changed { load() }
    }

    private func load() {
        guard let path = settings.path, !path.isEmpty else {
            status = "No image selected"
            slot.clear()
            return
        }
        guard let img = Rasterizer.cgImage(fromFile: path) else {
            status = "Cannot load \(path)"
            slot.clear()
            return
        }
        // Metal textures cap at 8192 px a side; scale big images down proportionally.
        let scale = min(1.0, 8192.0 / Double(max(img.width, img.height, 1)))
        let sz = Size2D(max(1, Int(Double(img.width) * scale)), max(1, Int(Double(img.height) * scale)))
        guard let tex = Rasterizer.texture(device: device, size: sz, label: "image.\(id)", draw: { ctx in
            // CG draws with y up; we flipped the context, so flip the image back.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(sz.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: sz.width, height: sz.height))
            ctx.restoreGState()
        }) else {
            status = "Cannot upload \(path)"
            return
        }
        size = sz
        slot.set(VideoFrame(texture: tex, holder: nil, size: sz, timestamp: hostTimeSeconds()))
        status = "\(sz.width)x\(sz.height)"
    }
}

final class TextSource: VideoSourceInstance {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: TextSettings
    private let device: MTLDevice
    private let slot = FrameSlot()
    private(set) var isActive = false
    @Synchronized private(set) var status = "Not started"
    private var size: Size2D?

    init(descriptor: SourceDescriptor, settings: TextSettings, device: MTLDevice) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        self.device = device
    }

    var displayedSize: Size2D? { size }
    func latestFrame() -> VideoFrame? { slot.get() }

    func start() {
        isActive = true
        render()
    }

    func stop() {
        isActive = false
        slot.clear()
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        guard case .text(let s) = descriptor.settings else { return }
        if s != settings {
            settings = s
            render()
        }
    }

    private func render() {
        let s = settings
        let font = NSFont(name: s.fontName, size: CGFloat(s.fontSize)) ?? NSFont.boldSystemFont(ofSize: CGFloat(s.fontSize))
        let paragraph = NSMutableParagraphStyle()
        switch s.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: s.color.r, green: s.color.g, blue: s.color.b, alpha: s.color.a),
            .paragraphStyle: paragraph,
        ]
        if s.outlineWidth > 0 {
            attrs[.strokeColor] = NSColor(red: s.outlineColor.r, green: s.outlineColor.g, blue: s.outlineColor.b, alpha: s.outlineColor.a)
            attrs[.strokeWidth] = -s.outlineWidth
        }
        let text = s.text.isEmpty ? " " : s.text
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let pad = CGFloat(s.fontSize * 0.25)
        let maxWidth = s.wrapWidth > 0 ? CGFloat(s.wrapWidth) : 8192
        let bounds = attributed.boundingRect(with: CGSize(width: maxWidth, height: 8192), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = s.wrapWidth > 0 ? CGFloat(s.wrapWidth) : ceil(bounds.width) + pad * 2
        let height = ceil(bounds.height) + pad * 2
        let sz = Size2D(max(2, Int(width)), max(2, Int(height)))
        guard let tex = Rasterizer.texture(device: device, size: sz, label: "text.\(id)", draw: { ctx in
            if s.backgroundColor.a > 0 {
                ctx.setFillColor(CGColor(srgbRed: s.backgroundColor.r, green: s.backgroundColor.g, blue: s.backgroundColor.b, alpha: s.backgroundColor.a))
                ctx.fill(CGRect(x: 0, y: 0, width: sz.width, height: sz.height))
            }
            // Draw with AppKit's string drawing (needs a flipped graphics context for top-down y).
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            let rect = CGRect(x: pad, y: pad, width: width - pad * 2, height: height - pad * 2)
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }) else {
            status = "Cannot render text"
            return
        }
        size = sz
        slot.set(VideoFrame(texture: tex, holder: nil, size: sz, timestamp: hostTimeSeconds()))
        status = "\(sz.width)x\(sz.height)"
    }
}

final class ColorSource: VideoSourceInstance {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: ColorSettings
    private(set) var isActive = false
    var status: String { "Solid \(settings.color.hexString)" }

    init(descriptor: SourceDescriptor, settings: ColorSettings) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
    }

    var displayedSize: Size2D? { settings.size }
    var solidColor: RGBA? { settings.color }
    func latestFrame() -> VideoFrame? { nil }
    func start() { isActive = true }
    func stop() { isActive = false }
    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        if case .color(let s) = descriptor.settings { settings = s }
    }
}
