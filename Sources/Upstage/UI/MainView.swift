import SwiftUI
import UpstageCore

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let err = state.engineError {
                ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                HStack(spacing: 0) {
                    ScenesPanel().frame(width: 200)
                    Divider()
                    SourcesPanel().frame(minWidth: 260)
                    Divider()
                    MixerPanel().frame(minWidth: 320)
                    Divider()
                    TransitionsPanel().frame(width: 180)
                    Divider()
                    ControlsPanel().frame(width: 190)
                }
                .frame(height: 250)
                Divider()
                StatusBar()
            }
        }
        .sheet(isPresented: $state.showAddSource) { AddSourceSheet().environmentObject(state) }
        .sheet(item: sheet($state.propertiesSourceID)) { s in SourcePropertiesView(sourceID: s.id).environmentObject(state) }
        .sheet(item: sheet($state.filtersSourceID)) { s in FiltersView(sourceID: s.id).environmentObject(state) }
        .sheet(item: sheet($state.transformItemID)) { s in TransformView(itemID: s.id).environmentObject(state) }
        .alert(item: $state.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
    }

    @ViewBuilder private var previewArea: some View {
        if state.studioMode {
            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Text("Preview: \(state.collection.scene(state.editingSceneID)?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                    PreviewView(mode: .preview)
                }
                VStack(spacing: 4) {
                    Text("Program: \(state.collection.scene(state.programSceneID)?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                    PreviewView(mode: .program)
                }
            }
            .padding(8)
        } else {
            PreviewView(mode: .program).padding(8)
        }
    }
}

struct SheetID: Identifiable {
    let id: UUID
}

/// Bridges an optional UUID to the Identifiable item `.sheet(item:)` wants.
func sheet(_ binding: Binding<UUID?>) -> Binding<SheetID?> {
    Binding(get: { binding.wrappedValue.map { SheetID(id: $0) } }, set: { binding.wrappedValue = $0?.id })
}

struct TransitionsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Scene Transitions")
            Picker("", selection: Binding(get: { state.collection.transition.kind }, set: { state.collection.transition.kind = $0 })) {
                ForEach(TransitionKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            HStack {
                Text("Duration").font(.caption)
                TextField("ms", value: Binding(get: { state.collection.transition.durationMs }, set: { state.collection.transition.durationMs = max(0, min(10_000, $0)) }), format: .number)
                    .frame(width: 60)
                Text("ms").font(.caption)
            }
            .disabled(state.collection.transition.kind == .cut)
            Button(action: { state.transition() }) {
                Text("Transition").frame(maxWidth: .infinity)
            }
            .disabled(!state.studioMode)
            .help(state.studioMode ? "Send the preview scene to program" : "Enable Studio Mode to use the transition button")
            Spacer()
        }
        .padding(8)
    }
}

struct ControlsPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 6) {
            PanelHeader(title: "Controls")
            Button(action: { state.toggleStreaming() }) {
                Text(streamLabel).frame(maxWidth: .infinity)
            }
            .tint(state.isStreaming ? .red : nil)
            Button(action: { state.toggleRecording() }) {
                Text(state.isRecording ? "Stop Recording" : "Start Recording").frame(maxWidth: .infinity)
            }
            .tint(state.isRecording ? .red : nil)
            if state.isRecording {
                Button(action: { state.pauseResumeRecording() }) {
                    Text(state.recordingPaused ? "Resume" : "Pause").frame(maxWidth: .infinity)
                }
            }
            Button(action: { state.replayActive ? state.saveReplay() : state.toggleReplayBuffer() }) {
                Text(state.replayActive ? "Save Replay" : "Start Replay Buffer").frame(maxWidth: .infinity)
            }
            .contextMenu {
                if state.replayActive { Button("Stop Replay Buffer") { state.stopReplayBuffer() } }
            }
            Button(action: {}) { Text("Start Virtual Camera").frame(maxWidth: .infinity) }
                .disabled(true)
                .help("Virtual camera needs a signed system extension; not available in this build yet.")
            Button(action: { state.toggleStudioMode() }) {
                Text(state.studioMode ? "Exit Studio Mode" : "Studio Mode").frame(maxWidth: .infinity)
            }
            Button(action: { openSettings() }) { Text("Settings").frame(maxWidth: .infinity) }
            Spacer()
        }
        .padding(8)
    }

    private var streamLabel: String {
        switch state.streamState {
        case .connecting: return "Connecting…"
        case .reconnecting(let n): return "Reconnecting (\(n))…"
        default: return state.isStreaming ? "Stop Streaming" : "Start Streaming"
        }
    }
}

struct PanelHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            if state.isStreaming {
                Label(streamText, systemImage: "dot.radiowaves.left.and.right").foregroundStyle(streamColor)
            }
            if state.isRecording {
                Label("REC \(timecode(state.recordingDuration))\(state.recordingPaused ? " (paused)" : "")", systemImage: "record.circle").foregroundStyle(.red)
            }
            if state.replayActive { Label("Replay", systemImage: "arrow.counterclockwise.circle") }
            Spacer()
            Text("\(state.profile.video.baseSize) → \(state.profile.video.outputSize) @ \(String(format: "%.4g", state.profile.video.frameRate))")
            Text(state.stats.metalFX ? "MetalFX" : "Lanczos").foregroundStyle(state.stats.metalFX ? .green : .orange)
            Text(String(format: "%.1f fps", state.stats.fps))
            Text(String(format: "render %.1f ms / gpu %.1f ms", state.stats.renderMilliseconds, state.stats.gpuMilliseconds))
            if state.stats.droppedFrames > 0 { Text("dropped \(state.stats.droppedFrames)").foregroundStyle(.orange) }
            if state.profile.remote.enabled { Text("Remote: \(state.remoteClients) client\(state.remoteClients == 1 ? "" : "s")") }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var streamText: String {
        switch state.streamState {
        case .live: return String(format: "LIVE %@  %.0f kbps  drop %d", timecode(state.streamStats.uptimeSeconds), state.streamStats.bitrateKbps, state.streamStats.framesDropped)
        case .connecting: return "Connecting"
        case .reconnecting(let n): return "Reconnecting (\(n))"
        case .failed(let s): return "Failed: \(s)"
        default: return "Stream"
        }
    }

    private var streamColor: Color {
        switch state.streamState {
        case .live: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}

func timecode(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
