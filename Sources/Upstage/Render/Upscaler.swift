import Foundation
import Metal
import MetalFX
import UpstageCore

/// Caches one MetalFX spatial scaler per key (source or canvas), recreating it
/// only when input/output sizes change. MetalFX spatial upscaling is the same
/// hardware path games use for 1080p -> 4K at frame rate; the fallback is the
/// renderer's Lanczos pass.
final class UpscalerCache {
    private final class Entry {
        let scaler: MTLFXSpatialScaler
        let input: Size2D
        let output: Size2D
        let outputTexture: MTLTexture
        var inputUsageOK = true

        init(scaler: MTLFXSpatialScaler, input: Size2D, output: Size2D, outputTexture: MTLTexture) {
            self.scaler = scaler
            self.input = input
            self.output = output
            self.outputTexture = outputTexture
        }
    }

    private var entries: [String: Entry] = [:]
    private var unsupportedLogged = false
    private(set) var metalFXAvailable: Bool? = nil
    private var failedKeys: Set<String> = []

    static func isSupported(_ device: MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    func reset() {
        entries.removeAll()
        failedKeys.removeAll()
    }

    /// Encodes a MetalFX upscale of `input` into a cached output texture. Returns nil if MetalFX
    /// is unavailable on this GPU or a scaler could not be created for these sizes.
    func metalFX(_ cb: MTLCommandBuffer, device: MTLDevice, renderer: Renderer, input: MTLTexture, to size: Size2D, key: String) -> MTLTexture? {
        if metalFXAvailable == nil { metalFXAvailable = UpscalerCache.isSupported(device) }
        guard metalFXAvailable == true else { return nil }
        let inSize = Size2D(input.width, input.height)
        guard size.width >= inSize.width, size.height >= inSize.height else { return nil }
        if failedKeys.contains(key + "\(inSize)\(size)") { return nil }

        var entry = entries[key]
        if let e = entry, e.input != inSize || e.output != size { entry = nil }
        if entry == nil {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = inSize.width
            d.inputHeight = inSize.height
            d.outputWidth = size.width
            d.outputHeight = size.height
            d.colorTextureFormat = input.pixelFormat
            d.outputTextureFormat = Renderer.pixelFormat
            d.colorProcessingMode = .perceptual
            guard let scaler = d.makeSpatialScaler(device: device) else {
                failedKeys.insert(key + "\(inSize)\(size)")
                NSLog("MetalFX: could not create spatial scaler \(inSize) -> \(size); using Lanczos")
                return nil
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.pixelFormat, width: size.width, height: size.height, mipmapped: false)
            td.usage = scaler.outputTextureUsage.union([.shaderRead, .renderTarget])
            td.storageMode = .private
            guard let out = device.makeTexture(descriptor: td) else { return nil }
            out.label = "metalfx.\(key)"
            let e = Entry(scaler: scaler, input: inSize, output: size, outputTexture: out)
            entries[key] = e
            entry = e
        }
        guard let e = entry else { return nil }

        // CoreVideo-backed textures sometimes lack the usage MetalFX wants; copy once if so.
        var source = input
        let needed = e.scaler.colorTextureUsage
        if !input.usage.contains(needed) {
            guard let copied = renderer.copy(cb, from: input, key: "metalfx.copy.\(key)") else { return nil }
            source = copied
        }
        e.scaler.colorTexture = source
        e.scaler.outputTexture = e.outputTexture
        e.scaler.encode(commandBuffer: cb)
        return e.outputTexture
    }
}
