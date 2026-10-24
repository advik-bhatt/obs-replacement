import CoreVideo
import Foundation
import Metal
import UpstageCore

struct EngineStats {
    var fps: Double = 0
    var targetFPS: Double = 0
    var renderMilliseconds: Double = 0
    var gpuMilliseconds: Double = 0
    var totalFrames: Int = 0
    var droppedFrames: Int = 0
    var metalFX: Bool = false
    var gpuName: String = ""
    var activeSources: Int = 0
}

/// The live pipeline: owns source instances, the render loop, the audio mixer
/// and the outputs. The UI talks to it through AppState; it never touches
/// SwiftUI. Everything that reads the scene graph for drawing goes through a
/// snapshot taken under `lock`, so the UI can mutate freely.
final class Engine {
    let device: MTLDevice
    let renderer: Renderer
    let textureCache: TextureCache
    let mixer = AudioMixer()

    private let renderQueue = DispatchQueue(label: "upstage.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let inFlight = DispatchSemaphore(value: 2)
    private let lock = NSLock()

    private(set) var videoSettings = VideoSettings()
    private var collection: SceneCollection = .empty()
    private var sources: [UUID: SourceInstance] = [:]
    private var descriptors: [UUID: SourceDescriptor] = [:]
    private var programSceneID = UUID()
    private var previewSceneID: UUID?
    private(set) var studioMode = false

    private var programTextures: [MTLTexture] = []
    private var programIndex = 0
    private var previewTextures: [MTLTexture] = []
    private var previewIndex = 0
    private var transitionTextures: [MTLTexture] = []
    private var pixelPool: PixelBufferPool?

    private var latestProgram: MTLTexture?
    private var latestPreview: MTLTexture?

    private struct ActiveTransition {
        var from: UUID
        var to: UUID
        var kind: TransitionKind
        var start: Double
        var duration: Double
    }
    private var transition: ActiveTransition?

    private(set) var recorder: Recorder?
    private(set) var stream: StreamOutput?
    private(set) var replay: ReplayBuffer?

    private(set) var startTime: Double = 0
    private(set) var isRunning = false
    private var stats = EngineStats()
    private var fpsWindow: (start: Double, frames: Int) = (0, 0)
    private var expectedFrames: Double = 0
    private var knownSizes: [UUID: Size2D] = [:]

    /// Fired on the main queue when a source reports its pixel size for the first time or changes it.
    var onSourceSizeChanged: ((UUID, Size2D) -> Void)?
    /// Fired on the main queue when a transition completes and the program scene changed.
    var onProgramSceneChanged: ((UUID) -> Void)?

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        device = dev
        renderer = try Renderer(device: dev)
        textureCache = TextureCache(device: dev)
        programSceneID = collection.currentSceneID
        stats.gpuName = dev.name
        stats.metalFX = UpscalerCache.isSupported(dev)
        rebuildTextures()
    }

    var metalFXSupported: Bool { stats.metalFX }

    // MARK: lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startTime = hostTimeSeconds()
        mixer.start(startTime: startTime)
        expectedFrames = 0
        fpsWindow = (startTime, 0)
        startTimer()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        mixer.stop()
        lock.lock()
        let all = Array(sources.values)
        sources.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }

    func pts() -> Double { hostTimeSeconds() - startTime }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        let interval = 1.0 / max(1, videoSettings.frameRate)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: configuration

    func apply(video: VideoSettings) {
        lock.lock()
        let changed = video != videoSettings
        videoSettings = video
        lock.unlock()
        guard changed else { return }
        renderQueue.sync {
            rebuildTextures()
            renderer.upscalers.reset()
        }
        if isRunning { startTimer() }
    }

    private func rebuildTextures() {
        let base = videoSettings.baseSize
        programTextures = (0..<3).compactMap { renderer.makeTexture(size: base, label: "program\($0)") }
        previewTextures = (0..<2).compactMap { renderer.makeTexture(size: base, label: "preview\($0)") }
        transitionTextures = (0..<2).compactMap { renderer.makeTexture(size: base, label: "transition\($0)") }
        pixelPool = PixelBufferPool(size: videoSettings.outputSize)
        lock.lock()
        latestProgram = nil
        latestPreview = nil
        lock.unlock()
    }

    /// Syncs runtime sources with the collection and stores the drawing snapshot.
    func apply(collection c: SceneCollection) {
        var toStart: [SourceInstance] = []
        var toStop: [SourceInstance] = []
        lock.lock()
        collection = c
        let wanted = Dictionary(uniqueKeysWithValues: c.sources.map { ($0.id, $0) })
        var removed: [UUID] = []
        for (id, inst) in sources where wanted[id] == nil {
            toStop.append(inst)
            sources.removeValue(forKey: id)
            descriptors.removeValue(forKey: id)
            mixer.removeSource(id)
            knownSizes.removeValue(forKey: id)
            removed.append(id)
        }
        for d in c.sources {
            if let existing = sources[d.id] {
                if descriptors[d.id] != d {
                    if descriptors[d.id]?.settings.kind != d.settings.kind {
                        toStop.append(existing)
                        sources.removeValue(forKey: d.id)
                        mixer.removeSource(d.id)
                        if let inst = makeInstance(d) {
                            sources[d.id] = inst
                            toStart.append(inst)
                            if let a = inst as? AudioSourceInstance { mixer.addSource(d.id, output: a.audioOutput, audio: d.audio) }
                        }
                    } else {
                        existing.update(descriptor: d)
                        mixer.updateSource(d.id, audio: d.audio)
                    }
                    descriptors[d.id] = d
                }
            } else if let inst = makeInstance(d) {
                sources[d.id] = inst
                descriptors[d.id] = d
                toStart.append(inst)
                if let a = inst as? AudioSourceInstance { mixer.addSource(d.id, output: a.audioOutput, audio: d.audio) }
            }
        }
        if c.scene(programSceneID) == nil { programSceneID = c.currentSceneID }
        if let p = previewSceneID, c.scene(p) == nil { previewSceneID = c.scenes.first?.id }
        lock.unlock()
        toStop.forEach { $0.stop() }
        toStart.forEach { $0.start() }
        if !removed.isEmpty {
            renderQueue.async { [weak self] in removed.forEach { self?.renderer.forget(sourceID: $0) } }
        }
        updateActiveAudio()
    }

    private func makeInstance(_ d: SourceDescriptor) -> SourceInstance? {
        switch d.settings {
        case .camera(let s): return CameraSource(descriptor: d, settings: s, textureCache: textureCache)
        case .display(let s): return ScreenCaptureSource(descriptor: d, mode: .display(s), textureCache: textureCache)
        case .window(let s): return ScreenCaptureSource(descriptor: d, mode: .window(s), textureCache: textureCache)
        case .audioInput(let s): return AudioInputSource(descriptor: d, settings: s)
        case .systemAudio(let s): return SystemAudioSource(descriptor: d, settings: s)
        case .media(let s): return MediaSource(descriptor: d, settings: s, textureCache: textureCache)
        case .image(let s): return ImageSource(descriptor: d, settings: s, device: device)
        case .text(let s): return TextSource(descriptor: d, settings: s, device: device)
        case .color(let s): return ColorSource(descriptor: d, settings: s)
        }
    }

    func source(_ id: UUID) -> SourceInstance? {
        lock.lock(); defer { lock.unlock() }
        return sources[id]
    }

    func sourceStatus(_ id: UUID) -> String { source(id)?.status ?? "" }

    func sourceDisplayedSize(_ id: UUID) -> Size2D? {
        guard let v = source(id) as? VideoSourceInstance else { return nil }
        return v.displayedSize ?? v.latestFrame()?.size
    }

    func audioInputChannels(_ id: UUID) -> Int? {
        (source(id) as? AudioInputSource)?.deviceChannels
    }

    // MARK: scenes

    var currentProgramSceneID: UUID {
        lock.lock(); defer { lock.unlock() }
        return programSceneID
    }

    var currentPreviewSceneID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return previewSceneID
    }

    func setStudioMode(_ on: Bool) {
        lock.lock()
        studioMode = on
        if on, previewSceneID == nil { previewSceneID = programSceneID }
        lock.unlock()
    }

    func setPreviewScene(_ id: UUID) {
        lock.lock()
        previewSceneID = id
        lock.unlock()
    }

    /// Switches the program scene, with the collection's transition when `animated`.
    func switchProgramScene(to id: UUID, transition t: TransitionSettings, animated: Bool = true) {
        lock.lock()
        guard id != programSceneID || transition != nil else { lock.unlock(); return }
        let from = transition?.to ?? programSceneID
        if !animated || t.kind == .cut || t.durationMs <= 0 {
            transition = nil
            programSceneID = id
            lock.unlock()
            activateMedia(in: id)
            updateActiveAudio()
            DispatchQueue.main.async { self.onProgramSceneChanged?(id) }
            return
        }
        transition = ActiveTransition(from: from, to: id, kind: t.kind, start: hostTimeSeconds(), duration: Double(t.durationMs) / 1000)
        lock.unlock()
        activateMedia(in: id)
        updateActiveAudio()
    }

    /// Studio mode: send the preview scene to program (and swap).
    func performStudioTransition(_ t: TransitionSettings) {
        lock.lock()
        guard studioMode, let p = previewSceneID else { lock.unlock(); return }
        let oldProgram = transition?.to ?? programSceneID
        lock.unlock()
        switchProgramScene(to: p, transition: t)
        lock.lock()
        previewSceneID = oldProgram
        lock.unlock()
    }

    private func activateMedia(in sceneID: UUID) {
        lock.lock()
        let c = collection
        let insts = sources
        lock.unlock()
        guard let scene = c.scene(sceneID) else { return }
        for item in scene.items where item.visible {
            if let m = insts[item.sourceID] as? MediaSource, case .media(let s) = c.source(item.sourceID)?.settings, s.restartWhenActivated {
                m.restart()
            }
        }
    }

    /// Audio is heard from sources that sit (visible) in the program scene, or in either
    /// side of a running transition. Same rule as OBS.
    private func updateActiveAudio() {
        lock.lock()
        let c = collection
        var ids = Set<UUID>()
        var sceneIDs = [programSceneID]
        if let t = transition { sceneIDs.append(t.to); sceneIDs.append(t.from) }
        lock.unlock()
        for sid in sceneIDs {
            for item in c.scene(sid)?.items ?? [] where item.visible { ids.insert(item.sourceID) }
        }
        mixer.setActiveSources(ids)
    }

    // MARK: outputs

    func startRecording(settings: RecordingSettings, sceneName: String) throws {
        guard recorder == nil else { return }
        let r = try Recorder(settings: settings, video: videoSettings, sceneName: sceneName)
        try r.start()
        mixer.addSink(r)
        renderQueue.sync { recorder = r }
    }

    func stopRecording(completion: @escaping (Error?) -> Void) {
        guard let r = recorder else { completion(nil); return }
        renderQueue.sync { recorder = nil }
        mixer.removeSink(r)
        r.stop(completion: completion)
    }

    func startStreaming(settings: StreamSettings) {
        guard stream == nil else { return }
        let s = StreamOutput(settings: settings, video: videoSettings)
        mixer.addSink(s)
        renderQueue.sync { stream = s }
        s.start()
    }

    func stopStreaming() {
        guard let s = stream else { return }
        renderQueue.sync { stream = nil }
        mixer.removeSink(s)
        s.stop()
    }

    func startReplayBuffer(settings: ReplayBufferSettings, recording: RecordingSettings) {
        guard replay == nil else { return }
        let r = ReplayBuffer(settings: settings, recording: recording, video: videoSettings)
        mixer.addSink(r)
        renderQueue.sync { replay = r }
        r.start()
    }

    func stopReplayBuffer() {
        guard let r = replay else { return }
        renderQueue.sync { replay = nil }
        mixer.removeSink(r)
        r.stop()
    }

    var anyOutputActive: Bool { recorder != nil || stream != nil || replay != nil }

    // MARK: display

    func programTextureForDisplay() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latestProgram
    }

    func previewTextureForDisplay() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latestPreview
    }

    func currentStats() -> EngineStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: render loop

    private func buildScene(_ sceneID: UUID, c: SceneCollection, insts: [UUID: SourceInstance]) -> RenderScene {
        var items: [RenderItem] = []
        guard let scene = c.scene(sceneID) else { return RenderScene(items: [], canvasSize: videoSettings.baseSize) }
        for item in scene.items where item.visible {
            guard let d = c.source(item.sourceID), let v = insts[item.sourceID] as? VideoSourceInstance else { continue }
            let frame = v.latestFrame()
            guard let displayed = v.displayedSize ?? frame?.size, !displayed.isEmpty else { continue }
            if frame == nil && v.solidColor == nil { continue }
            let filters = d.filters.filter { $0.enabled }.map { $0.type }
            items.append(RenderItem(sourceID: d.id, texture: frame?.texture, solidColor: v.solidColor, displayedSize: displayed,
                                    quarterTurns: v.quarterTurns, mirror: v.mirror, transform: item.transform, filters: filters, upscale: d.upscale))
            // keep holders alive for this frame
            if let f = frame { frameHolders.append(f) }
        }
        return RenderScene(items: items, canvasSize: videoSettings.baseSize)
    }

    private var frameHolders: [VideoFrame] = []

    private func tick() {
        guard isRunning else { return }
        let tickStart = hostTimeSeconds()
        expectedFrames += 1
        guard inFlight.wait(timeout: .now()) == .success else {
            lock.lock(); stats.droppedFrames += 1; lock.unlock()
            return
        }
        lock.lock()
        let c = collection
        let insts = sources
        let program = programSceneID
        let preview = previewSceneID
        let studio = studioMode
        var trans = transition
        let video = videoSettings
        lock.unlock()

        // Notify size changes (auto-fit in the UI)
        for (id, inst) in insts {
            guard let v = inst as? VideoSourceInstance, let size = v.displayedSize ?? v.latestFrame()?.size, !size.isEmpty else { continue }
            lock.lock()
            let changed = knownSizes[id] != size
            if changed { knownSizes[id] = size }
            lock.unlock()
            if changed { DispatchQueue.main.async { self.onSourceSizeChanged?(id, size) } }
        }

        guard !programTextures.isEmpty, let cb = renderer.commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        cb.label = "frame"
        frameHolders.removeAll(keepingCapacity: true)
        let target = programTextures[programIndex]
        programIndex = (programIndex + 1) % programTextures.count

        var finishedTransition: UUID?
        if let t = trans {
            let progress = min(1, (hostTimeSeconds() - t.start) / max(0.001, t.duration))
            if transitionTextures.count == 2 {
                let a = transitionTextures[0], b = transitionTextures[1]
                renderer.render(cb, scene: buildScene(t.from, c: c, insts: insts), into: a)
                renderer.render(cb, scene: buildScene(t.to, c: c, insts: insts), into: b)
                renderer.transition(cb, from: a, to: b, kind: t.kind, progress: progress, into: target)
            } else {
                renderer.render(cb, scene: buildScene(t.to, c: c, insts: insts), into: target)
            }
            if progress >= 1 {
                finishedTransition = t.to
                trans = nil
            }
        } else {
            renderer.render(cb, scene: buildScene(program, c: c, insts: insts), into: target)
        }

        var previewTarget: MTLTexture?
        if studio, let p = preview, !previewTextures.isEmpty {
            let pt = previewTextures[previewIndex]
            previewIndex = (previewIndex + 1) % previewTextures.count
            renderer.render(cb, scene: buildScene(p, c: c, insts: insts), into: pt)
            previewTarget = pt
        }

        // Output scaling + pixel buffer for encoders
        var outputTexture: MTLTexture = target
        if video.outputSize != video.baseSize {
            if let up = renderer.upscale(cb, input: target, to: video.outputSize, kind: video.upscaler, key: "canvas") {
                outputTexture = up
            }
        }
        let needsOutput = recorder != nil || stream != nil || replay != nil
        var outPixelBuffer: CVPixelBuffer?
        var outHolder: CVMetalTexture?
        if needsOutput, let pool = pixelPool, let pb = pool.makeBuffer(), let pair = textureCache.texture(from: pb) {
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: outputTexture, to: pair.0)
                blit.endEncoding()
                outPixelBuffer = pb
                outHolder = pair.1
            }
        }

        let framePTS = pts()
        let holders = frameHolders
        let rec = recorder, str = stream, rep = replay
        cb.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            _ = holders
            _ = outHolder
            self.lock.lock()
            self.latestProgram = target
            if let previewTarget { self.latestPreview = previewTarget }
            self.stats.totalFrames += 1
            self.stats.gpuMilliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self.stats.renderMilliseconds = (hostTimeSeconds() - tickStart) * 1000
            self.stats.targetFPS = video.frameRate
            self.stats.activeSources = insts.count
            self.fpsWindow.frames += 1
            let now = hostTimeSeconds()
            if now - self.fpsWindow.start >= 1 {
                self.stats.fps = Double(self.fpsWindow.frames) / (now - self.fpsWindow.start)
                self.fpsWindow = (now, 0)
            }
            self.lock.unlock()
            if let pb = outPixelBuffer {
                rec?.receiveVideo(pb, pts: framePTS)
                str?.receiveVideo(pb, pts: framePTS)
                rep?.receiveVideo(pb, pts: framePTS)
            }
            self.inFlight.signal()
        }
        cb.commit()

        if let done = finishedTransition {
            // Only commit if this is still the active transition (a cut may have replaced it mid-frame).
            lock.lock()
            let commit = transition?.to == done
            if commit {
                transition = nil
                programSceneID = done
            }
            lock.unlock()
            if commit {
                updateActiveAudio()
                DispatchQueue.main.async { self.onProgramSceneChanged?(done) }
            }
        }
    }
}
