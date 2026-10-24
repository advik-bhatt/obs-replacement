import Foundation
import UpstageCore

/// JSON persistence under ~/Library/Application Support/Upstage:
///   scene-collections/<name>.json, profiles/<name>.json, state.json (which are active).
final class Store {
    struct AppStateFile: Codable {
        var collection: String
        var profile: String
    }

    let root: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private var pendingCollection: SceneCollection?
    private var pendingProfile: Profile?
    private var saveTimer: Timer?
    private(set) var activeCollectionName = "Default"
    private(set) var activeProfileName = "Default"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        root = base.appendingPathComponent("Upstage", isDirectory: true)
        try? FileManager.default.createDirectory(at: collectionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")), let s = try? JSONDecoder().decode(AppStateFile.self, from: data) {
            activeCollectionName = s.collection
            activeProfileName = s.profile
        }
    }

    var collectionsDir: URL { root.appendingPathComponent("scene-collections", isDirectory: true) }
    var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }

    private func url(collection name: String) -> URL { collectionsDir.appendingPathComponent(Store.safe(name) + ".json") }
    private func url(profile name: String) -> URL { profilesDir.appendingPathComponent(Store.safe(name) + ".json") }

    static func safe(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
    }

    func listCollections() -> [String] { list(collectionsDir) }
    func listProfiles() -> [String] { list(profilesDir) }

    private func list(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func loadCollection(named name: String? = nil) -> SceneCollection? {
        let n = name ?? activeCollectionName
        guard let data = try? Data(contentsOf: url(collection: n)) else { return nil }
        return try? JSONDecoder().decode(SceneCollection.self, from: data)
    }

    func loadProfile(named name: String? = nil) -> Profile? {
        let n = name ?? activeProfileName
        guard let data = try? Data(contentsOf: url(profile: n)) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    func setActive(collection: String? = nil, profile: String? = nil) {
        if let c = collection { activeCollectionName = c }
        if let p = profile { activeProfileName = p }
        let s = AppStateFile(collection: activeCollectionName, profile: activeProfileName)
        if let data = try? encoder.encode(s) { try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic) }
    }

    /// Debounced: UI edits arrive many times a second, disk gets one write.
    func scheduleSave(collection: SceneCollection? = nil, profile: Profile? = nil) {
        if let c = collection { pendingCollection = c }
        if let p = profile { pendingProfile = p }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in self?.flush() }
    }

    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        if let c = pendingCollection {
            write(c, to: url(collection: c.name))
            activeCollectionName = c.name
            pendingCollection = nil
        }
        if let p = pendingProfile {
            write(p, to: url(profile: p.name))
            activeProfileName = p.name
            pendingProfile = nil
        }
        setActive()
    }

    func saveNow(collection: SceneCollection) { write(collection, to: url(collection: collection.name)) }
    func saveNow(profile: Profile) { write(profile, to: url(profile: profile.name)) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        // Profiles hold the stream key: keep them user-only readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(collection name: String) { try? FileManager.default.removeItem(at: url(collection: name)) }
    func delete(profile name: String) { try? FileManager.default.removeItem(at: url(profile: name)) }

    func rename(collection old: String, to new: String) {
        try? FileManager.default.moveItem(at: url(collection: old), to: url(collection: new))
    }

    func rename(profile old: String, to new: String) {
        try? FileManager.default.moveItem(at: url(profile: old), to: url(profile: new))
    }
}
