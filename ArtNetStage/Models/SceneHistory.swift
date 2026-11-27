import Foundation
import Combine
import AppKit

/// Cronologia annulla/ripristina (⌘Z / ⇧⌘Z) basata su istantanee dello stato della scena.
///
/// Ogni modifica a catena DMX, libreria dei profili (canali, ruota colori, gobo, prisma, strobo…), palco, oggetti 3D,
/// luminosità o Net/SubNet viene rilevata osservando i modelli: non serve registrare le azioni una per una.
/// Le raffiche di modifiche (slider, digitazione, trascinamento) si fondono in un solo passo: il passo viene chiuso
/// dopo una breve pausa, oppure al rilascio del mouse quando si trascina il Gumball.
final class SceneHistory: ObservableObject {

    /// Stato completo annullabile.
    struct Snapshot: Equatable {
        var library: [FixtureProfile]
        var patched: [PatchedFixture]
        var stage: StageConfig
        var objects: [StageObject]
        var ambient: Double
        var master: Double
        var net: Int
        var subNet: Int
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private unowned let patch: PatchManager
    private unowned let scene: SceneModel
    private unowned let server: ArtNetServer

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var committed: Snapshot
    private var pendingWork: DispatchWorkItem?
    private var holdCount = 0
    private var suppressUntil = Date.distantPast
    private var bag = Set<AnyCancellable>()

    private static let limit = 200
    private static let quietInterval: TimeInterval = 0.5

    init(patch: PatchManager, scene: SceneModel, server: ArtNetServer) {
        self.patch = patch
        self.scene = scene
        self.server = server
        self.committed = Snapshot(
            library: patch.library, patched: patch.patched, stage: scene.stage, objects: scene.objects,
            ambient: scene.ambientLevel, master: scene.beamMaster, net: server.net, subNet: server.subNet
        )

        // I publisher @Published emettono prima dell'assegnazione: `receive(on:)` rimanda la lettura al ciclo successivo,
        // quando i modelli hanno già il valore nuovo.
        Publishers.MergeMany(
            patch.$library.map { _ in () }.eraseToAnyPublisher(),
            patch.$patched.map { _ in () }.eraseToAnyPublisher(),
            scene.$stage.map { _ in () }.eraseToAnyPublisher(),
            scene.$objects.map { _ in () }.eraseToAnyPublisher(),
            scene.$ambientLevel.map { _ in () }.eraseToAnyPublisher(),
            scene.$beamMaster.map { _ in () }.eraseToAnyPublisher(),
            server.$net.map { _ in () }.eraseToAnyPublisher(),
            server.$subNet.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.noteChange() }
        .store(in: &bag)
    }

    // MARK: - Istantanee

    private func capture() -> Snapshot {
        Snapshot(
            library: patch.library, patched: patch.patched, stage: scene.stage, objects: scene.objects,
            ambient: scene.ambientLevel, master: scene.beamMaster, net: server.net, subNet: server.subNet
        )
    }

    // MARK: - Registrazione

    private func noteChange() {
        // Durante il trascinamento del Gumball non serve confrontare nulla: il passo si chiude al rilascio.
        if holdCount > 0 { return }
        // Subito dopo un annulla/ripristina o un'apertura file i modelli si assestano (riancoraggi, sincronizzazioni):
        // non sono modifiche dell'utente, quindi la base si aggiorna senza creare passi.
        if Date() < suppressUntil {
            committed = capture()
            return
        }
        if capture() == committed {
            pendingWork?.cancel()
            return
        }
        scheduleCommit()
    }

    private func scheduleCommit() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.holdCount > 0 { return }           // trascinamento in corso: si chiude al rilascio
            self.commitNow()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietInterval, execute: work)
    }

    /// Chiude il passo in corso: la base precedente entra nello stack di annulla.
    func commitNow() {
        pendingWork?.cancel()
        pendingWork = nil
        let current = capture()
        guard current != committed else { return }
        undoStack.append(committed)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
        committed = current
        refreshFlags()
    }

    /// Inizio/fine di un trascinamento continuo (Gumball): un solo passo, chiuso al rilascio del mouse.
    func beginHold() { holdCount += 1 }

    func endHold() {
        holdCount = max(holdCount - 1, 0)
        if holdCount == 0 { commitNow() }
    }

    // MARK: - Annulla / Ripristina

    func undo() {
        commitNow()
        guard let target = undoStack.popLast() else { return }
        redoStack.append(committed)
        restore(target)
    }

    func redo() {
        commitNow()
        guard let target = redoStack.popLast() else { return }
        undoStack.append(committed)
        restore(target)
    }

    /// Dopo aperture di file o nuove scene: la cronologia riparte da zero.
    func reset() {
        pendingWork?.cancel()
        pendingWork = nil
        undoStack.removeAll()
        redoStack.removeAll()
        suppressUntil = Date().addingTimeInterval(0.8)
        committed = capture()
        refreshFlags()
    }

    private func restore(_ s: Snapshot) {
        suppressUntil = Date().addingTimeInterval(0.6)

        patch.library = s.library
        scene.setStageWithoutReanchor(s.stage)        // niente riancoraggio delle luci: le loro posizioni sono nell'istantanea
        scene.objects = s.objects
        scene.ambientLevel = s.ambient
        scene.beamMaster = s.master
        server.net = s.net
        server.subNet = s.subNet
        patch.patched = s.patched                     // per ultimo: prevale su sincronizzazioni e riancoraggi

        if let sel = scene.selectedEntityID,
           !s.patched.contains(where: { $0.id == sel }), !s.objects.contains(where: { $0.id == sel }) {
            scene.selectedEntityID = nil
        }
        committed = s
        refreshFlags()
    }

    private func refreshFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
