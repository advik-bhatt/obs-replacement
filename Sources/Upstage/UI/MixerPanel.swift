import SwiftUI
import UpstageCore

struct MixerPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Audio Mixer").padding(8)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.mixerSources) { source in
                        MixerStrip(source: source)
                    }
                    if state.mixerSources.isEmpty {
                        Text("No audio sources in the program scene").foregroundStyle(.secondary).font(.caption).padding()
                    }
                    MasterStrip()
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

struct LevelMeter: View {
    var peakDB: [Double]
    var holdDB: [Double]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<max(1, peakDB.count), id: \.self) { ch in
                GeometryReader { geo in
                    let w = geo.size.width
                    let p = position(peakDB.indices.contains(ch) ? peakDB[ch] : -100)
                    let h = position(holdDB.indices.contains(ch) ? holdDB[ch] : -100)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35))
                        LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing)
                            .mask(alignment: .leading) { Rectangle().frame(width: w * p) }
                        Rectangle().fill(Color.white).frame(width: 2).offset(x: w * h)
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private func position(_ db: Double) -> Double {
        // -60 dB .. 0 dB maps to 0..1
        max(0, min(1, (db + 60) / 60))
    }
}

struct MixerStrip: View {
    @EnvironmentObject var state: AppState
    let source: SourceDescriptor

    var body: some View {
        let levels = state.levels.sources[source.id]
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(source.name).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Text(String(format: "%.1f dB", source.audio.volumeDB)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            LevelMeter(peakDB: levels?.peakDB ?? [-100, -100], holdDB: levels?.holdDB ?? [-100, -100])
            HStack(spacing: 6) {
                Slider(value: Binding(get: { AudioMath.faderPosition(fromDB: source.audio.volumeDB) },
                                      set: { state.setVolume(source.id, db: AudioMath.dB(fromFaderPosition: $0)) }), in: 0...1)
                Button(action: { state.toggleMute(source.id) }) {
                    Image(systemName: source.audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(source.audio.muted ? .red : .primary)
                }
                .buttonStyle(.borderless)
                Menu {
                    Picker("Monitoring", selection: Binding(get: { source.audio.monitoring }, set: { state.setMonitoring(source.id, $0) })) {
                        ForEach(MonitoringMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("Properties…") { state.propertiesSourceID = source.id }
                    Button("Filters…") { state.filtersSourceID = source.id }
                    Menu("Sync Offset") {
                        ForEach([-200, -100, -50, 0, 50, 100, 200, 500], id: \.self) { ms in
                            Button("\(ms) ms\(source.audio.syncOffsetMs == ms ? " ✓" : "")") {
                                var d = source
                                d.audio.syncOffsetMs = ms
                                state.updateSource(d)
                            }
                        }
                    }
                    Menu("Tracks") {
                        ForEach(1...6, id: \.self) { t in
                            Button("Track \(t)\(source.audio.tracks & (1 << (t - 1)) != 0 ? " ✓" : "")") {
                                var d = source
                                d.audio.tracks ^= UInt8(1 << (t - 1))
                                state.updateSource(d)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

struct MasterStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Master").font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f dB", state.levels.master.peakDB.max() ?? -100)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            LevelMeter(peakDB: state.levels.master.peakDB, holdDB: state.levels.master.holdDB)
        }
        .padding(6)
    }
}
