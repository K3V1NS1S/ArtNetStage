import Foundation

/// Archivio delle scene salvate come preset (patch + palco + oggetti + Net/SubNet + camera).
final class ScenePresetStore: ObservableObject {

    @Published private(set) var presets: [ScenePreset] = []

    init() {
        load()
    }

    @discardableResult
    func save(name: String, fixtures: [PatchedFixture], stage: StageConfig, objects: [StageObject],
              net: Int, subNet: Int, camera: CameraSnapshot?) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = ScenePreset(
            name: trimmed.isEmpty ? "Scena \(presets.count + 1)" : trimmed,
            fixtures: fixtures, stage: stage, objects: objects,
            net: net, subNet: subNet, camera: camera
        )
        presets.insert(preset, at: 0)
        persist()
        return preset.id
    }

    /// Sovrascrive il contenuto di un preset esistente mantenendone nome e id.
    func update(id: UUID, fixtures: [PatchedFixture], stage: StageConfig, objects: [StageObject],
                net: Int, subNet: Int, camera: CameraSnapshot?) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].fixtures = fixtures
        presets[i].stage = stage
        presets[i].objects = objects
        presets[i].net = net
        presets[i].subNet = subNet
        presets[i].camera = camera
        presets[i].date = Date()
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets[i].name = trimmed
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func export(id: UUID, to url: URL) throws {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: url, options: .atomic)
    }

    @discardableResult
    func importPreset(from url: URL) throws -> UUID {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var p = try dec.decode(ScenePreset.self, from: data)
        p.id = UUID()
        presets.insert(p, at: 0)
        persist()
        return p.id
    }

    // MARK: - Persistenza

    private var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtNetStage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scenes.json")
    }

    private func load() {
        if let d = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([ScenePreset].self, from: d) {
            presets = list
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(presets) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }
}
