import SwiftUI
import UpstageCore

struct ScenesPanel: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Scenes", trailing: AnyView(HStack(spacing: 4) {
                Button(action: { state.addScene() }) { Image(systemName: "plus") }.buttonStyle(.borderless)
                Button(action: { state.removeScene(state.editingSceneID) }) { Image(systemName: "minus") }.buttonStyle(.borderless)
                    .disabled(state.collection.scenes.count <= 1)
            }))
            .padding(8)
            List(selection: Binding(get: { Optional(state.editingSceneID) }, set: { if let id = $0 { state.selectScene(id) } })) {
                ForEach(state.collection.scenes) { scene in
                    HStack {
                        if renaming == scene.id {
                            TextField("Name", text: $renameText, onCommit: {
                                state.renameScene(scene.id, to: renameText)
                                renaming = nil
                            })
                            .textFieldStyle(.roundedBorder)
                        } else {
                            Text(scene.name)
                            Spacer()
                            if scene.id == state.programSceneID {
                                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red).help("On program")
                            }
                        }
                    }
                    .tag(scene.id)
                    .contextMenu {
                        Button("Rename") { renameText = scene.name; renaming = scene.id }
                        Button("Duplicate") { duplicate(scene) }
                        Divider()
                        Button("Move Up") { if let i = state.collection.sceneIndex(scene.id) { state.moveScene(from: i, to: i - 1) } }
                        Button("Move Down") { if let i = state.collection.sceneIndex(scene.id) { state.moveScene(from: i, to: i + 1) } }
                        Divider()
                        Button("Remove", role: .destructive) { state.removeScene(scene.id) }.disabled(state.collection.scenes.count <= 1)
                    }
                    .onTapGesture(count: 2) { renameText = scene.name; renaming = scene.id }
                }
                .onMove { from, to in
                    guard let f = from.first else { return }
                    state.moveScene(from: f, to: to > f ? to - 1 : to)
                }
            }
            .listStyle(.inset)
        }
    }

    private func duplicate(_ scene: StudioScene) {
        var copy = StudioScene(name: state.collection.uniqueName(scene.name + " copy", existing: state.collection.scenes.map { $0.name }))
        copy.items = scene.items.map { SceneItem(sourceID: $0.sourceID, visible: $0.visible, locked: $0.locked, transform: $0.transform) }
        state.collection.scenes.append(copy)
    }
}

struct SourcesPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Sources (\(state.collection.scene(state.editingSceneID)?.name ?? ""))", trailing: AnyView(HStack(spacing: 4) {
                Button(action: { state.showAddSource = true }) { Image(systemName: "plus") }.buttonStyle(.borderless)
                Button(action: { if let s = state.selectedItemID { state.removeItem(s) } }) { Image(systemName: "minus") }.buttonStyle(.borderless)
                    .disabled(state.selectedItemID == nil)
                Button(action: { if let s = state.selectedItemID { state.moveItem(s, by: 1) } }) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    .disabled(state.selectedItemID == nil)
                Button(action: { if let s = state.selectedItemID { state.moveItem(s, by: -1) } }) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    .disabled(state.selectedItemID == nil)
            }))
            .padding(8)
            List(selection: $state.selectedItemID) {
                // Top of the list = top of the stack, like OBS.
                ForEach((state.editingScene?.items ?? []).reversed()) { item in
                    row(item).tag(item.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if state.editingScene?.items.isEmpty ?? true {
                    VStack(spacing: 6) {
                        Text("No sources yet").foregroundStyle(.secondary)
                        Button("Add a camera, display, audio input…") { state.showAddSource = true }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: SceneItem) -> some View {
        let source = state.collection.source(item.sourceID)
        HStack(spacing: 6) {
            Button(action: { state.toggleVisible(item.id) }) {
                Image(systemName: item.visible ? "eye" : "eye.slash").foregroundStyle(item.visible ? .primary : .secondary)
            }.buttonStyle(.borderless)
            Image(systemName: icon(for: source?.kind)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source?.name ?? "?").lineLimit(1)
                Text(state.engine?.sourceStatus(item.sourceID) ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { state.toggleLocked(item.id) }) {
                Image(systemName: item.locked ? "lock.fill" : "lock.open").foregroundStyle(item.locked ? .primary : .secondary)
            }.buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Properties…") { state.propertiesSourceID = item.sourceID }
            Button("Filters…") { state.filtersSourceID = item.sourceID }
            Button("Transform…") { state.transformItemID = item.id }
            Menu("Fit") {
                Button("Fit to Screen") { state.fitItem(item.id, mode: .fit) }
                Button("Fill Screen") { state.fitItem(item.id, mode: .fill) }
                Button("Stretch to Screen") { state.fitItem(item.id, mode: .stretch) }
                Button("Center (native size)") { state.fitItem(item.id, mode: .center) }
                Button("Reset Transform") { state.resetTransform(item.id) }
            }
            Menu("Rotate") {
                Button("Rotate 90° CW") { rotate(item, by: 90) }
                Button("Rotate 90° CCW") { rotate(item, by: -90) }
                Button("Rotate 180°") { rotate(item, by: 180) }
            }
            Divider()
            Button("Move Up") { state.moveItem(item.id, by: 1) }
            Button("Move Down") { state.moveItem(item.id, by: -1) }
            Divider()
            Button("Remove", role: .destructive) { state.removeItem(item.id) }
        }
        .onTapGesture(count: 2) { state.propertiesSourceID = item.sourceID }
    }

    private func rotate(_ item: SceneItem, by degrees: Double) {
        var it = item
        it.transform.rotation = (it.transform.rotation + degrees).truncatingRemainder(dividingBy: 360)
        state.updateItem(it)
    }

    private func icon(for kind: SourceKind?) -> String {
        switch kind {
        case .camera: return "video"
        case .display: return "display"
        case .window: return "macwindow"
        case .audioInput: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .media: return "film"
        case .image: return "photo"
        case .text: return "textformat"
        case .color: return "paintpalette"
        case nil: return "questionmark"
        }
    }
}

struct AddSourceSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .camera
    @State private var name = ""
    @State private var existing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Source").font(.title2)
            HStack(alignment: .top, spacing: 16) {
                List(SourceKind.allCases, id: \.self, selection: Binding(get: { Optional(kind) }, set: { if let k = $0 { kind = k } })) { k in
                    Label(k.displayName, systemImage: iconName(k)).tag(k)
                }
                .frame(width: 230, height: 260)
                VStack(alignment: .leading, spacing: 8) {
                    Text(description(kind)).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .leading)
                    TextField("Name", text: $name, prompt: Text(kind.displayName))
                    let reusable = state.collection.sources.filter { $0.kind == kind }
                    if !reusable.isEmpty {
                        Divider()
                        Text("Or add an existing source to this scene:").font(.caption)
                        Picker("Existing", selection: $existing) {
                            Text("Create new").tag(UUID?.none)
                            ForEach(reusable) { s in Text(s.name).tag(UUID?.some(s.id)) }
                        }
                    }
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let e = existing { state.addExistingSource(e) } else { state.addSource(kind: kind, name: name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onChange(of: kind) { _, _ in existing = nil }
    }

    private func iconName(_ k: SourceKind) -> String {
        switch k {
        case .camera: return "video"
        case .display: return "display"
        case .window: return "macwindow"
        case .audioInput: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .media: return "film"
        case .image: return "photo"
        case .text: return "textformat"
        case .color: return "paintpalette"
        }
    }

    private func description(_ k: SourceKind) -> String {
        switch k {
        case .camera: return "Any camera: built-in, USB webcam or capture card, iPhone as Continuity Camera (USB or Wi-Fi), or a wired iPhone/iPad screen. Rotate 90° for portrait; the feed is upscaled with MetalFX when drawn larger than its native size."
        case .display: return "Capture an entire display at native resolution through ScreenCaptureKit."
        case .window: return "Capture one window, even when it is behind other windows."
        case .audioInput: return "Any CoreAudio input device with all of its channels: microphones, interfaces, BlackHole 2ch/16ch/64ch, aggregate devices. Route any channels to left/right."
        case .systemAudio: return "Everything the Mac is playing (desktop audio), excluding Upstage itself."
        case .media: return "Play a video or audio file in the scene (loops by default)."
        case .image: return "A PNG, JPEG, HEIC or other still image."
        case .text: return "Rendered text with font, colour, outline and alignment."
        case .color: return "A solid colour block, handy as a background."
        }
    }
}
