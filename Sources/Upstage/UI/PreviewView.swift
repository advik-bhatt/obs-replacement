import MetalKit
import SwiftUI
import UpstageCore

/// MTKView that draws the engine's program or preview texture aspect-fitted.
final class PreviewMetalView: MTKView {
    weak var engine: Engine?
    var showPreview = false

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        colorPixelFormat = Renderer.pixelFormat
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        framebufferOnly = true
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let engine, let drawable = currentDrawable, let cb = engine.renderer.commandQueue.makeCommandBuffer() else { return }
        let texture = showPreview ? engine.previewTextureForDisplay() : engine.programTextureForDisplay()
        engine.renderer.drawFitted(cb, texture: texture, into: drawable.texture)
        cb.present(drawable)
        cb.commit()
    }
}

struct MetalPreview: NSViewRepresentable {
    let engine: Engine?
    let showPreview: Bool

    func makeNSView(context: Context) -> PreviewMetalView {
        let v = PreviewMetalView(frame: .zero, device: engine?.device)
        v.engine = engine
        v.showPreview = showPreview
        return v
    }

    func updateNSView(_ nsView: PreviewMetalView, context: Context) {
        nsView.engine = engine
        nsView.showPreview = showPreview
    }
}

/// The preview with selection, drag-to-move and corner-drag-to-scale.
struct PreviewView: View {
    enum Mode { case program, preview }
    let mode: Mode
    @EnvironmentObject var state: AppState
    @State private var dragStart: (item: SceneItem, point: Vec2, handle: Int?)?

    private var editable: Bool { mode == .preview || !state.studioMode }

    var body: some View {
        GeometryReader { geo in
            let canvas = state.canvasSize
            let fit = Renderer.fitRect(content: canvas, in: Size2D(Int(geo.size.width), Int(geo.size.height)))
            let scale = canvas.width > 0 ? fit.size.x / Double(canvas.width) : 1
            ZStack(alignment: .topLeading) {
                MetalPreview(engine: state.engine, showPreview: mode == .preview)
                if editable, let sel = state.selectedItemID, let item = state.item(sel), let size = state.displayedSize(ofSource: item.sourceID) {
                    selectionOverlay(item: item, size: size, fit: fit, scale: scale)
                }
                if state.profile.general.showPreviewSafeAreas {
                    Rectangle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: fit.size.x * 0.9, height: fit.size.y * 0.9)
                        .offset(x: fit.origin.x + fit.size.x * 0.05, y: fit.origin.y + fit.size.y * 0.05)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(fit: fit, scale: scale))
                    .onTapGesture(count: 2) {
                        if let sel = state.selectedItemID { state.fitItem(sel, mode: .fit) }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onDeleteCommand { if editable, let sel = state.selectedItemID { state.removeItem(sel) } }
        .onMoveCommand { dir in
            guard editable, let sel = state.selectedItemID, var it = state.item(sel), !it.locked else { return }
            switch dir {
            case .left: it.transform.position.x -= 1
            case .right: it.transform.position.x += 1
            case .up: it.transform.position.y -= 1
            case .down: it.transform.position.y += 1
            default: break
            }
            state.updateItem(it)
        }
        .focusable()
    }

    private func corners(of item: SceneItem, size: Size2D) -> [Vec2] {
        let t = item.transform
        let s = t.renderedSize(for: size)
        let r = t.rotation * .pi / 180
        let c = cos(r), sn = sin(r)
        let hw = s.x / 2, hh = s.y / 2
        return [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map { p in
            Vec2(t.position.x + p.x * c - p.y * sn, t.position.y + p.x * sn + p.y * c)
        }
    }

    @ViewBuilder private func selectionOverlay(item: SceneItem, size: Size2D, fit: Rect2D, scale: Double) -> some View {
        let pts = corners(of: item, size: size).map { CGPoint(x: fit.origin.x + $0.x * scale, y: fit.origin.y + $0.y * scale) }
        Path { p in
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            p.closeSubpath()
        }
        .stroke(item.locked ? Color.gray : Color.accentColor, lineWidth: 2)
        if !item.locked {
            ForEach(0..<4, id: \.self) { i in
                Rectangle().fill(Color.accentColor).frame(width: 10, height: 10)
                    .position(pts[i])
            }
        }
    }

    private func hitTest(_ canvasPoint: Vec2) -> SceneItem? {
        guard let scene = state.editingScene else { return nil }
        for it in scene.items.reversed() where it.visible && !it.locked {
            guard let size = state.displayedSize(ofSource: it.sourceID) else { continue }
            if it.transform.boundingBox(for: size).contains(canvasPoint) { return it }
        }
        return nil
    }

    private func handleHit(_ viewPoint: CGPoint, item: SceneItem, fit: Rect2D, scale: Double) -> Int? {
        guard let size = state.displayedSize(ofSource: item.sourceID) else { return nil }
        let pts = corners(of: item, size: size).map { CGPoint(x: fit.origin.x + $0.x * scale, y: fit.origin.y + $0.y * scale) }
        for (i, p) in pts.enumerated() where hypot(p.x - viewPoint.x, p.y - viewPoint.y) <= 9 { return i }
        return nil
    }

    private func dragGesture(fit: Rect2D, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard editable, scale > 0 else { return }
                let toCanvas = { (p: CGPoint) -> Vec2 in Vec2((p.x - fit.origin.x) / scale, (p.y - fit.origin.y) / scale) }
                if dragStart == nil {
                    let start = toCanvas(value.startLocation)
                    if let sel = state.selectedItemID, let it = state.item(sel), !it.locked,
                       let h = handleHit(value.startLocation, item: it, fit: fit, scale: scale) {
                        dragStart = (it, start, h)
                    } else if let hit = hitTest(start) {
                        state.selectedItemID = hit.id
                        dragStart = (hit, start, nil)
                    } else {
                        state.selectedItemID = nil
                        dragStart = nil
                        return
                    }
                }
                guard let ds = dragStart, var it = state.item(ds.item.id), let size = state.displayedSize(ofSource: it.sourceID) else { return }
                let now = toCanvas(value.location)
                if ds.handle != nil {
                    let center = ds.item.transform.position
                    let d0 = max(1, hypot(ds.point.x - center.x, ds.point.y - center.y))
                    let d1 = hypot(now.x - center.x, now.y - center.y)
                    let f = max(0.02, d1 / d0)
                    it.transform.scale = Vec2(ds.item.transform.scale.x * f, ds.item.transform.scale.y * f)
                } else {
                    var pos = ds.item.transform.position + (now - ds.point)
                    if state.profile.general.snapToEdges {
                        pos = snap(pos, item: it, size: size)
                    }
                    it.transform.position = pos
                }
                state.updateItem(it)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func snap(_ pos: Vec2, item: SceneItem, size: Size2D) -> Vec2 {
        var t = item.transform
        t.position = pos
        let box = t.boundingBox(for: size)
        let canvas = state.canvasSize
        let threshold = 12.0
        var p = pos
        let edgesX: [(Double, Double)] = [(box.minX, 0), (box.maxX, Double(canvas.width)), (box.center.x, Double(canvas.width) / 2)]
        for (a, b) in edgesX where abs(a - b) < threshold { p.x += b - a; break }
        let edgesY: [(Double, Double)] = [(box.minY, 0), (box.maxY, Double(canvas.height)), (box.center.y, Double(canvas.height) / 2)]
        for (a, b) in edgesY where abs(a - b) < threshold { p.y += b - a; break }
        return p
    }
}
