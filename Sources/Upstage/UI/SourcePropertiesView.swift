import AppKit
import SwiftUI
import UpstageCore

struct SourcePropertiesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID

    private var source: SourceDescriptor? { state.collection.source(sourceID) }

    var body: some View {
        if let source {
            let binding = Binding<SourceDescriptor>(get: { state.collection.source(sourceID) ?? source }, set: { state.updateSource($0) })
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Properties").font(.title3)
                    Spacer()
                    Text(state.engine?.sourceStatus(sourceID) ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Form {
                    TextField("Name", text: binding.name)
                    switch source.settings {
                    case .camera(let s): CameraProperties(source: binding, settings: s)
                    case .display(let s): DisplayProperties(source: binding, settings: s)
                    case .window(let s): WindowProperties(source: binding, settings: s)
                    case .audioInput(let s): AudioInputProperties(source: binding, settings: s)
                    case .systemAudio(let s):
                        Toggle("Exclude Upstage's own audio", isOn: Binding(get: { s.excludeOwnProcess }, set: { binding.wrappedValue.settings = .systemAudio(SystemAudioSettings(excludeOwnProcess: $0)) }))
                        Text("Needs Screen Recording permission (System Settings > Privacy & Security).").font(.caption).foregroundStyle(.secondary)
                    case .media(let s): MediaProperties(source: binding, settings: s)
                    case .image(let s):
                        FilePickerRow(label: "Image file", path: s.path, types: ["public.image"]) { binding.wrappedValue.settings = .image(ImageSettings(path: $0)) }
                    case .text(let s): TextProperties(source: binding, settings: s)
                    case .color(let s): ColorProperties(source: binding, settings: s)
                    }
                    if source.kind.hasVideo {
                        Picker("Upscaling", selection: binding.upscale) {
                            ForEach(UpscaleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Text(state.stats.metalFX ? "MetalFX spatial upscaling is available on this GPU." : "MetalFX is not supported on this GPU; Lanczos is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if source.kind.hasAudio {
                        Stepper("Audio sync offset: \(binding.wrappedValue.audio.syncOffsetMs) ms", value: binding.audio.syncOffsetMs, in: -2000...2000, step: 10)
                    }
                }
                HStack {
                    Button("Filters…") { dismiss(); DispatchQueue.main.async { state.filtersSourceID = sourceID } }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 640)
        } else {
            Text("Source no longer exists").padding()
        }
    }
}

struct FilePickerRow: View {
    let label: String
    let path: String?
    let types: [String]
    let onPick: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "none").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
            }
        }
    }
}

struct CameraProperties: View {
    @EnvironmentObject var state: AppState
    @Binding var source: SourceDescriptor
    let settings: CameraSettings

    private func set(_ f: (inout CameraSettings) -> Void) {
        var s = settings
        f(&s)
        source.settings = .camera(s)
    }

    var body: some View {
        let devices = state.videoDevices.devices
        Picker("Device", selection: Binding(get: { settings.deviceUniqueID ?? "" }, set: { id in
            set { s in
                s.deviceUniqueID = id.isEmpty ? nil : id
                s.deviceName = devices.first { $0.uniqueID == id }?.name
                s.preferredSize = nil
            }
        })) {
            Text("System preferred camera").tag("")
            ForEach(devices) { d in
                Text("\(d.name)  [\(d.kind.rawValue)\(d.transport.isEmpty ? "" : ", " + d.transport)]").tag(d.uniqueID)
            }
        }
        HStack {
            Button("Refresh devices") { state.videoDevices.refresh() }
            if !state.cameraAuthorized { Text("Camera access not granted (System Settings > Privacy & Security > Camera)").font(.caption).foregroundStyle(.red) }
        }
        if let d = devices.first(where: { $0.uniqueID == settings.deviceUniqueID }) {
            Picker("Resolution / FPS", selection: Binding(get: { settings.preferredSize.map { "\($0.width)x\($0.height)" } ?? "" }, set: { v in
                set { s in
                    if v.isEmpty { s.preferredSize = nil } else {
                        let parts = v.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { s.preferredSize = Size2D(parts[0], parts[1]) }
                    }
                }
            })) {
                Text("Highest available").tag("")
                ForEach(Array(Set(d.formats.map { "\($0.width)x\($0.height)" })).sorted { a, b in
                    let pa = a.split(separator: "x").compactMap { Int($0) }, pb = b.split(separator: "x").compactMap { Int($0) }
                    return (pa.first ?? 0) * (pa.last ?? 0) > (pb.first ?? 0) * (pb.last ?? 0)
                }, id: \.self) { v in
                    let maxFPS = d.formats.filter { "\($0.width)x\($0.height)" == v }.map(\.maxFrameRate).max() ?? 0
                    Text("\(v)  (up to \(String(format: "%.4g", maxFPS)) fps)").tag(v)
                }
            }
            if d.kind == .continuityCamera {
                Text("Continuity Camera delivers up to \(d.maxFormat.map { "\($0.width)x\($0.height)" } ?? "1080p"); Upstage upscales it to the canvas with MetalFX. Works over USB and Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if d.kind == .iosDevice {
                Text("Wired iPhone/iPad screen capture (same path QuickTime uses). Enable 'Capture audio from this device' for its sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Picker("Frame rate", selection: Binding(get: { settings.preferredFrameRate ?? 0 }, set: { v in set { $0.preferredFrameRate = v == 0 ? nil : v } })) {
            Text("Match canvas").tag(0.0)
            ForEach(VideoSettings.commonFrameRates, id: \.self) { Text(String(format: "%.4g", $0)).tag($0) }
        }
        Picker("Rotation", selection: Binding(get: { settings.rotation }, set: { v in set { $0.rotation = v } })) {
            ForEach(Rotation.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Text("Use 90°/270° when the iPhone is mounted vertically, so a 1920x1080 feed becomes 1080x1920 for a portrait canvas.").font(.caption).foregroundStyle(.secondary)
        Toggle("Mirror horizontally", isOn: Binding(get: { settings.mirror }, set: { v in set { $0.mirror = v } }))
        Toggle("Capture audio from this device (wired iPhone screen, capture cards)", isOn: Binding(get: { settings.captureAudio }, set: { v in set { $0.captureAudio = v } }))
    }
}

struct DisplayProperties: View {
    @EnvironmentObject var state: AppState
    @Binding var source: SourceDescriptor
    let settings: DisplaySettings

    var body: some View {
        Picker("Display", selection: Binding(get: { settings.displayID ?? 0 }, set: { v in
            var s = settings; s.displayID = v == 0 ? nil : v; source.settings = .display(s)
        })) {
            Text("Main display").tag(UInt32(0))
            ForEach(state.displays) { d in Text(d.label).tag(d.displayID) }
        }
        Toggle("Show cursor", isOn: Binding(get: { settings.showCursor }, set: { v in var s = settings; s.showCursor = v; source.settings = .display(s) }))
        Picker("Frame rate", selection: Binding(get: { settings.frameRate }, set: { v in var s = settings; s.frameRate = v; source.settings = .display(s) })) {
            ForEach([15.0, 24, 30, 60], id: \.self) { Text(String(format: "%.0f", $0)).tag($0) }
        }
        Button("Refresh displays") { state.refreshShareableContent() }
    }
}

struct WindowProperties: View {
    @EnvironmentObject var state: AppState
    @Binding var source: SourceDescriptor
    let settings: WindowSettings

    var body: some View {
        Picker("Window", selection: Binding(get: { settings.windowID ?? 0 }, set: { v in
            var s = settings
            s.windowID = v == 0 ? nil : v
            if let w = state.windows.first(where: { $0.windowID == v }) { s.ownerName = w.ownerName; s.title = w.title }
            source.settings = .window(s)
        })) {
            Text("Choose a window…").tag(UInt32(0))
            ForEach(state.windows) { w in Text(w.label).tag(w.windowID) }
        }
        Toggle("Show cursor", isOn: Binding(get: { settings.showCursor }, set: { v in var s = settings; s.showCursor = v; source.settings = .window(s) }))
        Picker("Frame rate", selection: Binding(get: { settings.frameRate }, set: { v in var s = settings; s.frameRate = v; source.settings = .window(s) })) {
            ForEach([15.0, 24, 30, 60], id: \.self) { Text(String(format: "%.0f", $0)).tag($0) }
        }
        Button("Refresh windows") { state.refreshShareableContent() }
    }
}

struct AudioInputProperties: View {
    @EnvironmentObject var state: AppState
    @Binding var source: SourceDescriptor
    let settings: AudioInputSettings

    var body: some View {
        let devices = state.audioDevices.inputDevices
        Picker("Device", selection: Binding(get: { settings.deviceUID ?? "" }, set: { uid in
            var s = settings
            s.deviceUID = uid.isEmpty ? nil : uid
            if let d = devices.first(where: { $0.uid == uid }) {
                s.deviceName = d.name
                s.channelMatrix = s.channelMatrix.resized(toInputChannels: d.inputChannels)
            }
            source.settings = .audioInput(s)
        })) {
            Text("Default input").tag("")
            ForEach(devices) { d in
                Text("\(d.name)  [\(d.inputChannels) ch, \(Int(d.sampleRate)) Hz\(d.transport.isEmpty ? "" : ", " + d.transport)]").tag(d.uid)
            }
        }
        HStack {
            Button("Refresh devices") { state.audioDevices.refresh() }
            if !state.microphoneAuthorized { Text("Microphone access not granted").font(.caption).foregroundStyle(.red) }
        }
        let liveChannels = state.engine?.audioInputChannels(source.id) ?? 0
        let channels = max(liveChannels, settings.channelMatrix.inputChannels, devices.first { $0.uid == settings.deviceUID }?.inputChannels ?? 0, 2)
        let matrix = settings.channelMatrix.resized(toInputChannels: channels)
        Text("Channel routing (\(channels) device channels → L / R)").font(.caption.weight(.semibold))
        HStack {
            Button("Default (1→L, 2→R)") { apply(.defaultMapping(inputChannels: channels)) }
            Button("Sum all to both") { apply(.sumAll(inputChannels: channels)) }
            Button("Clear") { apply(ChannelMatrix(inputChannels: channels)) }
        }
        ScrollView(.horizontal) {
            Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 2) {
                GridRow {
                    Text("").frame(width: 24)
                    ForEach(0..<channels, id: \.self) { i in Text("\(i + 1)").font(.caption2).frame(width: 22) }
                }
                ForEach(0..<2, id: \.self) { out in
                    GridRow {
                        Text(out == 0 ? "L" : "R").font(.caption.weight(.semibold)).frame(width: 24)
                        ForEach(0..<channels, id: \.self) { i in
                            Toggle("", isOn: Binding(get: { matrix.isRouted(input: i, output: out) }, set: { on in
                                var m = matrix
                                m.setRouted(input: i, output: out, on)
                                apply(m)
                            }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .frame(width: 22)
                        }
                    }
                }
            }
        }
        Text("Example: BlackHole 16ch carrying a DAW's stems → tick the channels you want in the stream; everything else stays silent.").font(.caption).foregroundStyle(.secondary)
    }

    private func apply(_ m: ChannelMatrix) {
        var s = settings
        s.channelMatrix = m
        source.settings = .audioInput(s)
    }
}

struct MediaProperties: View {
    @Binding var source: SourceDescriptor
    let settings: MediaSettings

    var body: some View {
        FilePickerRow(label: "Media file", path: settings.path, types: ["public.movie", "public.audio"]) { p in var s = settings; s.path = p; source.settings = .media(s) }
        Toggle("Loop", isOn: Binding(get: { settings.loop }, set: { v in var s = settings; s.loop = v; source.settings = .media(s) }))
        Toggle("Restart playback when the scene becomes active", isOn: Binding(get: { settings.restartWhenActivated }, set: { v in var s = settings; s.restartWhenActivated = v; source.settings = .media(s) }))
    }
}

struct TextProperties: View {
    @Binding var source: SourceDescriptor
    let settings: TextSettings

    private func set(_ f: (inout TextSettings) -> Void) {
        var s = settings
        f(&s)
        source.settings = .text(s)
    }

    var body: some View {
        TextEditor(text: Binding(get: { settings.text }, set: { v in set { $0.text = v } })).frame(height: 80).font(.body)
        Picker("Font", selection: Binding(get: { settings.fontName }, set: { v in set { $0.fontName = v } })) {
            ForEach(["Helvetica-Bold", "Helvetica", "HelveticaNeue-Bold", "AvenirNext-Bold", "Futura-Bold", "Menlo-Bold", "Georgia-Bold", "Impact", "SFPro-Bold"], id: \.self) { Text($0).tag($0) }
            if !["Helvetica-Bold", "Helvetica", "HelveticaNeue-Bold", "AvenirNext-Bold", "Futura-Bold", "Menlo-Bold", "Georgia-Bold", "Impact", "SFPro-Bold"].contains(settings.fontName) {
                Text(settings.fontName).tag(settings.fontName)
            }
        }
        TextField("Font name (any installed PostScript name)", text: Binding(get: { settings.fontName }, set: { v in set { $0.fontName = v } }))
        Slider(value: Binding(get: { settings.fontSize }, set: { v in set { $0.fontSize = v } }), in: 8...400) { Text("Size \(Int(settings.fontSize))") }
        ColorPicker("Colour", selection: Binding(get: { Color(rgba: settings.color) }, set: { v in set { $0.color = v.rgba } }))
        ColorPicker("Background", selection: Binding(get: { Color(rgba: settings.backgroundColor) }, set: { v in set { $0.backgroundColor = v.rgba } }))
        Picker("Alignment", selection: Binding(get: { settings.alignment }, set: { v in set { $0.alignment = v } })) {
            ForEach(TextAlignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Slider(value: Binding(get: { settings.outlineWidth }, set: { v in set { $0.outlineWidth = v } }), in: 0...20) { Text("Outline \(Int(settings.outlineWidth))") }
        ColorPicker("Outline colour", selection: Binding(get: { Color(rgba: settings.outlineColor) }, set: { v in set { $0.outlineColor = v.rgba } }))
        Stepper("Wrap width: \(settings.wrapWidth == 0 ? "auto" : "\(settings.wrapWidth) px")", value: Binding(get: { settings.wrapWidth }, set: { v in set { $0.wrapWidth = max(0, v) } }), in: 0...8192, step: 100)
    }
}

struct ColorProperties: View {
    @Binding var source: SourceDescriptor
    let settings: ColorSettings

    var body: some View {
        ColorPicker("Colour", selection: Binding(get: { Color(rgba: settings.color) }, set: { v in var s = settings; s.color = v.rgba; source.settings = .color(s) }))
        HStack {
            Text("Size")
            TextField("w", value: Binding(get: { settings.size.width }, set: { v in var s = settings; s.size.width = max(1, v); source.settings = .color(s) }), format: .number).frame(width: 80)
            TextField("h", value: Binding(get: { settings.size.height }, set: { v in var s = settings; s.size.height = max(1, v); source.settings = .color(s) }), format: .number).frame(width: 80)
        }
    }
}

extension Color {
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    var rgba: RGBA {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return RGBA(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}
