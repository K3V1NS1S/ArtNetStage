import Foundation
import SwiftUI

/// Stato condiviso della scena: dimensioni del palco, oggetti 3D e **selezione unica**
/// (`selectedEntityID`) usata sia dalle liste nella sidebar sia dalla vista 3D.
final class SceneModel: ObservableObject {

    @Published var stage = StageConfig() {
        didSet {
            let c = stage.clamped()
            if c != stage { stage = c }
            guard !isLoading else { return }
            scheduleSave()
            if !suppressStageHook { onStageEdited?(oldValue, stage) }
        }
    }

    @Published var objects: [StageObject] = [] {
        didSet {
            guard !isLoading else { return }
            scheduleSave()
        }
    }

    /// ID della fixture o dell'oggetto selezionato (nil = nessuna selezione).
    @Published var selectedEntityID: UUID?

    /// Chiamato quando l'utente modifica il palco (non quando si carica una scena salvata):
    /// serve a riancorare le luci appese alle americane.
    var onStageEdited: ((StageConfig, StageConfig) -> Void)?

    private var isLoading = true
    private var suppressStageHook = false
    private var saveWork: DispatchWorkItem?

    private struct Persisted: Codable {
        var stage: StageConfig
        var objects: [StageObject]
    }

    init() {
        load()
    }

    // MARK: - Palco

    /// Imposta il palco senza spostare le luci (usato quando si carica una scena salvata,
    /// dove le posizioni delle luci sono già coerenti con il palco salvato).
    func setStageWithoutReanchor(_ s: StageConfig) {
        suppressStageHook = true
        stage = s
        suppressStageHook = false
    }

    // MARK: - Oggetti

    @discardableResult
    func addObject(_ kind: StageObjectKind) -> UUID {
        let n = objects.filter { $0.kind == kind }.count
        let x = Double(n % 4) * 1.4 - 2.1
        let z = stage.depth / 2 - 1.5 - Double(n / 4) * 1.2
        let obj: StageObject
        switch kind {
        case .box:
            obj = StageObject(name: "Parallelepipedo \(n + 1)", kind: .box, x: x, z: z,
                              width: 1, height: 1, depth: 1, colorHex: "#8F8F8F")
        case .mannequin:
            obj = StageObject(name: "Manichino \(n + 1)", kind: .mannequin, x: x, z: z,
                              width: 0.6, height: 1.75, depth: 0.3, colorHex: "#D6D6D6")
        }
        objects.append(obj)
        selectedEntityID = obj.id
        return obj.id
    }

    @discardableResult
    func duplicateObject(_ id: UUID) -> UUID? {
        guard var o = objects.first(where: { $0.id == id }) else { return nil }
        o.id = UUID()
        o.name += " (copia)"
        o.x += 0.6
        objects.append(o)
        selectedEntityID = o.id
        return o.id
    }

    func removeObject(_ id: UUID) {
        objects.removeAll { $0.id == id }
        if selectedEntityID == id { selectedEntityID = nil }
    }

    func objectBinding(_ id: UUID) -> Binding<StageObject>? {
        guard let fallback = objects.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.objects.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let i = self.objects.firstIndex(where: { $0.id == id }) { self.objects[i] = newValue }
            }
        )
    }

    // MARK: - Persistenza

    private var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtNetStage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scene.json")
    }

    private func load() {
        isLoading = true
        if let d = try? Data(contentsOf: fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: d) {
            stage = p.stage.clamped()
            objects = p.objects
        }
        isLoading = false
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(Persisted(stage: stage, objects: objects)) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }
}
