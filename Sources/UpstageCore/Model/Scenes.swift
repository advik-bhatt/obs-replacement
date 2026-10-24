import Foundation

public struct SceneItem: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var visible: Bool
    public var locked: Bool
    public var transform: Transform

    public init(id: UUID = UUID(), sourceID: UUID, visible: Bool = true, locked: Bool = false,
                transform: Transform = .identity) {
        self.id = id
        self.sourceID = sourceID
        self.visible = visible
        self.locked = locked
        self.transform = transform
    }
}

public struct Scene: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Draw order: index 0 is the bottom.
    public var items: [SceneItem]

    public init(id: UUID = UUID(), name: String, items: [SceneItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public enum TransitionKind: String, Codable, CaseIterable, Hashable {
    case cut
    case fade
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case fadeToBlack

    public var label: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .fadeToBlack: return "Fade to Black"
        }
    }
}

public struct TransitionSettings: Codable, Equatable, Hashable {
    public var kind: TransitionKind
    public var durationMs: Int

    public init(kind: TransitionKind = .fade, durationMs: Int = 300) {
        self.kind = kind
        self.durationMs = durationMs
    }
}

/// Everything about what is on screen: scenes, the sources they reference and
/// the transition between them. Saved as one JSON document.
public struct SceneCollection: Codable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var name: String
    public var scenes: [Scene]
    public var sources: [SourceDescriptor]
    public var currentSceneID: UUID
    public var previewSceneID: UUID?
    public var transition: TransitionSettings

    public init(name: String, scenes: [Scene], sources: [SourceDescriptor],
                currentSceneID: UUID, previewSceneID: UUID? = nil,
                transition: TransitionSettings = TransitionSettings()) {
        self.version = SceneCollection.formatVersion
        self.name = name
        self.scenes = scenes
        self.sources = sources
        self.currentSceneID = currentSceneID
        self.previewSceneID = previewSceneID
        self.transition = transition
    }

    /// One empty scene, nothing else. What a fresh install shows.
    public static func empty(name: String = "Untitled") -> SceneCollection {
        let scene = Scene(name: "Scene")
        return SceneCollection(name: name, scenes: [scene], sources: [], currentSceneID: scene.id)
    }

    // MARK: lookups

    public func scene(_ id: UUID) -> Scene? { scenes.first { $0.id == id } }
    public func sceneIndex(_ id: UUID) -> Int? { scenes.firstIndex { $0.id == id } }
    public func source(_ id: UUID) -> SourceDescriptor? { sources.first { $0.id == id } }
    public func sourceIndex(_ id: UUID) -> Int? { sources.firstIndex { $0.id == id } }
    public var currentScene: Scene? { scene(currentSceneID) }

    public func scenes(containing sourceID: UUID) -> [Scene] {
        scenes.filter { $0.items.contains { $0.sourceID == sourceID } }
    }

    /// Sources that are not referenced by any scene (candidates for cleanup).
    public var orphanSources: [SourceDescriptor] {
        sources.filter { scenes(containing: $0.id).isEmpty }
    }

    // MARK: mutation helpers (pure, so the UI layer can stay thin)

    @discardableResult
    public mutating func addScene(named name: String) -> Scene {
        let unique = uniqueName(name, existing: scenes.map { $0.name })
        let scene = Scene(name: unique)
        scenes.append(scene)
        return scene
    }

    public mutating func removeScene(_ id: UUID) {
        guard scenes.count > 1, let idx = sceneIndex(id) else { return }
        scenes.remove(at: idx)
        if currentSceneID == id { currentSceneID = scenes[max(0, idx - 1)].id }
        if previewSceneID == id { previewSceneID = scenes[max(0, idx - 1)].id }
    }

    @discardableResult
    public mutating func addSource(_ descriptor: SourceDescriptor, toScene sceneID: UUID, transform: Transform? = nil) -> SceneItem? {
        var src = descriptor
        if source(src.id) == nil {
            src.name = uniqueName(src.name, existing: sources.map { $0.name })
            sources.append(src)
        }
        guard let sidx = sceneIndex(sceneID) else { return nil }
        let item = SceneItem(sourceID: src.id, transform: transform ?? .identity)
        scenes[sidx].items.append(item)
        return item
    }

    /// Adds an existing source to a scene (the "Add Existing" flow).
    @discardableResult
    public mutating func addItem(sourceID: UUID, toScene sceneID: UUID, transform: Transform = .identity) -> SceneItem? {
        guard source(sourceID) != nil, let sidx = sceneIndex(sceneID) else { return nil }
        let item = SceneItem(sourceID: sourceID, transform: transform)
        scenes[sidx].items.append(item)
        return item
    }

    public mutating func removeItem(_ itemID: UUID, fromScene sceneID: UUID, deleteOrphanedSource: Bool = true) {
        guard let sidx = sceneIndex(sceneID), let iidx = scenes[sidx].items.firstIndex(where: { $0.id == itemID }) else { return }
        let sourceID = scenes[sidx].items[iidx].sourceID
        scenes[sidx].items.remove(at: iidx)
        if deleteOrphanedSource, scenes(containing: sourceID).isEmpty, let srcIdx = sourceIndex(sourceID) {
            sources.remove(at: srcIdx)
        }
    }

    public mutating func removeSource(_ sourceID: UUID) {
        for i in scenes.indices { scenes[i].items.removeAll { $0.sourceID == sourceID } }
        sources.removeAll { $0.id == sourceID }
    }

    public mutating func updateSource(_ source: SourceDescriptor) {
        guard let idx = sourceIndex(source.id) else { return }
        sources[idx] = source
    }

    public mutating func updateItem(_ item: SceneItem, inScene sceneID: UUID) {
        guard let sidx = sceneIndex(sceneID), let iidx = scenes[sidx].items.firstIndex(where: { $0.id == item.id }) else { return }
        scenes[sidx].items[iidx] = item
    }

    public mutating func moveItem(_ itemID: UUID, inScene sceneID: UUID, by delta: Int) {
        guard let sidx = sceneIndex(sceneID), let iidx = scenes[sidx].items.firstIndex(where: { $0.id == itemID }) else { return }
        let target = min(max(0, iidx + delta), scenes[sidx].items.count - 1)
        guard target != iidx else { return }
        let item = scenes[sidx].items.remove(at: iidx)
        scenes[sidx].items.insert(item, at: target)
    }

    public mutating func moveScene(from: Int, to: Int) {
        guard scenes.indices.contains(from), scenes.indices.contains(to), from != to else { return }
        let s = scenes.remove(at: from)
        scenes.insert(s, at: to)
    }

    public func uniqueName(_ base: String, existing: [String]) -> String {
        var name = base
        var n = 2
        let set = Set(existing)
        while set.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}
