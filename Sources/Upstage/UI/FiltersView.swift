import SwiftUI
import UpstageCore

struct FiltersView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var selected: UUID?

    private var source: SourceDescriptor? { state.collection.source(sourceID) }

    var body: some View {
        if let source {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Filters: \(source.name)").font(.headline)
                        Spacer()
                        Menu {
                            ForEach(Array(FilterType.allDefaults.enumerated()), id: \.offset) { _, t in
                                Button(t.displayName) { state.addFilter(t, to: sourceID) }
                            }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).frame(width: 30)
                        Button(action: { if let s = selected { state.removeFilter(s, from: sourceID); selected = nil } }) { Image(systemName: "minus") }
                            .buttonStyle(.borderless).disabled(selected == nil)
                        Button(action: { if let s = selected { state.moveFilter(s, in: sourceID, by: -1) } }) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button(action: { if let s = selected { state.moveFilter(s, in: sourceID, by: 1) } }) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    }
                    List(selection: $selected) {
                        ForEach(source.filters) { f in
                            HStack {
                                Toggle("", isOn: Binding(get: { f.enabled }, set: { v in var g = f; g.enabled = v; state.updateFilter(g, in: sourceID) })).labelsHidden()
                                Text(f.name)
                            }
                            .tag(f.id)
                        }
                    }
                    .frame(width: 220, height: 300)
                }
                Divider()
                VStack(alignment: .leading) {
                    if let sel = selected, let f = source.filters.first(where: { $0.id == sel }) {
                        FilterEditor(filter: Binding(get: { source.filters.first { $0.id == sel } ?? f }, set: { state.updateFilter($0, in: sourceID) }))
                    } else {
                        Text("Select a filter, or add one with +").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(minWidth: 360)
            }
            .padding(20)
            .frame(width: 680)
            .overlay(alignment: .bottomTrailing) { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding(20) }
            .frame(height: 400)
        } else {
            Text("Source no longer exists").padding()
        }
    }
}

struct FilterEditor: View {
    @Binding var filter: FilterDescriptor

    var body: some View {
        Form {
            TextField("Name", text: $filter.name)
            switch filter.type {
            case .colorCorrection(let c):
                let b = Binding(get: { c }, set: { filter.type = .colorCorrection($0) })
                Slider(value: b.brightness, in: -1...1) { Text("Brightness \(String(format: "%.2f", c.brightness))") }
                Slider(value: b.contrast, in: 0...4) { Text("Contrast \(String(format: "%.2f", c.contrast))") }
                Slider(value: b.saturation, in: 0...4) { Text("Saturation \(String(format: "%.2f", c.saturation))") }
                Slider(value: b.gamma, in: 0.1...4) { Text("Gamma \(String(format: "%.2f", c.gamma))") }
                Slider(value: b.hueShift, in: -180...180) { Text("Hue \(Int(c.hueShift))°") }
                Slider(value: b.opacity, in: 0...1) { Text("Opacity \(String(format: "%.2f", c.opacity))") }
                Button("Reset") { filter.type = .colorCorrection(ColorCorrectionFilter()) }
            case .chromaKey(let k):
                let b = Binding(get: { k }, set: { filter.type = .chromaKey($0) })
                ColorPicker("Key colour", selection: Binding(get: { Color(rgba: k.keyColor) }, set: { b.wrappedValue.keyColor = $0.rgba }))
                HStack {
                    Button("Green") { b.wrappedValue.keyColor = .chromaGreen }
                    Button("Blue") { b.wrappedValue.keyColor = RGBA(r: 0, g: 0, b: 1) }
                    Button("Magenta") { b.wrappedValue.keyColor = RGBA(r: 1, g: 0, b: 1) }
                }
                Slider(value: b.similarity, in: 0...1) { Text("Similarity \(String(format: "%.2f", k.similarity))") }
                Slider(value: b.smoothness, in: 0...1) { Text("Smoothness \(String(format: "%.2f", k.smoothness))") }
                Slider(value: b.spillReduction, in: 0...1) { Text("Spill reduction \(String(format: "%.2f", k.spillReduction))") }
            case .lumaKey(let k):
                let b = Binding(get: { k }, set: { filter.type = .lumaKey($0) })
                Slider(value: b.lumaMin, in: 0...1) { Text("Luma min \(String(format: "%.2f", k.lumaMin))") }
                Slider(value: b.lumaMax, in: 0...1) { Text("Luma max \(String(format: "%.2f", k.lumaMax))") }
                Slider(value: b.smooth, in: 0...0.5) { Text("Smooth \(String(format: "%.2f", k.smooth))") }
            case .sharpen(let s):
                Slider(value: Binding(get: { s.amount }, set: { filter.type = .sharpen(SharpenFilter(amount: $0)) }), in: 0...1) { Text("Amount \(String(format: "%.2f", s.amount))") }
            case .blur(let bl):
                Slider(value: Binding(get: { bl.radius }, set: { filter.type = .blur(BlurFilter(radius: $0)) }), in: 0...64) { Text("Radius \(Int(bl.radius)) px") }
            case .cropPad(let cp):
                let b = Binding(get: { cp.crop }, set: { filter.type = .cropPad(CropPadFilter(crop: $0)) })
                HStack {
                    TextField("Left", value: b.left, format: .number)
                    TextField("Top", value: b.top, format: .number)
                    TextField("Right", value: b.right, format: .number)
                    TextField("Bottom", value: b.bottom, format: .number)
                }
                Text("Pixels removed from each edge of the source.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
