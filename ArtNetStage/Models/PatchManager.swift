import Foundation
import SwiftUI

/// Gestisce libreria fixture, patch (catena DMX), rilevamento conflitti e persistenza su disco.
/// La selezione (fixture e oggetti) vive in `SceneModel.selectedEntityID`.
final class PatchManager: ObservableObject {

    @Published var library: [FixtureProfile] = [] {
        didSet {
            guard !isLoading else { return }
            syncPatchedProfiles()
            scheduleSave()
        }
    }

    /// L'ordine dell'array è l'ordine della catena DMX (daisy-chain).
    @Published var patched: [PatchedFixture] = [] {
        didSet {
            guard !isLoading else { return }
            recompute()
            scheduleSave()
        }
    }

    @Published private(set) var conflicts: Set<UUID> = []
    @Published var selectedProfileID: UUID?

    /// Fornisce le dimensioni attuali del palco (impostato da `AppViewModel`).
    var stageProvider: () -> StageConfig = { StageConfig() }

    private var isLoading = true
    private var saveWork: DispatchWorkItem?

    init() {
        load()
    }

    // MARK: - Binding di comodo per le viste

    func profileBinding(_ id: UUID) -> Binding<FixtureProfile>? {
        guard let fallback = library.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.library.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let i = self.library.firstIndex(where: { $0.id == id }) { self.library[i] = newValue }
            }
        )
    }

    func fixtureBinding(_ id: UUID) -> Binding<PatchedFixture>? {
        guard let fallback = patched.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.patched.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let i = self.patched.firstIndex(where: { $0.id == id }) { self.patched[i] = newValue }
            }
        )
    }

    // MARK: - Patch

    /// Primo slot libero subito dopo `fixture` (se non entra nell'universo passa al successivo).
    func nextSlot(after fixture: PatchedFixture?, channelCount: Int) -> (universe: Int, address: Int) {
        var u = fixture?.universe ?? 0
        var a = (fixture?.endAddress ?? 0) + 1
        if a + channelCount - 1 > 512 {
            u += 1
            a = 1
        }
        return (min(u, 15), a)
    }

    @discardableResult
    func addFixture(_ profile: FixtureProfile, universe: Int, address: Int) -> UUID {
        let sameType = patched.filter { $0.profile.type == profile.type }.count
        let sameName = patched.filter { $0.profile.modelName == profile.modelName }.count
        var f = PatchedFixture(
            label: "\(profile.modelName) \(sameName + 1)",
            profile: profile,
            universe: min(max(universe, 0), 15),
            startAddress: min(max(address, 1), 512)
        )
        let pl = placement(for: profile.type, index: sameType)
        f.x = pl.x
        f.y = pl.y
        f.z = pl.z
        f.mount = pl.mount
        patched.append(f)
        return f.id
    }

    /// "Collega in serie": aggiunge la luce al primo canale libero dopo l'ultima della catena.
    @discardableResult
    func addFixtureInSeries(_ profile: FixtureProfile) -> UUID {
        let slot = nextSlot(after: patched.last, channelCount: profile.channelCount)
        return addFixture(profile, universe: slot.universe, address: slot.address)
    }

    /// Ricollega una singola luce subito dopo la precedente della catena.
    func autoPatch(_ id: UUID) {
        guard let i = patched.firstIndex(where: { $0.id == id }) else { return }
        let prev: PatchedFixture? = i > 0 ? patched[i - 1] : nil
        let slot = nextSlot(after: prev, channelCount: patched[i].profile.channelCount)
        var copy = patched
        copy[i].universe = slot.universe
        copy[i].startAddress = slot.address
        patched = copy
    }

    /// Riassegna l'intera catena in sequenza a partire da Universo 0 / canale 1.
    func repatchChain() {
        var copy = patched
        var prev: PatchedFixture? = nil
        for i in copy.indices {
            let slot = nextSlot(after: prev, channelCount: copy[i].profile.channelCount)
            copy[i].universe = slot.universe
            copy[i].startAddress = slot.address
            prev = copy[i]
        }
        patched = copy
    }

    func remove(_ id: UUID) {
        patched.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        var copy = patched
        copy.move(fromOffsets: source, toOffset: destination)
        patched = copy
    }

    /// Sostituisce l'intera patch (caricamento di una scena salvata).
    func replacePatch(with fixtures: [PatchedFixture]) {
        patched = fixtures
    }

    // MARK: - Ancoraggio al palco

    /// Quando cambiano altezza o profondità, le luci appese alle americane restano attaccate:
    /// `y` è l'altezza sopra il piano del palco, quindi le luci a terra seguono da sole l'altezza della base,
    /// mentre quelle su americana seguono l'altezza dell'americana (e lo spostamento di quella di fondo).
    func reanchor(from old: StageConfig, to new: StageConfig) {
        let dy = new.trussHeight - old.trussHeight
        let backMoved = old.backTrussZ != new.backTrussZ
        guard dy != 0 || backMoved else { return }
        var copy = patched
        var changed = false
        for i in copy.indices where copy[i].mount == .truss {
            if dy != 0 {
                copy[i].y += dy
                changed = true
            }
            if backMoved && abs(copy[i].z - old.backTrussZ) < 0.35 {
                copy[i].z = new.backTrussZ
                changed = true
            }
        }
        if changed { patched = copy }
    }

    private func placement(for type: FixtureType, index n: Int) -> (x: Double, y: Double, z: Double, mount: MountOrientation) {
        let st = stageProvider()
        switch type {
        case .movingHeadBeam, .movingHeadSpot:
            let row = n / 4
            let step = min(3.0, st.width / 4)
            return ((Double(n % 4) - 1.5) * step, st.trussHeight - 0.2, row == 0 ? st.frontTrussZ : st.backTrussZ, .truss)
        case .parLED:
            let step = min(1.0, st.width / 8)
            return ((Double(n % 7) - 3) * step, 0, st.depth / 2 - 1.0 - Double(n / 7), .floor)
        case .ledBar:
            let step = min(3.0, st.width / 4)
            return ((Double(n % 3) - 1) * step, 0, -st.depth / 2 + 1.5 + Double(n / 3), .floor)
        }
    }

    // MARK: - Conflitti

    private func recompute() {
        var result = Set<UUID>()
        for i in patched.indices {
            let a = patched[i]
            if a.endAddress > 512 || a.universe > 15 { result.insert(a.id) }
            for j in (i + 1)..<patched.count {
                let b = patched[j]
                if a.universe == b.universe && a.startAddress <= b.endAddress && b.startAddress <= a.endAddress {
                    result.insert(a.id)
                    result.insert(b.id)
                }
            }
        }
        if result != conflicts { conflicts = result }
    }

    /// Le luci già patchate restano allineate al profilo di libreria (modifiche live nel Fixture Builder).
    private func syncPatchedProfiles() {
        var copy = patched
        var changed = false
        for i in copy.indices {
            if let lib = library.first(where: { $0.id == copy[i].profile.id }), lib != copy[i].profile {
                copy[i].profile = lib
                changed = true
            }
        }
        if changed { patched = copy }
    }

    // MARK: - Libreria

    @discardableResult
    func newProfile() -> UUID {
        let p = FixtureProfile(
            modelName: "Nuova fixture",
            type: .parLED,
            channels: [
                ChannelDefinition(name: "Dimmer", role: .dimmer),
                ChannelDefinition(name: "Rosso", role: .red),
                ChannelDefinition(name: "Verde", role: .green),
                ChannelDefinition(name: "Blu", role: .blue)
            ],
            beamAngle: 30
        )
        library.append(p)
        return p.id
    }

    @discardableResult
    func duplicateProfile(_ id: UUID) -> UUID? {
        guard var p = library.first(where: { $0.id == id }) else { return nil }
        p.id = UUID()
        p.modelName += " (copia)"
        library.append(p)
        return p.id
    }

    func deleteProfile(_ id: UUID) {
        library.removeAll { $0.id == id }
    }

    /// Unisce i profili di un file di scena alla libreria: stesso id = versione del file, id nuovo = aggiunto.
    /// I profili già presenti nell'app e assenti dal file restano dove sono.
    func mergeLibrary(_ profiles: [FixtureProfile]) {
        var copy = library
        for p in profiles {
            if let i = copy.firstIndex(where: { $0.id == p.id }) {
                copy[i] = p
            } else {
                copy.append(p)
            }
        }
        library = copy
    }

    func restorePresets() {
        var copy = library
        for preset in FixturePresets.all {
            if let i = copy.firstIndex(where: { $0.id == preset.id }) {
                copy[i] = preset
            } else {
                copy.append(preset)
            }
        }
        library = copy
    }

    func exportProfile(_ profile: FixtureProfile, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profile).write(to: url, options: .atomic)
    }

    /// Importa un profilo singolo oppure un array di profili. Restituisce l'id del primo importato.
    @discardableResult
    func importProfiles(from url: URL) throws -> UUID? {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        var incoming: [FixtureProfile]
        if let many = try? dec.decode([FixtureProfile].self, from: data) {
            incoming = many
        } else {
            incoming = [try dec.decode(FixtureProfile.self, from: data)]
        }
        var copy = library
        for i in incoming.indices {
            if copy.contains(where: { $0.id == incoming[i].id }) { incoming[i].id = UUID() }
            copy.append(incoming[i])
        }
        library = copy
        return incoming.first?.id
    }

    // MARK: - Persistenza

    private var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtNetStage", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var libraryURL: URL { supportDir.appendingPathComponent("library.json") }
    private var patchURL: URL { supportDir.appendingPathComponent("patch.json") }

    private func load() {
        isLoading = true
        let dec = JSONDecoder()

        if let d = try? Data(contentsOf: libraryURL),
           let lib = try? dec.decode([FixtureProfile].self, from: d),
           !lib.isEmpty {
            library = lib
        } else {
            library = FixturePresets.all
        }

        var seeded = false
        if let d = try? Data(contentsOf: patchURL),
           let p = try? dec.decode([PatchedFixture].self, from: d) {
            patched = p
        } else {
            seedDemoPatch()
            seeded = true
        }

        selectedProfileID = library.first?.id
        isLoading = false
        recompute()
        syncPatchedProfiles()
        if seeded { scheduleSave() }
    }

    /// Patch dimostrativa al primo avvio: 4 PAR, 4 teste mobili e una barra, in catena.
    private func seedDemoPatch() {
        for _ in 0..<4 { addFixtureInSeries(FixturePresets.par) }
        for _ in 0..<4 { addFixtureInSeries(FixturePresets.mover) }
        addFixtureInSeries(FixturePresets.bar)
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
        if let d = try? enc.encode(library) { try? d.write(to: libraryURL, options: .atomic) }
        if let d = try? enc.encode(patched) { try? d.write(to: patchURL, options: .atomic) }
    }
}
