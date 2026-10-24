import SwiftUI
import UpstageCore

struct TransformView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID

    var body: some View {
        if let item = state.item(itemID) {
            let binding = Binding<Transform>(get: { state.item(itemID)?.transform ?? .identity },
                                             set: { var it = item; it.transform = $0; state.updateItem(it) })
            VStack(alignment: .leading, spacing: 10) {
                Text("Transform: \(state.collection.source(item.sourceID)?.name ?? "")").font(.title3)
                Form {
                    HStack {
                        Text("Position (centre)")
                        TextField("x", value: binding.position.x, format: .number.precision(.fractionLength(0))).frame(width: 80)
                        TextField("y", value: binding.position.y, format: .number.precision(.fractionLength(0))).frame(width: 80)
                    }
                    HStack {
                        Text("Scale")
                        TextField("x", value: Binding(get: { binding.wrappedValue.scale.x * 100 }, set: { binding.wrappedValue.scale.x = max(0.01, $0 / 100) }), format: .number.precision(.fractionLength(1))).frame(width: 80)
                        TextField("y", value: Binding(get: { binding.wrappedValue.scale.y * 100 }, set: { binding.wrappedValue.scale.y = max(0.01, $0 / 100) }), format: .number.precision(.fractionLength(1))).frame(width: 80)
                        Text("%")
                    }
                    if let size = state.displayedSize(ofSource: item.sourceID) {
                        let r = binding.wrappedValue.renderedSize(for: size)
                        Text("Source \(size) → drawn \(Int(r.x))x\(Int(r.y)) px").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Rotation")
                        TextField("deg", value: binding.rotation, format: .number.precision(.fractionLength(1))).frame(width: 80)
                        Text("°")
                        Button("0") { binding.wrappedValue.rotation = 0 }
                        Button("90") { binding.wrappedValue.rotation = 90 }
                        Button("180") { binding.wrappedValue.rotation = 180 }
                        Button("270") { binding.wrappedValue.rotation = 270 }
                    }
                    HStack {
                        Text("Crop (px)")
                        TextField("L", value: binding.crop.left, format: .number).frame(width: 60)
                        TextField("T", value: binding.crop.top, format: .number).frame(width: 60)
                        TextField("R", value: binding.crop.right, format: .number).frame(width: 60)
                        TextField("B", value: binding.crop.bottom, format: .number).frame(width: 60)
                    }
                    Slider(value: binding.opacity, in: 0...1) { Text("Opacity") }
                    HStack {
                        Toggle("Flip horizontal", isOn: binding.flipHorizontal)
                        Toggle("Flip vertical", isOn: binding.flipVertical)
                    }
                    HStack {
                        Button("Fit to Screen") { state.fitItem(itemID, mode: .fit) }
                        Button("Fill Screen") { state.fitItem(itemID, mode: .fill) }
                        Button("Stretch") { state.fitItem(itemID, mode: .stretch) }
                        Button("Native / Centre") { state.fitItem(itemID, mode: .center) }
                        Button("Reset") { state.resetTransform(itemID) }
                    }
                    Text("Portrait tip: for a 16:9 camera on a 9:16 canvas, crop left/right to 420 each (a 1920-wide feed becomes 1080) or rotate the source 90° in its Properties if the phone is mounted vertically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 560)
        } else {
            Text("Item no longer exists").padding()
        }
    }
}
