import AppKit
import SwiftUI
import UpstageCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gear") }
            VideoSettingsTab().tabItem { Label("Video", systemImage: "display") }
            OutputSettingsTab().tabItem { Label("Output", systemImage: "record.circle") }
            StreamSettingsTab().tabItem { Label("Stream", systemImage: "dot.radiowaves.left.and.right") }
            AudioSettingsTab().tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            HotkeysTab().tabItem { Label("Hotkeys", systemImage: "keyboard") }
            MIDITab().tabItem { Label("MIDI", systemImage: "pianokeys") }
            RemoteTab().tabItem { Label("Remote", systemImage: "network") }
        }
        .frame(width: 720, height: 560)
        .padding()
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Text("Profile: \(state.profile.name)   ·   Scene collection: \(state.collection.name)").font(.caption).foregroundStyle(.secondary)
            Toggle("Confirm before stopping a stream", isOn: $state.profile.general.confirmBeforeStoppingStream)
            Toggle("Confirm before stopping a recording", isOn: $state.profile.general.confirmBeforeStoppingRecording)
            Toggle("Snap items to canvas edges and centre", isOn: $state.profile.general.snapToEdges)
            Toggle("Show safe-area guide in the preview", isOn: $state.profile.general.showPreviewSafeAreas)
            Section("Where things live") {
                Text(state.store.root.path).font(.caption).textSelection(.enabled)
                Text("Recordings: \((state.profile.recording.directory as NSString).expandingTildeInPath)").font(.caption)
            }
            Section("GPU") {
                Text(state.stats.gpuName)
                Text(state.stats.metalFX ? "MetalFX spatial upscaling: supported" : "MetalFX spatial upscaling: not supported on this GPU (Lanczos fallback)")
            }
        }
    }
}

struct VideoSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var draft = VideoSettings()
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Canvas") {
            Picker("Canvas (base) preset", selection: Binding(get: { CanvasPreset.matching(draft.baseSize) }, set: { if let p = $0 { draft.baseSize = p.size } })) {
                Text("Custom").tag(CanvasPreset?.none)
                ForEach(CanvasPreset.allCases, id: \.self) { Text($0.label).tag(CanvasPreset?.some($0)) }
            }
            HStack {
                Text("Canvas size")
                TextField("w", value: $draft.baseSize.width, format: .number).frame(width: 80)
                TextField("h", value: $draft.baseSize.height, format: .number).frame(width: 80)
            }
            }
            Section("Output") {
            Picker("Output preset", selection: Binding(get: { CanvasPreset.matching(draft.outputSize) }, set: { if let p = $0 { draft.outputSize = p.size } })) {
                Text("Custom").tag(CanvasPreset?.none)
                ForEach(CanvasPreset.allCases, id: \.self) { Text($0.label).tag(CanvasPreset?.some($0)) }
            }
            HStack {
                Text("Output size")
                TextField("w", value: $draft.outputSize.width, format: .number).frame(width: 80)
                TextField("h", value: $draft.outputSize.height, format: .number).frame(width: 80)
                Button("Same as canvas") { draft.outputSize = draft.baseSize }
            }
            }
            Section("Rate and scaling") {
            Picker("Frame rate", selection: $draft.frameRate) {
                ForEach(VideoSettings.commonFrameRates, id: \.self) { Text(String(format: "%.4g", $0)).tag($0) }
            }
            Picker("Canvas → output scaler", selection: $draft.upscaler) {
                ForEach(UpscalerKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Default per-source upscaling", selection: $draft.sourceUpscale) {
                ForEach(UpscaleMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Recommended for an iPhone Continuity Camera: canvas and output both 4K (landscape 3840x2160 or portrait 2160x3840). The camera is upscaled per-source with MetalFX, overlays render at native 4K.")
                .font(.caption).foregroundStyle(.secondary)
            }
            let errs = draft.validationErrors
            if !errs.isEmpty { Text(errs.joined(separator: "\n")).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Revert") { draft = state.profile.video }
                Button("Apply") { state.profile.video = draft }
                    .disabled(!errs.isEmpty || draft == state.profile.video || (state.engine?.anyOutputActive ?? false))
            }
            if state.engine?.anyOutputActive ?? false {
                Text("Stop recording/streaming/replay to change video settings.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { if !loaded { draft = state.profile.video; loaded = true } }
    }
}

struct OutputSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Recording") {
                HStack {
                    TextField("Folder", text: $state.profile.recording.directory)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { state.profile.recording.directory = u.path }
                    }
                }
                TextField("Filename format (%Y %m %d %H %M %S %SCENE)", text: $state.profile.recording.filenameFormat)
                Picker("Container", selection: $state.profile.recording.container) {
                    ForEach(ContainerFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Video codec", selection: $state.profile.recording.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !state.profile.recording.codec.isProRes {
                    RateControlEditor(rateControl: $state.profile.recording.rateControl)
                    Stepper("Keyframe interval: \(String(format: "%.0f", state.profile.recording.keyframeIntervalSeconds)) s", value: $state.profile.recording.keyframeIntervalSeconds, in: 1...10)
                }
                Picker("Audio bitrate", selection: $state.profile.recording.audioBitrateKbps) {
                    ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Audio track", selection: $state.profile.recording.audioTrack) {
                    ForEach(1...6, id: \.self) { Text("Track \($0)").tag($0) }
                }
                let errs = state.profile.recording.validationErrors
                if !errs.isEmpty { Text(errs.joined(separator: "\n")).foregroundStyle(.red).font(.caption) }
            }
            Section("Replay buffer") {
                Toggle("Enable replay buffer", isOn: $state.profile.replay.enabled)
                Stepper("Length: \(state.profile.replay.seconds) s", value: $state.profile.replay.seconds, in: 5...600, step: 5)
                TextField("Filename prefix", text: $state.profile.replay.filenamePrefix)
                Text("Keeps the last N seconds encoded in memory; Save Replay (default ⌘⇧⌥F1) writes them to the recordings folder.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RateControlEditor: View {
    @Binding var rateControl: RateControl

    var body: some View {
        Picker("Rate control", selection: Binding(get: { rateControl.isBitrate ? 0 : 1 }, set: { rateControl = $0 == 0 ? .bitrate(20_000) : .quality(0.75) })) {
            Text("Bitrate").tag(0)
            Text("Constant quality").tag(1)
        }
        switch rateControl {
        case .bitrate(let kbps):
            HStack {
                TextField("kbps", value: Binding(get: { kbps }, set: { rateControl = .bitrate(max(500, $0)) }), format: .number).frame(width: 100)
                Text("kbps  (4K30 HEVC: 30–50 Mbps, 4K30 H.264: 50–80 Mbps)").font(.caption).foregroundStyle(.secondary)
            }
        case .quality(let q):
            Slider(value: Binding(get: { q }, set: { rateControl = .quality($0) }), in: 0.1...1) { Text("Quality \(String(format: "%.2f", q))") }
        }
    }
}

struct StreamSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var showKey = false

    var body: some View {
        Form {
            Section("Service") {
            Picker("Service", selection: $state.profile.stream.service) {
                ForEach(StreamService.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: state.profile.stream.service) { _, s in
                if let first = s.servers.first, !first.url.isEmpty { state.profile.stream.serverURL = first.url }
            }
            if !state.profile.stream.service.servers.isEmpty, state.profile.stream.service != .kick {
                Picker("Server", selection: $state.profile.stream.serverURL) {
                    ForEach(state.profile.stream.service.servers, id: \.url) { Text($0.name).tag($0.url) }
                    if !state.profile.stream.service.servers.contains(where: { $0.url == state.profile.stream.serverURL }) {
                        Text(state.profile.stream.serverURL).tag(state.profile.stream.serverURL)
                    }
                }
            }
            TextField("Server URL (rtmp:// or rtmps://)", text: $state.profile.stream.serverURL)
            if state.profile.stream.service == .kick { Text(state.profile.stream.service.servers.first?.name ?? "").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if showKey { TextField("Stream key", text: $state.profile.stream.streamKey) } else { SecureField("Stream key", text: $state.profile.stream.streamKey) }
                Button(showKey ? "Hide" : "Show") { showKey.toggle() }
            }
            }
            Section("Encoding") {
            HStack {
                Text("Video bitrate")
                TextField("kbps", value: $state.profile.stream.videoBitrateKbps, format: .number).frame(width: 100)
                Text("kbps").font(.caption)
                if let cap = state.profile.stream.service.recommendedMaxVideoKbps { Text("(\(state.profile.stream.service.label) max ≈ \(cap))").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("Audio bitrate", selection: $state.profile.stream.audioBitrateKbps) {
                ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            Stepper("Keyframe interval: \(String(format: "%.0f", state.profile.stream.keyframeIntervalSeconds)) s", value: $state.profile.stream.keyframeIntervalSeconds, in: 1...10)
            Picker("Stream resolution", selection: Binding(get: { state.profile.stream.scaledSize.map { "\($0.width)x\($0.height)" } ?? "" }, set: { v in
                let parts = v.split(separator: "x").compactMap { Int($0) }
                state.profile.stream.scaledSize = parts.count == 2 ? Size2D(parts[0], parts[1]) : nil
            })) {
                Text("Same as output (\(state.profile.video.outputSize))").tag("")
                ForEach(["1920x1080", "1280x720", "1080x1920", "720x1280", "2560x1440", "1440x2560"], id: \.self) { Text($0).tag($0) }
            }
            Text("Streaming encodes H.264 (what every RTMP ingest accepts). Sending 4K to Twitch is pointless; YouTube accepts it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
            Toggle("Reconnect automatically", isOn: $state.profile.stream.autoReconnect)
            Stepper("Retry delay: \(state.profile.stream.reconnectDelaySeconds) s", value: $state.profile.stream.reconnectDelaySeconds, in: 1...60)
            Picker("Audio track", selection: $state.profile.stream.audioTrack) {
                ForEach(1...6, id: \.self) { Text("Track \($0)").tag($0) }
            }
            }
            let errs = state.profile.stream.validationErrors
            if !errs.isEmpty { Text(errs.joined(separator: "\n")).foregroundStyle(.orange).font(.caption) }
        }
    }
}

struct AudioSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Text("Mix: 48 kHz stereo, 10 ms blocks. Every source is converted to this format on arrival.").font(.caption).foregroundStyle(.secondary)
            Picker("Monitoring device", selection: Binding(get: { state.profile.audio.monitoringDeviceUID ?? "" }, set: { v in
                state.profile.audio.monitoringDeviceUID = v.isEmpty ? nil : v
                state.profile.audio.monitoringDeviceName = state.audioDevices.outputDevices.first { $0.uid == v }?.name
            })) {
                Text("System default output").tag("")
                ForEach(state.audioDevices.outputDevices) { d in Text("\(d.name) (\(d.outputChannels) out)").tag(d.uid) }
            }
            Button("Refresh devices") { state.audioDevices.refresh() }
            Section("Input devices seen right now") {
                ForEach(state.audioDevices.inputDevices) { d in
                    Text("\(d.name): \(d.inputChannels) in / \(d.outputChannels) out, \(Int(d.sampleRate)) Hz\(d.transport.isEmpty ? "" : ", " + d.transport)\(d.isDefaultInput ? "  (default input)" : "")")
                        .font(.caption)
                }
            }
        }
    }
}

struct HotkeysTab: View {
    @EnvironmentObject var state: AppState
    @State private var recording: ControlAction?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Text("Global hotkeys work in any app. Click a field, then press the combination (needs at least one modifier).").font(.caption).foregroundStyle(.secondary)
            ForEach(allActions(), id: \.self) { action in
                HStack {
                    Text(label(action)).frame(width: 260, alignment: .leading)
                    Button(recording == action ? "Press keys…" : (state.profile.hotkeys.binding(for: action)?.combo.displayString ?? "none")) {
                        startRecording(action)
                    }
                    .frame(width: 160)
                    Button("Clear") { state.profile.hotkeys.set(nil, for: action) }.disabled(state.profile.hotkeys.binding(for: action) == nil)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func allActions() -> [ControlAction] {
        var out = ControlAction.global
        for s in state.collection.scenes { out.append(.switchToScene(s.id)) }
        for src in state.collection.sources where src.kind.hasAudio {
            out.append(.toggleMute(src.id))
            out.append(.pushToTalk(src.id))
            out.append(.pushToMute(src.id))
        }
        return out
    }

    private func label(_ a: ControlAction) -> String {
        switch a {
        case .switchToScene(let id): return "Switch to scene: \(state.collection.scene(id)?.name ?? "?")"
        case .toggleMute(let id): return "Mute/Unmute: \(state.collection.source(id)?.name ?? "?")"
        case .pushToTalk(let id): return "Push-to-talk: \(state.collection.source(id)?.name ?? "?")"
        case .pushToMute(let id): return "Push-to-mute: \(state.collection.source(id)?.name ?? "?")"
        default: return a.label
        }
    }

    private func startRecording(_ action: ControlAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var mods = KeyModifiers()
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            if event.keyCode == 53 { // escape cancels
                stopRecording()
                return nil
            }
            let isFunctionKey = (0x60...0x7A).contains(Int(event.keyCode))
            guard !mods.isEmpty || isFunctionKey else { return nil }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            state.profile.hotkeys.set(combo, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }
}

struct MIDITab: View {
    @EnvironmentObject var state: AppState
    @State private var learning: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.midi.isAvailable ? "MIDI sources: \(state.midi.sourceNames.isEmpty ? "none connected" : state.midi.sourceNames.joined(separator: ", "))" : "CoreMIDI unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add binding") {
                    state.profile.midi.append(MIDIBinding(message: .note(60), mode: .trigger, action: .startStopRecording))
                }
            }
            if let e = state.lastMIDIEvent {
                Text("Last MIDI: \(e.device)  ch \(e.channel + 1)  \(e.message.label)").font(.caption.monospaced())
            }
            List {
                ForEach($state.profile.midi) { $b in
                    HStack {
                        Button(learning == b.id ? "Listening… (move a control)" : b.message.label) {
                            learning = b.id
                        }
                        .frame(width: 180)
                        Picker("", selection: $b.mode) {
                            ForEach(MIDITriggerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                        Picker("", selection: $b.action) {
                            ForEach(actions(), id: \.self) { Text(label($0)).tag($0) }
                        }
                        .labelsHidden()
                        Button(action: { state.profile.midi.removeAll { $0.id == b.id } }) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Text("Trigger: fires on note-on / CC ≥ 64. Momentary: note on = press, note off = release (push-to-talk). Continuous: a CC 0–127 drives Set Volume.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: state.lastMIDIEvent?.message) { _, msg in
            guard let id = learning, let e = state.lastMIDIEvent, let msg else { return }
            if let i = state.profile.midi.firstIndex(where: { $0.id == id }) {
                state.profile.midi[i].message = msg
                state.profile.midi[i].channel = e.channel
                state.profile.midi[i].deviceName = e.device
            }
            learning = nil
        }
    }

    private func actions() -> [ControlAction] {
        var out = ControlAction.global
        for s in state.collection.scenes { out.append(.switchToScene(s.id)) }
        for src in state.collection.sources where src.kind.hasAudio {
            out.append(.toggleMute(src.id))
            out.append(.pushToTalk(src.id))
            out.append(.setVolume(src.id))
        }
        return out
    }

    private func label(_ a: ControlAction) -> String {
        switch a {
        case .switchToScene(let id): return "Scene: \(state.collection.scene(id)?.name ?? "?")"
        case .toggleMute(let id): return "Mute: \(state.collection.source(id)?.name ?? "?")"
        case .pushToTalk(let id): return "Push-to-talk: \(state.collection.source(id)?.name ?? "?")"
        case .setVolume(let id): return "Volume: \(state.collection.source(id)?.name ?? "?")"
        default: return a.label
        }
    }
}

struct RemoteTab: View {
    @EnvironmentObject var state: AppState
    @State private var showPassword = false

    var body: some View {
        Form {
            Toggle("Enable obs-websocket compatible server", isOn: $state.profile.remote.enabled)
            TextField("Port", value: $state.profile.remote.port, format: .number).frame(width: 120)
            HStack {
                if showPassword { TextField("Password (blank = none)", text: $state.profile.remote.password) } else { SecureField("Password (blank = none)", text: $state.profile.remote.password) }
                Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }
            }
            Text("Point Stream Deck, Touch Portal, Bitfocus Companion or any obs-websocket 5 client at ws://<this Mac>:\(state.profile.remote.port). Supports scenes, studio mode, mute/volume, stream/record/replay control and scene item visibility.")
                .font(.caption).foregroundStyle(.secondary)
            if state.profile.remote.enabled {
                Text(state.remote.isRunning ? "Listening · \(state.remoteClients) client(s) connected" : "Not listening\(state.remote.lastError.map { ": \($0)" } ?? "")")
                    .foregroundStyle(state.remote.isRunning ? .green : .red)
            }
        }
    }
}
