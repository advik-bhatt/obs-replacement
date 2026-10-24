import AppKit
import AVFoundation
import Combine
import Foundation
import UpstageCore

struct MixerLevels {
    var master: AudioLevels = AudioLevels(peakDB: [-100, -100], holdDB: [-100, -100], inputPeakDB: [-100, -100])
    var sources: [UUID: AudioLevels] = [:]
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The app's single observable model. Owns the engine, persistence, device
/// managers and control surfaces; the views bind to it.
final class AppState: ObservableObject {
    let engine: Engine?
    let engineError: String?
    let store = Store()
    let videoDevices = VideoDeviceManager()
    let audioDevices = AudioDeviceManager()
    let hotkeys = HotkeyManager()
    let midi = MIDIManager()
    let remote = RemoteControlServer()

    @Published var collection: SceneCollection {
        didSet { if !suppressSync { collectionChanged() } }
    }
    @Published var profile: Profile {
        didSet { if !suppressSync { profileChanged(old: oldValue) } }
    }
    @Published var programSceneID: UUID
    @Published var previewSceneID: UUID?
    @Published var studioMode = false
    @Published var selectedItemID: UUID?
    @Published var isRecording = false
    @Published var recordingPaused = false
    @Published var recordingDuration: Double = 0
    @Published var recordingURL: URL?
    @Published var isStreaming = false
    @Published var streamState: StreamOutput.State = .idle
    @Published var streamStats = StreamOutput.Stats()
    @Published var replayActive = false
    @Published var stats = EngineStats()
    @Published var levels = MixerLevels()
    @Published var displays: [DisplayInfo] = []
    @Published var windows: [WindowInfo] = []
    @Published var alert: AppAlert?
    @Published var lastMIDIEvent: (device: String, channel: UInt8, message: MIDIMessageKind)?
    @Published var remoteClients = 0
    @Published var cameraAuthorized = false
    @Published var microphoneAuthorized = false
    @Published var transitionInProgress = false
    @Published var showAddSource = false
    @Published var propertiesSourceID: UUID?
    @Published var filtersSourceID: UUID?
    @Published var transformItemID: UUID?
    @Published var collectionNames: [String] = []
    @Published var profileNames: [String] = []

    private var suppressSync = false
    private var pendingFit: Set<UUID> = []
    private var uiTimer: Timer?
    private var pushToTalkMuted: [UUID: Bool] = [:]

    init() {
        var eng: Engine?
        var err: String?
        do {
            eng = try Engine()
        } catch {
            err = "\(error)"
        }
        engine = eng
        engineError = err

        let loadedCollection = store.loadCollection() ?? .empty(name: store.activeCollectionName)
        let loadedProfile = store.loadProfile() ?? Profile(name: store.activeProfileName)
        collection = loadedCollection
        profile = loadedProfile
        programSceneID = loadedCollection.currentSceneID
        previewSceneID = loadedCollection.previewSceneID
        collectionNames = store.listCollections()
        profileNames = store.listProfiles()
        if collectionNames.isEmpty { store.saveNow(collection: loadedCollection); collectionNames = store.listCollections() }
        if profileNames.isEmpty { store.saveNow(profile: loadedProfile); profileNames = store.listProfiles() }

        wireEngine()
        requestPermissions()
        refreshShareableContent()
        hotkeys.onAction = { [weak self] action, pressed in self?.perform(action, pressed: pressed, value: nil) }
        midi.onAction = { [weak self] action, pressed, value in self?.perform(action, pressed: pressed, value: value) }
        midi.onEvent = { [weak self] device, channel, message, _, _ in self?.lastMIDIEvent = (device, channel, message) }
        remote.host = self
        remote.onClientCountChanged = { [weak self] n in DispatchQueue.main.async { self?.remoteClients = n } }
        applyProfile(force: true)
        engine?.apply(collection: collection)
        engine?.start()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollEngine() }
    }

    private func wireEngine() {
        guard let engine else { return }
        engine.onSourceSizeChanged = { [weak self] id, size in self?.autoFit(sourceID: id, size: size) }
        engine.onProgramSceneChanged = { [weak self] id in
            guard let self else { return }
            self.programSceneID = id
            self.transitionInProgress = false
            if self.collection.currentSceneID != id {
                self.suppressSync = true
                self.collection.currentSceneID = id
                self.suppressSync = false
                self.store.scheduleSave(collection: self.collection)
            }
            self.remote.broadcast(event: "CurrentProgramSceneChanged", intent: OBSWebSocket.EventSubscription.scenes,
                                  data: ["sceneName": .string(self.collection.scene(id)?.name ?? ""), "sceneUuid": .string(self.collection.scene(id)?.name ?? "")])
        }
    }

    private func requestPermissions() {
        VideoDeviceManager.requestAccess(.video) { [weak self] ok in
            self?.cameraAuthorized = ok
            self?.videoDevices.refresh()
        }
        VideoDeviceManager.requestAccess(.audio) { [weak self] ok in self?.microphoneAuthorized = ok }
    }

    func refreshShareableContent() {
        ShareableContent.fetch { [weak self] d, w in
            self?.displays = d
            self?.windows = w
        }
    }

    // MARK: sync

    private func collectionChanged() {
        engine?.apply(collection: collection)
        store.scheduleSave(collection: collection)
    }

    private func profileChanged(old: Profile) {
        applyProfile(force: false, old: old)
        store.scheduleSave(profile: profile)
    }

    func applyProfile(force: Bool, old: Profile? = nil) {
        guard let engine else { return }
        if force || old?.video != profile.video {
            if engine.anyOutputActive {
                // Changing the canvas mid-output would break the encoders; revert.
                if let old { suppressSync = true; profile.video = old.video; suppressSync = false }
                alert = AppAlert(title: "Video settings locked", message: "Stop recording, streaming and the replay buffer before changing resolution or frame rate.")
            } else {
                engine.apply(video: profile.video)
                // A real canvas change re-fits everything; launch keeps the saved layout.
                if !force {
                    for scene in collection.scenes { for item in scene.items { pendingFit.insert(item.id) } }
                    refitAll()
                }
            }
        }
        if force || old?.hotkeys != profile.hotkeys { hotkeys.apply(profile.hotkeys) }
        if force || old?.midi != profile.midi { midi.apply(profile.midi) }
        if force || old?.remote != profile.remote {
            scheduleRemoteApply(immediate: force)
        }
        if force || old?.audio.monitoringDeviceUID != profile.audio.monitoringDeviceUID {
            engine.mixer.setMonitoringDevice(uid: profile.audio.monitoringDeviceUID)
        }
        if force || old?.replay != profile.replay {
            if profile.replay.enabled, !replayActive { startReplayBuffer() }
            if !profile.replay.enabled, replayActive { stopReplayBuffer() }
        }
    }

    private var remoteApplyTimer: Timer?

    /// The Remote settings fields write on every keystroke; restart the listener once they settle.
    private func scheduleRemoteApply(immediate: Bool) {
        remoteApplyTimer?.invalidate()
        remoteApplyTimer = nil
        let apply = { [weak self] in
            guard let self else { return }
            if self.profile.remote.enabled {
                self.remote.start(port: self.profile.remote.port, password: self.profile.remote.password)
            } else {
                self.remote.stop()
            }
        }
        if immediate {
            apply()
        } else {
            remoteApplyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in apply() }
        }
    }

    private func pollEngine() {
        guard let engine else { return }
        stats = engine.currentStats()
        let l = engine.mixer.levels()
        levels = MixerLevels(master: l.master, sources: l.sources)
        if let r = engine.recorder {
            recordingDuration = r.duration
            if case .failed(let why) = r.state, isRecording {
                isRecording = false
                recordingPaused = false
                engine.stopRecording { _ in }
                alert = AppAlert(title: "Recording failed", message: why)
            }
        }
        if let s = engine.stream {
            streamStats = s.stats
            if streamState != s.state { streamState = s.state }
            if case .failed(let why) = s.state, isStreaming {
                isStreaming = false
                alert = AppAlert(title: "Stream stopped", message: why)
                engine.stopStreaming()
            }
        }
    }

    // MARK: scenes

    var canvasSize: Size2D { profile.video.baseSize }

    /// The scene the Sources panel edits: preview in studio mode, program otherwise.
    var editingSceneID: UUID { studioMode ? (previewSceneID ?? programSceneID) : programSceneID }
    var editingScene: StudioScene? { collection.scene(editingSceneID) }

    func selectScene(_ id: UUID) {
        guard collection.scene(id) != nil, let engine else { return }
        if studioMode {
            previewSceneID = id
            engine.setPreviewScene(id)
            suppressSync = true
            collection.previewSceneID = id
            suppressSync = false
            store.scheduleSave(collection: collection)
        } else {
            transitionInProgress = collection.transition.kind != .cut
            engine.switchProgramScene(to: id, transition: collection.transition)
            if collection.transition.kind == .cut || collection.transition.durationMs <= 0 { programSceneID = id }
            collection.currentSceneID = id
        }
        selectedItemID = nil
    }

    func addScene() {
        let s = collection.addScene(named: "Scene")
        selectScene(s.id)
    }

    func removeScene(_ id: UUID) {
        guard collection.scenes.count > 1 else { return }
        let wasProgram = programSceneID == id
        collection.removeScene(id)   // Engine.apply already moved its own program scene
        if wasProgram {
            programSceneID = collection.currentSceneID
            engine?.switchProgramScene(to: programSceneID, transition: TransitionSettings(kind: .cut), animated: false)
            transitionInProgress = false
        }
        if previewSceneID == id {
            previewSceneID = collection.scenes.first?.id
            if let p = previewSceneID { engine?.setPreviewScene(p) }
        }
        if selectedItemID != nil, item(selectedItemID!) == nil { selectedItemID = nil }
    }

    /// Modal yes/no used by the stop confirmations.
    private func confirmStop(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func renameScene(_ id: UUID, to name: String) {
        guard let idx = collection.sceneIndex(id), !name.isEmpty else { return }
        collection.scenes[idx].name = collection.uniqueName(name, existing: collection.scenes.filter { $0.id != id }.map { $0.name })
    }

    func moveScene(from: Int, to: Int) { collection.moveScene(from: from, to: to) }

    func toggleStudioMode() {
        studioMode.toggle()
        if studioMode, previewSceneID == nil { previewSceneID = programSceneID }
        engine?.setStudioMode(studioMode)
        if let p = previewSceneID { engine?.setPreviewScene(p) }
        remote.broadcast(event: "StudioModeStateChanged", intent: OBSWebSocket.EventSubscription.ui, data: ["studioModeEnabled": .bool(studioMode)])
    }

    func transition() {
        guard studioMode, let engine else { return }
        transitionInProgress = true
        engine.performStudioTransition(collection.transition)
        let oldProgram = programSceneID
        previewSceneID = oldProgram
        suppressSync = true
        collection.previewSceneID = oldProgram
        suppressSync = false
    }

    // MARK: sources & items

    func addSource(kind: SourceKind, name: String, settings: SourceSettings? = nil) {
        var d = SourceDescriptor(name: name.isEmpty ? kind.displayName : name, settings: settings ?? SourceSettings.defaults(for: kind))
        d.upscale = profile.video.sourceUpscale
        if let item = collection.addSource(d, toScene: editingSceneID) {
            pendingFit.insert(item.id)
            selectedItemID = item.id
            if kind.hasVideo, let size = engine?.sourceDisplayedSize(d.id) ?? staticSize(of: d) { autoFit(sourceID: d.id, size: size) }
            propertiesSourceID = d.id
        }
    }

    private func staticSize(of d: SourceDescriptor) -> Size2D? {
        if case .color(let c) = d.settings { return c.size }
        return nil
    }

    func addExistingSource(_ sourceID: UUID) {
        if let item = collection.addItem(sourceID: sourceID, toScene: editingSceneID) {
            pendingFit.insert(item.id)
            if let size = engine?.sourceDisplayedSize(sourceID) { autoFit(sourceID: sourceID, size: size) }
            selectedItemID = item.id
        }
    }

    func removeItem(_ itemID: UUID) {
        collection.removeItem(itemID, fromScene: editingSceneID)
        if selectedItemID == itemID { selectedItemID = nil }
    }

    func item(_ id: UUID) -> SceneItem? { editingScene?.items.first { $0.id == id } }

    func updateItem(_ item: SceneItem) { collection.updateItem(item, inScene: editingSceneID) }

    func toggleVisible(_ itemID: UUID) {
        guard var it = item(itemID) else { return }
        it.visible.toggle()
        updateItem(it)
    }

    func toggleLocked(_ itemID: UUID) {
        guard var it = item(itemID) else { return }
        it.locked.toggle()
        updateItem(it)
    }

    func moveItem(_ itemID: UUID, by delta: Int) { collection.moveItem(itemID, inScene: editingSceneID, by: delta) }

    func source(for itemID: UUID) -> SourceDescriptor? {
        guard let it = item(itemID) else { return nil }
        return collection.source(it.sourceID)
    }

    func updateSource(_ d: SourceDescriptor) {
        let old = collection.source(d.id)
        collection.updateSource(d)
        // Rotation changes the displayed size, so re-fit the items that show it.
        if case .camera(let n) = d.settings, case .camera(let o)? = old?.settings, n.rotation != o.rotation {
            refit(sourceID: d.id)
        }
    }

    func refit(sourceID: UUID) {
        for scene in collection.scenes { for it in scene.items where it.sourceID == sourceID { pendingFit.insert(it.id) } }
        if let size = engine?.sourceDisplayedSize(sourceID) { autoFit(sourceID: sourceID, size: size) }
    }

    private func autoFit(sourceID: UUID, size: Size2D) {
        guard !size.isEmpty else { return }
        var changed = false
        for (si, scene) in collection.scenes.enumerated() {
            for (ii, it) in scene.items.enumerated() where it.sourceID == sourceID && pendingFit.contains(it.id) {
                let rotation = collection.scenes[si].items[ii].transform.rotation
                collection.scenes[si].items[ii].transform = Transform.fitting(source: size, in: canvasSize, mode: .fit, rotation: rotation)
                pendingFit.remove(it.id)
                changed = true
            }
        }
        _ = changed
    }

    private func refitAll() {
        for d in collection.sources { if let size = engine?.sourceDisplayedSize(d.id) ?? staticSize(of: d) { autoFit(sourceID: d.id, size: size) } }
    }

    func fitItem(_ itemID: UUID, mode: Transform.FitMode) {
        guard var it = item(itemID), let d = collection.source(it.sourceID) else { return }
        guard let size = engine?.sourceDisplayedSize(d.id) ?? staticSize(of: d) else { return }
        let t = Transform.fitting(source: size, in: canvasSize, mode: mode, rotation: it.transform.rotation, crop: it.transform.crop)
        it.transform.position = t.position
        it.transform.scale = t.scale
        updateItem(it)
    }

    func resetTransform(_ itemID: UUID) {
        guard var it = item(itemID) else { return }
        it.transform = .identity
        updateItem(it)
        pendingFit.insert(itemID)
        if let d = collection.source(it.sourceID), let size = engine?.sourceDisplayedSize(d.id) ?? staticSize(of: d) { autoFit(sourceID: d.id, size: size) }
    }

    func displayedSize(ofSource id: UUID) -> Size2D? {
        guard let d = collection.source(id) else { return nil }
        return engine?.sourceDisplayedSize(id) ?? staticSize(of: d)
    }

    // MARK: audio

    func setVolume(_ sourceID: UUID, db: Double) {
        guard var d = collection.source(sourceID) else { return }
        d.audio.volumeDB = max(AudioMath.silenceDB, min(26, db))
        collection.updateSource(d)
        remote.broadcast(event: "InputVolumeChanged", intent: OBSWebSocket.EventSubscription.inputs,
                         data: ["inputName": .string(d.name), "inputVolumeMul": .number(Double(AudioMath.linear(fromDB: d.audio.volumeDB))), "inputVolumeDb": .number(d.audio.volumeDB)])
    }

    func setMuted(_ sourceID: UUID, _ muted: Bool) {
        guard var d = collection.source(sourceID), d.audio.muted != muted else { return }
        d.audio.muted = muted
        collection.updateSource(d)
        remote.broadcast(event: "InputMuteStateChanged", intent: OBSWebSocket.EventSubscription.inputs, data: ["inputName": .string(d.name), "inputMuted": .bool(muted)])
    }

    func toggleMute(_ sourceID: UUID) {
        guard let d = collection.source(sourceID) else { return }
        setMuted(sourceID, !d.audio.muted)
    }

    func setMonitoring(_ sourceID: UUID, _ mode: MonitoringMode) {
        guard var d = collection.source(sourceID) else { return }
        d.audio.monitoring = mode
        collection.updateSource(d)
    }

    /// Audio-capable sources in the program scene (what the mixer shows), in draw order.
    var mixerSources: [SourceDescriptor] {
        guard let scene = collection.scene(programSceneID) else { return [] }
        var seen = Set<UUID>()
        var out: [SourceDescriptor] = []
        for it in scene.items {
            guard let d = collection.source(it.sourceID), d.kind.hasAudio, seen.insert(d.id).inserted else { continue }
            if case .camera(let c) = d.settings, !c.captureAudio { continue }
            out.append(d)
        }
        return out
    }

    // MARK: filters

    func addFilter(_ type: FilterType, to sourceID: UUID) {
        guard var d = collection.source(sourceID) else { return }
        let base = type.displayName
        let name = collection.uniqueName(base, existing: d.filters.map { $0.name })
        d.filters.append(FilterDescriptor(name: name, type: type))
        collection.updateSource(d)
    }

    func updateFilter(_ f: FilterDescriptor, in sourceID: UUID) {
        guard var d = collection.source(sourceID), let idx = d.filters.firstIndex(where: { $0.id == f.id }) else { return }
        d.filters[idx] = f
        collection.updateSource(d)
    }

    func removeFilter(_ id: UUID, from sourceID: UUID) {
        guard var d = collection.source(sourceID) else { return }
        d.filters.removeAll { $0.id == id }
        collection.updateSource(d)
    }

    func moveFilter(_ id: UUID, in sourceID: UUID, by delta: Int) {
        guard var d = collection.source(sourceID), let idx = d.filters.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, idx + delta), d.filters.count - 1)
        guard target != idx else { return }
        let f = d.filters.remove(at: idx)
        d.filters.insert(f, at: target)
        collection.updateSource(d)
    }

    // MARK: outputs

    /// `confirm` honours Settings > General; hotkeys and remote control pass false.
    func toggleRecording(confirm: Bool = true) {
        if isRecording {
            if confirm, profile.general.confirmBeforeStoppingRecording, !confirmStop("Stop recording?") { return }
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard let engine, !isRecording else { return }
        let errs = profile.recording.validationErrors
        guard errs.isEmpty else {
            alert = AppAlert(title: "Recording settings", message: errs.joined(separator: "\n"))
            return
        }
        do {
            try engine.startRecording(settings: profile.recording, sceneName: collection.scene(programSceneID)?.name ?? "Scene")
            isRecording = true
            recordingPaused = false
            recordingURL = engine.recorder?.url
            remote.broadcast(event: "RecordStateChanged", intent: OBSWebSocket.EventSubscription.outputs, data: ["outputActive": .bool(true), "outputState": "OBS_WEBSOCKET_OUTPUT_STARTED", "outputPath": .string(recordingURL?.path ?? "")])
        } catch {
            alert = AppAlert(title: "Could not start recording", message: error.localizedDescription)
        }
    }

    func stopRecording() {
        guard let engine, isRecording else { return }
        let url = recordingURL
        engine.stopRecording { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.alert = AppAlert(title: "Recording finished with an error", message: error.localizedDescription) }
                self.remote.broadcast(event: "RecordStateChanged", intent: OBSWebSocket.EventSubscription.outputs, data: ["outputActive": .bool(false), "outputState": "OBS_WEBSOCKET_OUTPUT_STOPPED", "outputPath": .string(url?.path ?? "")])
            }
        }
        isRecording = false
        recordingPaused = false
        recordingDuration = 0
    }

    func pauseResumeRecording() {
        guard let r = engine?.recorder, isRecording else { return }
        if recordingPaused { r.resume() } else { r.pause() }
        recordingPaused.toggle()
    }

    func toggleStreaming(confirm: Bool = true) {
        if isStreaming {
            if confirm, profile.general.confirmBeforeStoppingStream, !confirmStop("Stop streaming? You are live.") { return }
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        guard let engine, !isStreaming else { return }
        let errs = profile.stream.validationErrors
        guard errs.isEmpty else {
            alert = AppAlert(title: "Stream settings", message: errs.joined(separator: "\n"))
            return
        }
        engine.startStreaming(settings: profile.stream)
        isStreaming = true
        streamState = .connecting
        engine.stream?.onStateChange = { [weak self] st in
            DispatchQueue.main.async {
                self?.streamState = st
                let active = st == .live || st == .connecting
                let state: String
                switch st {
                case .live: state = "OBS_WEBSOCKET_OUTPUT_STARTED"
                case .connecting: state = "OBS_WEBSOCKET_OUTPUT_STARTING"
                case .reconnecting: state = "OBS_WEBSOCKET_OUTPUT_RECONNECTING"
                case .stopped, .idle: state = "OBS_WEBSOCKET_OUTPUT_STOPPED"
                case .failed: state = "OBS_WEBSOCKET_OUTPUT_STOPPED"
                }
                self?.remote.broadcast(event: "StreamStateChanged", intent: OBSWebSocket.EventSubscription.outputs, data: ["outputActive": .bool(active), "outputState": .string(state)])
            }
        }
    }

    func stopStreaming() {
        guard let engine, isStreaming else { return }
        engine.stopStreaming()
        isStreaming = false
        streamState = .stopped
        remote.broadcast(event: "StreamStateChanged", intent: OBSWebSocket.EventSubscription.outputs, data: ["outputActive": .bool(false), "outputState": "OBS_WEBSOCKET_OUTPUT_STOPPED"])
    }

    func startReplayBuffer() {
        guard let engine, !replayActive else { return }
        engine.startReplayBuffer(settings: profile.replay, recording: profile.recording)
        replayActive = true
    }

    func stopReplayBuffer() {
        guard let engine, replayActive else { return }
        engine.stopReplayBuffer()
        replayActive = false
    }

    func toggleReplayBuffer() {
        if replayActive { stopReplayBuffer() } else { startReplayBuffer() }
    }

    func saveReplay() {
        guard let r = engine?.replay else {
            alert = AppAlert(title: "Replay buffer", message: "Start the replay buffer first (Settings > Output > Replay Buffer).")
            return
        }
        r.save { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let e): self?.alert = AppAlert(title: "Replay not saved", message: e.localizedDescription)
                }
            }
        }
    }

    // MARK: control actions

    func perform(_ action: ControlAction, pressed: Bool, value: Double?) {
        switch action {
        case .startStopStreaming: if pressed { toggleStreaming(confirm: false) }
        case .startStopRecording: if pressed { toggleRecording(confirm: false) }
        case .pauseResumeRecording: if pressed { pauseResumeRecording() }
        case .saveReplay: if pressed { saveReplay() }
        case .toggleStudioMode: if pressed { toggleStudioMode() }
        case .transition: if pressed { transition() }
        case .toggleVirtualCamera: break
        case .switchToScene(let id): if pressed, !studioMode { selectScene(id) } else if pressed { previewSceneID = id; engine?.setPreviewScene(id); transition() }
        case .setPreviewScene(let id): if pressed { if !studioMode { toggleStudioMode() }; selectScene(id) }
        case .toggleMute(let id): if pressed { toggleMute(id) }
        case .pushToMute(let id):
            if pressed { pushToTalkMuted[id] = collection.source(id)?.audio.muted ?? false; setMuted(id, true) } else { setMuted(id, pushToTalkMuted[id] ?? false) }
        case .pushToTalk(let id):
            if pressed { pushToTalkMuted[id] = collection.source(id)?.audio.muted ?? true; setMuted(id, false) } else { setMuted(id, pushToTalkMuted[id] ?? true) }
        case .toggleSceneItem(let sceneID, let itemID):
            guard pressed, let sidx = collection.sceneIndex(sceneID), let iidx = collection.scenes[sidx].items.firstIndex(where: { $0.id == itemID }) else { return }
            collection.scenes[sidx].items[iidx].visible.toggle()
        case .setVolume(let id):
            if let v = value { setVolume(id, db: AudioMath.dB(fromFaderPosition: v)) }
        }
    }

    // MARK: collections & profiles

    func switchCollection(named name: String) {
        guard name != collection.name else { return }
        store.flush()
        guard let c = store.loadCollection(named: name) else { return }
        store.setActive(collection: name)
        suppressSync = true
        collection = c
        suppressSync = false
        programSceneID = c.currentSceneID
        previewSceneID = c.previewSceneID
        engine?.apply(collection: c)
        engine?.switchProgramScene(to: c.currentSceneID, transition: TransitionSettings(kind: .cut), animated: false)
        if let p = previewSceneID { engine?.setPreviewScene(p) }
        selectedItemID = nil
    }

    func newCollection(named name: String) {
        let unique = collection.uniqueName(name.isEmpty ? "Untitled" : name, existing: store.listCollections())
        let c = SceneCollection.empty(name: unique)
        store.saveNow(collection: c)
        collectionNames = store.listCollections()
        switchCollection(named: unique)
    }

    func duplicateCollection() {
        var c = collection
        c.name = collection.uniqueName(collection.name + " copy", existing: store.listCollections())
        store.saveNow(collection: c)
        collectionNames = store.listCollections()
        switchCollection(named: c.name)
    }

    func renameCollection(to name: String) {
        guard !name.isEmpty, name != collection.name else { return }
        guard !store.listCollections().contains(name) else {
            alert = AppAlert(title: "Name in use", message: "A scene collection called \"\(name)\" already exists.")
            return
        }
        let old = collection.name
        store.rename(collection: old, to: name)
        collection.name = name
        store.setActive(collection: name)
        collectionNames = store.listCollections()
    }

    func switchProfile(named name: String) {
        guard name != profile.name else { return }
        if isRecording || isStreaming {
            alert = AppAlert(title: "Profile locked", message: "Stop recording and streaming before switching profiles.")
            return
        }
        if replayActive { stopReplayBuffer() }   // applyProfile restarts it if the new profile wants it
        store.flush()
        guard let p = store.loadProfile(named: name) else { return }
        store.setActive(profile: name)
        profile = p
    }

    func newProfile(named name: String, portrait: Bool) {
        let unique = collection.uniqueName(name.isEmpty ? "Untitled" : name, existing: store.listProfiles())
        var p = portrait ? Profile.portrait4K() : Profile()
        p.name = unique
        store.saveNow(profile: p)
        profileNames = store.listProfiles()
        switchProfile(named: unique)
    }

    func duplicateProfile() {
        var p = profile
        p.name = collection.uniqueName(profile.name + " copy", existing: store.listProfiles())
        store.saveNow(profile: p)
        profileNames = store.listProfiles()
        switchProfile(named: p.name)
    }

    func renameProfile(to name: String) {
        guard !name.isEmpty, name != profile.name else { return }
        guard !store.listProfiles().contains(name) else {
            alert = AppAlert(title: "Name in use", message: "A profile called \"\(name)\" already exists.")
            return
        }
        store.rename(profile: profile.name, to: name)
        profile.name = name
        store.setActive(profile: name)
        profileNames = store.listProfiles()
    }

    /// Stops outputs, waits for the recorder to finalise its file, then stops the
    /// engine. `completion` runs on the main queue (at most ~3 s later).
    func shutdown(completion: @escaping () -> Void) {
        store.flush()
        let group = DispatchGroup()
        if isRecording, let engine {
            group.enter()
            isRecording = false
            engine.stopRecording { _ in group.leave() }
        }
        if isStreaming { stopStreaming() }
        let deadline = DispatchTime.now() + 3
        DispatchQueue.global().async { [weak self] in
            _ = group.wait(timeout: deadline)
            // Give the RTMP goodbye a moment to leave the socket.
            if self?.engine?.stream != nil { Thread.sleep(forTimeInterval: 0.3) }
            DispatchQueue.main.async {
                self?.engine?.stop()
                completion()
            }
        }
    }
}

// MARK: - obs-websocket host

extension AppState: RemoteControlHost {
    func rcVersionInfo() -> JSONValue {
        [
            "obsVersion": .string("30.0.0"),
            "obsWebSocketVersion": .string(OBSWebSocket.obsWebSocketVersion),
            "rpcVersion": .number(Double(OBSWebSocket.protocolVersion)),
            "availableRequests": .array(["GetVersion", "GetStats", "GetSceneList", "SetCurrentProgramScene", "GetCurrentProgramScene", "SetCurrentPreviewScene", "GetCurrentPreviewScene", "GetStudioModeEnabled", "SetStudioModeEnabled", "TriggerStudioModeTransition", "GetInputList", "GetInputMute", "SetInputMute", "ToggleInputMute", "GetInputVolume", "SetInputVolume", "GetStreamStatus", "StartStream", "StopStream", "ToggleStream", "GetRecordStatus", "StartRecord", "StopRecord", "ToggleRecord", "PauseRecord", "ResumeRecord", "ToggleRecordPause", "GetReplayBufferStatus", "StartReplayBuffer", "StopReplayBuffer", "ToggleReplayBuffer", "SaveReplayBuffer", "GetSceneItemList", "GetSceneItemEnabled", "SetSceneItemEnabled", "GetVirtualCamStatus", "GetHotkeyList", "TriggerHotkeyByName", "BroadcastCustomEvent", "Sleep"].map { .string($0) }),
            "supportedImageFormats": .array([]),
            "platform": .string("macos"),
            "platformDescription": .string("Upstage \(UpstageVersion.string) on macOS"),
        ]
    }

    func rcStats() -> JSONValue {
        [
            "activeFps": .number(stats.fps),
            "averageFrameRenderTime": .number(stats.renderMilliseconds),
            "renderSkippedFrames": .number(Double(stats.droppedFrames)),
            "renderTotalFrames": .number(Double(stats.totalFrames)),
            "outputSkippedFrames": .number(Double(streamStats.framesDropped)),
            "outputTotalFrames": .number(Double(streamStats.framesSent)),
            "cpuUsage": .number(0),
            "memoryUsage": .number(0),
            "availableDiskSpace": .number(0),
            "webSocketSessionIncomingMessages": .number(0),
            "webSocketSessionOutgoingMessages": .number(0),
        ]
    }

    func rcSceneList() -> (current: String, preview: String?, scenes: [String]) {
        (collection.scene(programSceneID)?.name ?? "", studioMode ? previewSceneID.flatMap { collection.scene($0)?.name } : nil, collection.scenes.map { $0.name })
    }

    func rcSetProgramScene(_ name: String) -> Bool {
        guard let s = collection.scenes.first(where: { $0.name == name }) else { return false }
        if studioMode {
            previewSceneID = s.id
            engine?.setPreviewScene(s.id)
            transition()
        } else {
            selectScene(s.id)
        }
        return true
    }

    func rcSetPreviewScene(_ name: String) -> Bool {
        guard let s = collection.scenes.first(where: { $0.name == name }) else { return false }
        selectScene(s.id)
        return true
    }

    func rcStudioMode() -> Bool { studioMode }
    func rcSetStudioMode(_ on: Bool) { if on != studioMode { toggleStudioMode() } }
    func rcTriggerTransition() { transition() }

    func rcInputs() -> [(name: String, kind: String, muted: Bool, volumeDB: Double)] {
        collection.sources.map { ($0.name, $0.kind.rawValue, $0.audio.muted, $0.audio.volumeDB) }
    }

    func rcSetMute(_ input: String, muted: Bool?) -> Bool {
        guard let d = collection.sources.first(where: { $0.name == input }) else { return false }
        setMuted(d.id, muted ?? !d.audio.muted)
        return true
    }

    func rcSetVolume(_ input: String, db: Double?, mul: Double?) -> Bool {
        guard let d = collection.sources.first(where: { $0.name == input }) else { return false }
        if let db { setVolume(d.id, db: db) } else if let mul { setVolume(d.id, db: AudioMath.dB(fromLinear: mul)) }
        return true
    }

    func rcStreamStatus() -> (active: Bool, reconnecting: Bool, seconds: Double, bytes: UInt64, skipped: Int, total: Int, congestion: Double) {
        var reconnecting = false
        if case .reconnecting = streamState { reconnecting = true }
        return (isStreaming, reconnecting, streamStats.uptimeSeconds, streamStats.bytesSent, streamStats.framesDropped, streamStats.framesSent, streamStats.congestion)
    }

    func rcStartStream() -> Bool {
        guard !isStreaming else { return false }
        startStreaming()
        return isStreaming
    }

    func rcStopStream() -> Bool {
        guard isStreaming else { return false }
        stopStreaming()
        return true
    }

    func rcRecordStatus() -> (active: Bool, paused: Bool, seconds: Double, bytes: Int64, path: String?) {
        (isRecording, recordingPaused, recordingDuration, engine?.recorder?.fileSize ?? 0, recordingURL?.path)
    }

    func rcStartRecord() -> Bool {
        guard !isRecording else { return false }
        startRecording()
        return isRecording
    }

    func rcStopRecord() -> String? {
        guard isRecording else { return nil }
        let p = recordingURL?.path
        stopRecording()
        return p ?? ""
    }

    func rcPauseRecord(_ pause: Bool) -> Bool {
        guard isRecording, recordingPaused != pause else { return false }
        pauseResumeRecording()
        return true
    }

    func rcReplayStatus() -> Bool { replayActive }

    func rcSetReplay(_ on: Bool) -> Bool {
        guard on != replayActive else { return false }
        if on { startReplayBuffer() } else { stopReplayBuffer() }
        return true
    }

    func rcSaveReplay() -> Bool {
        guard replayActive else { return false }
        saveReplay()
        return true
    }

    func rcSceneItems(_ scene: String) -> [(id: Int, name: String, enabled: Bool)]? {
        guard let s = collection.scenes.first(where: { $0.name == scene }) else { return nil }
        return s.items.enumerated().map { (i, it) in (i + 1, collection.source(it.sourceID)?.name ?? "", it.visible) }
    }

    func rcSetSceneItemEnabled(_ scene: String, id: Int, enabled: Bool) -> Bool {
        guard let sidx = collection.scenes.firstIndex(where: { $0.name == scene }), collection.scenes[sidx].items.indices.contains(id - 1) else { return false }
        collection.scenes[sidx].items[id - 1].visible = enabled
        return true
    }

    func rcHotkeyByName(_ name: String) -> Bool {
        guard let action = ControlAction.global.first(where: { $0.label == name || $0.label.replacingOccurrences(of: " ", with: "") == name }) else { return false }
        perform(action, pressed: true, value: nil)
        return true
    }
}
