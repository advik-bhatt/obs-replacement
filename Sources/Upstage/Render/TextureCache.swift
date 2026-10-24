import CoreVideo
import Foundation
import Metal
import UpstageCore

/// Wraps CVMetalTextureCache so camera / screen / media pixel buffers become
/// Metal textures without a copy, and provides a pool of IOSurface-backed pixel
/// buffers the renderer can blit output frames into for the encoders.
final class TextureCache {
    let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()

    init(device: MTLDevice) {
        self.device = device
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c)
        cache = c
    }

    /// A Metal texture view of a BGRA pixel buffer. The returned CVMetalTexture must be
    /// kept alive as long as the MTLTexture is in use.
    func texture(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        lock.lock(); defer { lock.unlock() }
        guard let cache else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else { return nil }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }
}

/// Pool of BGRA, IOSurface-backed, Metal-compatible pixel buffers at a fixed size.
final class PixelBufferPool {
    let size: Size2D
    private var pool: CVPixelBufferPool?

    init?(size: Size2D, minimumBuffers: Int = 6) {
        self.size = size
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBuffers]
        var p: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
        guard status == kCVReturnSuccess, let p else { return nil }
        pool = p
    }

    func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 12]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux as CFDictionary, &pb)
        guard status == kCVReturnSuccess else { return nil }
        return pb
    }
}
