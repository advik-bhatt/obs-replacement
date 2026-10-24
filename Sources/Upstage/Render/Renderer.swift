import Foundation
import Metal
import MetalKit
import simd
import UpstageCore

struct QuadUniforms {
    var mvp: simd_float4x4
    var uvRect: SIMD4<Float>
    var opacity: Float
    var flipH: Float
    var flipV: Float
    var quarterTurns: Float
}

struct FilterUniforms {
    var p0: SIMD4<Float> = .zero
    var p1: SIMD4<Float> = .zero
    var p2: SIMD4<Float> = .zero
    var texelSize: SIMD2<Float> = .zero
    var pad: SIMD2<Float> = .zero
}

/// One item to draw this frame. Built by the engine from the scene graph and the
/// sources' latest textures; the renderer never touches model types directly.
struct RenderItem {
    var sourceID: UUID
    var texture: MTLTexture?
    /// Solid colour instead of a texture (color sources).
    var solidColor: RGBA?
    /// Size of the item as displayed before scaling, i.e. after the source's own rotation.
    var displayedSize: Size2D
    var quarterTurns: Int
    var mirror: Bool
    var transform: Transform
    var filters: [FilterType]
    var upscale: UpscaleMode
}

struct RenderScene {
    var items: [RenderItem]
    var canvasSize: Size2D
}

enum RendererError: Error {
    case noDevice
    case shaderCompile(String)
    case pipeline(String)
}

/// Metal compositor: draws scene items onto a canvas texture with transforms,
/// filters and per-item upscaling, blends transitions, and scales the canvas to
/// the output size.
final class Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    private let texturedPipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let colorCorrectionPipeline: MTLRenderPipelineState
    private let chromaKeyPipeline: MTLRenderPipelineState
    private let lumaKeyPipeline: MTLRenderPipelineState
    private let sharpenPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let lanczosPipeline: MTLRenderPipelineState
    private let transitionPipeline: MTLRenderPipelineState

    let linearSampler: MTLSamplerState
    let upscalers = UpscalerCache()

    /// Scratch textures keyed by (purpose, size).
    private var scratch: [String: MTLTexture] = [:]

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        commandQueue = queue
        let options = MTLCompileOptions()
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: ShaderSource.metal, options: options)
        } catch {
            throw RendererError.shaderCompile("\(error)")
        }
        library = lib

        // Local helper on purpose: it must not touch `self` before every stored
        // property has a value.
        func pipeline(_ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = lib.makeFunction(name: "quad_vertex")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            let att = d.colorAttachments[0]!
            att.pixelFormat = Renderer.pixelFormat
            if blend {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                throw RendererError.pipeline("\(fragment): \(error)")
            }
        }

        texturedPipeline = try pipeline("textured_fragment", blend: true)
        solidPipeline = try pipeline("solid_fragment", blend: true)
        colorCorrectionPipeline = try pipeline("color_correction_fragment", blend: false)
        chromaKeyPipeline = try pipeline("chroma_key_fragment", blend: false)
        lumaKeyPipeline = try pipeline("luma_key_fragment", blend: false)
        sharpenPipeline = try pipeline("sharpen_fragment", blend: false)
        blurPipeline = try pipeline("blur_fragment", blend: false)
        lanczosPipeline = try pipeline("lanczos_fragment", blend: false)
        transitionPipeline = try pipeline("transition_fragment", blend: false)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw RendererError.noDevice }
        linearSampler = sampler
    }

    // MARK: textures

    func makeTexture(size: Size2D, label: String, usage: MTLTextureUsage = [.shaderRead, .renderTarget]) -> MTLTexture? {
        guard !size.isEmpty else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.pixelFormat, width: size.width, height: size.height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)
        t?.label = label
        return t
    }

    func scratchTexture(_ key: String, size: Size2D) -> MTLTexture? {
        if let t = scratch[key], t.width == size.width, t.height == size.height { return t }
        guard let t = makeTexture(size: size, label: "scratch.\(key)") else { return nil }
        scratch[key] = t
        return t
    }

    static func size(of t: MTLTexture) -> Size2D { Size2D(t.width, t.height) }

    // MARK: matrices

    static func ortho(canvas: Size2D) -> simd_float4x4 {
        // canvas pixel (x right, y down) -> NDC (x right, y up)
        let w = Float(max(canvas.width, 1)), h = Float(max(canvas.height, 1))
        return simd_float4x4(columns: (
            SIMD4<Float>(2 / w, 0, 0, 0),
            SIMD4<Float>(0, -2 / h, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        ))
    }

    static func translation(_ x: Float, _ y: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, 0, 1)
        return m
    }

    static func scaling(_ x: Float, _ y: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = x
        m.columns.1.y = y
        return m
    }

    static func rotationZ(degreesClockwise: Float) -> simd_float4x4 {
        // y is down in canvas space, so a positive angle here is clockwise on screen.
        let r = degreesClockwise * .pi / 180
        let c = cos(r), s = sin(r)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(c, s, 0, 0)
        m.columns.1 = SIMD4<Float>(-s, c, 0, 0)
        return m
    }

    /// Model matrix for a unit quad to land centred at `position` with the given size and rotation.
    static func model(position: Vec2, size: Vec2, rotationDegrees: Double) -> simd_float4x4 {
        translation(Float(position.x), Float(position.y))
            * rotationZ(degreesClockwise: Float(rotationDegrees))
            * scaling(Float(size.x), Float(size.y))
            * translation(-0.5, -0.5)
    }

    // MARK: drawing

    private func encodeQuad(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, texture: MTLTexture?, uniforms: inout QuadUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        if let texture { enc.setFragmentTexture(texture, index: 0) }
        enc.setFragmentSamplerState(linearSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func fullscreenUniforms() -> QuadUniforms {
        QuadUniforms(mvp: Renderer.ortho(canvas: Size2D(1, 1)), uvRect: SIMD4<Float>(0, 0, 1, 1), opacity: 1, flipH: 0, flipV: 0, quarterTurns: 0)
    }

    /// Runs one fullscreen filter pass from `input` into `output`.
    func fullscreenPass(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, input: MTLTexture, input2: MTLTexture? = nil, output: MTLTexture, uniforms: FilterUniforms) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = output
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = pipeline.label
        var q = fullscreenUniforms()
        var f = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&q, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentBytes(&f, length: MemoryLayout<FilterUniforms>.stride, index: 0)
        enc.setFragmentTexture(input, index: 0)
        if let input2 { enc.setFragmentTexture(input2, index: 1) }
        enc.setFragmentSamplerState(linearSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    func clear(_ cb: MTLCommandBuffer, texture: MTLTexture, color: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = color
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    /// Copies `src` into a renderer-owned texture of the same size (used when a
    /// CoreVideo texture lacks the usage flags a later stage needs).
    func copy(_ cb: MTLCommandBuffer, from src: MTLTexture, key: String) -> MTLTexture? {
        guard let dst = scratchTexture(key, size: Renderer.size(of: src)) else { return nil }
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: src, to: dst)
        blit.endEncoding()
        return dst
    }

    // MARK: filters

    private func applyFilters(_ cb: MTLCommandBuffer, item: RenderItem, input: MTLTexture) -> MTLTexture {
        var current = input
        var pass = 0
        let size = Renderer.size(of: input)
        let texel = SIMD2<Float>(1 / Float(size.width), 1 / Float(size.height))
        for filter in item.filters {
            pass += 1
            let key = "filter.\(item.sourceID.uuidString).\(pass)"
            guard let out = scratchTexture(key, size: size) else { continue }
            var u = FilterUniforms()
            u.texelSize = texel
            switch filter {
            case .colorCorrection(let c):
                u.p0 = SIMD4<Float>(Float(c.brightness), Float(c.contrast), Float(c.saturation), Float(c.gamma))
                u.p1 = SIMD4<Float>(Float(c.hueShift / 360), Float(c.opacity), 0, 0)
                fullscreenPass(cb, pipeline: colorCorrectionPipeline, input: current, output: out, uniforms: u)
            case .chromaKey(let k):
                u.p0 = SIMD4<Float>(Float(k.keyColor.r), Float(k.keyColor.g), Float(k.keyColor.b), 1)
                u.p1 = SIMD4<Float>(Float(k.similarity), Float(k.smoothness), Float(k.spillReduction), 0)
                fullscreenPass(cb, pipeline: chromaKeyPipeline, input: current, output: out, uniforms: u)
            case .lumaKey(let k):
                u.p0 = SIMD4<Float>(Float(k.lumaMin), Float(k.lumaMax), Float(k.smooth), 0)
                fullscreenPass(cb, pipeline: lumaKeyPipeline, input: current, output: out, uniforms: u)
            case .sharpen(let s):
                u.p0 = SIMD4<Float>(Float(s.amount), 0, 0, 0)
                fullscreenPass(cb, pipeline: sharpenPipeline, input: current, output: out, uniforms: u)
            case .blur(let b):
                guard let mid = scratchTexture(key + ".h", size: size) else { continue }
                u.p0 = SIMD4<Float>(Float(b.radius), 0, 0, 0)
                fullscreenPass(cb, pipeline: blurPipeline, input: current, output: mid, uniforms: u)
                u.p0 = SIMD4<Float>(Float(b.radius), 1, 0, 0)
                fullscreenPass(cb, pipeline: blurPipeline, input: mid, output: out, uniforms: u)
            case .cropPad:
                // Crop/pad is applied through the item's uvRect (see draw), no pass needed.
                continue
            }
            current = out
        }
        return current
    }

    // MARK: scene

    /// Draws `scene` into `target` (which must be `scene.canvasSize`).
    func render(_ cb: MTLCommandBuffer, scene: RenderScene, into target: MTLTexture, background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        // Stage 1: per-item pre-passes (filters, upscale) need their own encoders.
        var prepared: [(RenderItem, MTLTexture?)] = []
        prepared.reserveCapacity(scene.items.count)
        for item in scene.items {
            guard item.transform.opacity > 0 else { continue }
            if item.solidColor != nil {
                prepared.append((item, nil))
                continue
            }
            guard let tex = item.texture else { continue }
            var current = tex
            if !item.filters.isEmpty {
                current = applyFilters(cb, item: item, input: current)
            }
            // Upscale when the item is drawn bigger than its pixels.
            let drawn = item.transform.renderedSize(for: item.displayedSize)
            let cropped = item.transform.crop.apply(to: item.displayedSize)
            let sx = cropped.width > 0 ? drawn.x / Double(cropped.width) : 1
            let sy = cropped.height > 0 ? drawn.y / Double(cropped.height) : 1
            if (sx > 1.01 || sy > 1.01) && item.upscale != .off {
                let odd = item.quarterTurns % 2 != 0
                let texScaleX = odd ? sy : sx
                let texScaleY = odd ? sx : sy
                let targetSize = Size2D(
                    max(1, Int((Double(current.width) * max(1, texScaleX)).rounded())),
                    max(1, Int((Double(current.height) * max(1, texScaleY)).rounded()))
                )
                if targetSize.width > current.width || targetSize.height > current.height {
                    if let up = upscale(cb, input: current, to: targetSize, mode: item.upscale, key: "item.\(item.sourceID.uuidString)") {
                        current = up
                    }
                }
            }
            prepared.append((item, current))
        }

        // Stage 2: composite.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = background
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "composite"
        let proj = Renderer.ortho(canvas: scene.canvasSize)
        for (item, tex) in prepared {
            let t = item.transform
            let drawn = t.renderedSize(for: item.displayedSize)
            guard drawn.x > 0, drawn.y > 0 else { continue }
            let model = Renderer.model(position: t.position, size: drawn, rotationDegrees: t.rotation)
            // Crop in displayed space -> uv rect
            let ds = item.displayedSize
            var uv = SIMD4<Float>(0, 0, 1, 1)
            if !t.crop.isEmpty, ds.width > 0, ds.height > 0 {
                uv = SIMD4<Float>(Float(t.crop.left) / Float(ds.width), Float(t.crop.top) / Float(ds.height),
                                  1 - Float(t.crop.right) / Float(ds.width), 1 - Float(t.crop.bottom) / Float(ds.height))
            }
            // Crop/pad filter adds to the crop in texture (pre-rotation) space; approximate by
            // applying it in displayed space when there is no rotation, which is the common case.
            for f in item.filters {
                if case .cropPad(let cp) = f, item.quarterTurns == 0, ds.width > 0, ds.height > 0 {
                    uv.x += Float(cp.crop.left) / Float(ds.width)
                    uv.y += Float(cp.crop.top) / Float(ds.height)
                    uv.z -= Float(cp.crop.right) / Float(ds.width)
                    uv.w -= Float(cp.crop.bottom) / Float(ds.height)
                }
            }
            var u = QuadUniforms(mvp: proj * model, uvRect: uv, opacity: Float(t.opacity),
                                 flipH: (t.flipHorizontal != item.mirror) ? 1 : 0, flipV: t.flipVertical ? 1 : 0,
                                 quarterTurns: Float(item.quarterTurns % 4))
            if let color = item.solidColor {
                var f = FilterUniforms()
                f.p0 = SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a * t.opacity))
                enc.setRenderPipelineState(solidPipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                enc.setFragmentBytes(&f, length: MemoryLayout<FilterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            } else if let tex {
                encodeQuad(enc, pipeline: texturedPipeline, texture: tex, uniforms: &u)
            }
        }
        enc.endEncoding()
    }

    /// Draws `texture` aspect-fitted and centred into a drawable of `viewSize` pixels (the preview).
    func drawFitted(_ cb: MTLCommandBuffer, texture: MTLTexture?, into drawable: MTLTexture, background: MTLClearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = background
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "preview"
        if let texture {
            let view = Size2D(drawable.width, drawable.height)
            let rect = Renderer.fitRect(content: Size2D(texture.width, texture.height), in: view)
            let model = Renderer.model(position: rect.center, size: rect.size, rotationDegrees: 0)
            var u = QuadUniforms(mvp: Renderer.ortho(canvas: view) * model, uvRect: SIMD4<Float>(0, 0, 1, 1), opacity: 1, flipH: 0, flipV: 0, quarterTurns: 0)
            encodeQuad(enc, pipeline: texturedPipeline, texture: texture, uniforms: &u)
        }
        enc.endEncoding()
    }

    /// Largest centred rectangle with `content`'s aspect inside `container`.
    static func fitRect(content: Size2D, in container: Size2D) -> Rect2D {
        guard !content.isEmpty, !container.isEmpty else { return Rect2D(x: 0, y: 0, width: 0, height: 0) }
        let s = min(Double(container.width) / Double(content.width), Double(container.height) / Double(content.height))
        let w = Double(content.width) * s, h = Double(content.height) * s
        return Rect2D(x: (Double(container.width) - w) / 2, y: (Double(container.height) - h) / 2, width: w, height: h)
    }

    /// Blends two rendered scenes with the given transition.
    func transition(_ cb: MTLCommandBuffer, from a: MTLTexture, to b: MTLTexture, kind: TransitionKind, progress: Double, into target: MTLTexture) {
        var u = FilterUniforms()
        let kindIndex: Float
        switch kind {
        case .cut, .fade: kindIndex = 0
        case .fadeToBlack: kindIndex = 1
        case .slideLeft: kindIndex = 2
        case .slideRight: kindIndex = 3
        case .slideUp: kindIndex = 4
        case .slideDown: kindIndex = 5
        }
        u.p0 = SIMD4<Float>(Float(progress), kindIndex, 0, 0)
        fullscreenPass(cb, pipeline: transitionPipeline, input: a, input2: b, output: target, uniforms: u)
    }

    // MARK: upscaling

    /// Scales `input` to `size` with MetalFX when available (and asked for), Lanczos otherwise.
    func upscale(_ cb: MTLCommandBuffer, input: MTLTexture, to size: Size2D, mode: UpscaleMode, key: String) -> MTLTexture? {
        let wantMetalFX = mode == .auto || mode == .metalFX
        if wantMetalFX, let out = upscalers.metalFX(cb, device: device, renderer: self, input: input, to: size, key: key) {
            return out
        }
        if mode == .metalFX || mode == .auto || mode == .lanczos {
            return lanczos(cb, input: input, to: size, key: key)
        }
        return nil
    }

    func upscale(_ cb: MTLCommandBuffer, input: MTLTexture, to size: Size2D, kind: UpscalerKind, key: String) -> MTLTexture? {
        switch kind {
        case .metalFX: return upscale(cb, input: input, to: size, mode: .auto, key: key)
        case .lanczos: return lanczos(cb, input: input, to: size, key: key)
        case .bilinear:
            guard let out = scratchTexture(key + ".bilinear", size: size) else { return nil }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = out
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
            var u = fullscreenUniforms()
            encodeQuad(enc, pipeline: texturedPipeline, texture: input, uniforms: &u)
            enc.endEncoding()
            return out
        }
    }

    func lanczos(_ cb: MTLCommandBuffer, input: MTLTexture, to size: Size2D, key: String) -> MTLTexture? {
        guard let out = scratchTexture(key + ".lanczos", size: size) else { return nil }
        var u = FilterUniforms()
        u.texelSize = SIMD2<Float>(1 / Float(input.width), 1 / Float(input.height))
        fullscreenPass(cb, pipeline: lanczosPipeline, input: input, output: out, uniforms: u)
        return out
    }
}
