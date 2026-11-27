import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum PanelSection: String, CaseIterable, Identifiable {
    case network = "Rete"
    case patch = "Catena"
    case fixtures = "Luci"
    case stage = "Palco"
    case monitor = "DMX"

    var id: String { rawValue }
}

/// Coordinatore dell'applicazione (MVVM): possiede i servizi, li tiene sincronizzati
/// e gestisce il salvataggio/apertura della scena come file `.artnetstage`.
final class AppViewModel: ObservableObject {
    @Published var section: PanelSection = .network

    /// File della scena corrente (nil = scena non ancora salvata).
    @Published private(set) var currentFileURL: URL?
    /// Ci sono modifiche non salvate rispetto al file (o alla scena iniziale).
    @Published private(set) var isDirty = false

    let dmx: DMXStore
    let patch: PatchManager
    let server: ArtNetServer
    let stage: StageController
    let scene: SceneModel
    /// Cronologia annulla/ripristina (⌘Z / ⇧⌘Z).
    let history: SceneHistory

    /// Pulsante «Orto» della barra viste: proiezione ortogonale in Frontale / Laterale / Superiore.
    @Published var isOrthographic: Bool = false {
        didSet { if isOrthographic != oldValue { stage.setOrthographic(isOrthographic) } }
    }

    /// «Test Luci» nella viewport: override temporaneo di rendering (colori e movimenti casuali su tutte le luci).
    /// Non è dato di progetto: non passa dal DMX, non entra nella cronologia annulla/ripristina e non rende il file «Modificato».
    @Published var isLightTest: Bool = false {
        didSet { if isLightTest != oldValue { stage.setLightTest(isLightTest) } }
    }

    // MARK: - Cancellazione con Backspace / Canc (v3.0)

    private var keyMonitor: Any?

    /// Installa (una sola volta) il monitor della tastiera: ⌫ (keyCode 51) o Canc (keyCode 117) rimuovono l'elemento
    /// selezionato (oggetto 3D o fixture). Non agisce se si sta scrivendo in un campo di testo, se c'è un pannello
    /// modale o se sono premuti ⌘ ⌥ ⌃ ⇧.
    func installDeleteKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 51 || event.keyCode == 117 else { return event }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            guard NSApp.modalWindow == nil, let window = NSApp.keyWindow, !(window is NSPanel) else { return event }
            // Un campo di testo ha il focus: il tasto serve a cancellare il testo (il field editor è un NSText).
            if window.firstResponder is NSText { return event }
            return self.deleteSelectedElement() ? nil : event
        }
    }

    /// Rimuove l'elemento selezionato: la modifica passa dal modello, quindi entra in Annulla/Ripristina (⌘Z)
    /// e rende il documento «Modificato». Restituisce `false` se non c'era nulla da rimuovere.
    @discardableResult
    func deleteSelectedElement() -> Bool {
        guard let id = scene.selectedEntityID else { return false }
        if scene.objects.contains(where: { $0.id == id }) {
            scene.removeObject(id)
            return true
        }
        if patch.patched.contains(where: { $0.id == id }) {
            patch.remove(id)
            scene.selectedEntityID = nil
            return true
        }
        return false
    }

    /// `true` se ci sono modifiche non salvate (alimenta l'etichetta «Modificato» / «Salvato» nel footer).
    var hasUnsavedChanges: Bool { isDirty }

    // Trascinamento Gumball di una luce: la scena 3D si aggiorna a ogni movimento del mouse (anteprima),
    // il modello dati e le viste SwiftUI a ~30 Hz e al rilascio, così il cursore non aspetta mai l'interfaccia.
    private var liveFixture: PatchedFixture?
    private var liveFlushWork: DispatchWorkItem?

    private var bag = Set<AnyCancellable>()
    private var ignoreDirty = false

    init() {
        let dmx = DMXStore()
        let patch = PatchManager()
        let server = ArtNetServer(dmx: dmx)
        let stage = StageController(dmx: dmx)
        let scene = SceneModel()
        self.dmx = dmx
        self.patch = patch
        self.server = server
        self.stage = stage
        self.scene = scene
        self.history = SceneHistory(patch: patch, scene: scene, server: server)

        // Le nuove luci nascono dentro le dimensioni attuali del palco.
        patch.stageProvider = { [weak scene] in scene?.stage ?? StageConfig() }

        // Se l'utente cambia altezza/profondità, le luci appese alle americane restano ancorate.
        scene.onStageEdited = { [weak patch] old, new in
            patch?.reanchor(from: old, to: new)
        }

        // Click nella vista 3D → selezione condivisa + apertura del pannello corrispondente.
        stage.onPick = { [weak self] id in
            self?.pick(id)
        }

        // Gumball 3D: i valori trascinati scrivono direttamente nel modello (anche i campi numerici della sidebar).
        stage.onGizmoTranslate = { [weak self] id, axis, value in
            self?.gizmoTranslate(id, axis: axis, value: value)
        }
        stage.onGizmoRotate = { [weak self] id, axis, value in
            self?.gizmoRotate(id, axis: axis, value: value)
        }
        // Un trascinamento del Gumball è un solo passo di cronologia, chiuso al rilascio del mouse.
        let history = self.history
        stage.onGizmoDragBegan = { history.beginHold() }
        stage.onGizmoDragEnded = { [weak self] in
            self?.finishLiveFixtureDrag()          // l'ultimo valore entra nel modello prima di chiudere il passo di cronologia
            history.endHold()
        }

        // Ogni modifica alla patch o a Net/SubNet aggiorna scena 3D e universi dichiarati nell'ArtPollReply.
        Publishers.CombineLatest3(patch.$patched, server.$net, server.$subNet)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fixtures, net, subNet in
                self?.apply(fixtures: fixtures, net: net, subNet: subNet)
            }
            .store(in: &bag)

        // Palco, oggetti e selezione → scena 3D.
        scene.$stage
            .sink { [weak stage] value in stage?.setStage(value) }
            .store(in: &bag)
        scene.$objects
            .sink { [weak self] value in
                self?.stage.setObjects(value)
                // Le luci agganciate a uno stativo seguono i suoi spostamenti, rotazioni e misure.
                self?.patch.reattach(objects: value)
            }
            .store(in: &bag)
        Publishers.CombineLatest(scene.$ambientLevel, scene.$beamMaster)
            .sink { [weak stage] ambient, master in stage?.setBrightness(ambient: ambient, master: master) }
            .store(in: &bag)
        scene.$selectedEntityID
            .removeDuplicates()
            .sink { [weak stage] id in stage?.setSelection(id) }
            .store(in: &bag)

        // Qualsiasi modifica a patch, palco o oggetti segna la scena come "modificata".
        Publishers.MergeMany(
            patch.$patched.map { _ in () }.eraseToAnyPublisher(),
            patch.$library.map { _ in () }.eraseToAnyPublisher(),
            server.$net.map { _ in () }.eraseToAnyPublisher(),
            server.$subNet.map { _ in () }.eraseToAnyPublisher(),
            scene.$stage.map { _ in () }.eraseToAnyPublisher(),
            scene.$objects.map { _ in () }.eraseToAnyPublisher(),
            scene.$ambientLevel.map { _ in () }.eraseToAnyPublisher(),
            scene.$beamMaster.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            guard let self, !self.ignoreDirty else { return }
            self.isDirty = true
        }
        .store(in: &bag)

        server.start()
        isDirty = false     // le emissioni iniziali dei publisher non sono modifiche dell'utente
    }

    private var lastDeclaredUniverses: [Int]?

    /// Anteprima immediata in 3D + scrittura del modello con cadenza limitata.
    private func commitLive(_ f: PatchedFixture) {
        liveFixture = f
        stage.previewFixture(f)
        guard liveFlushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.liveFlushWork = nil
            self?.flushLiveFixture()
        }
        liveFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
    }

    private func flushLiveFixture() {
        guard let f = liveFixture, let i = patch.patched.firstIndex(where: { $0.id == f.id }) else { return }
        if patch.patched[i] != f { patch.patched[i] = f }
    }

    private func finishLiveFixtureDrag() {
        liveFlushWork?.cancel()
        liveFlushWork = nil
        flushLiveFixture()
        liveFixture = nil
    }

    private func apply(fixtures: [PatchedFixture], net: Int, subNet: Int) {
        let base = ((net & 0x7F) << 8) | ((subNet & 0x0F) << 4)
        var fixtures = fixtures
        // Durante il trascinamento la luce mostra sempre l'ultima anteprima, mai un valore del modello più vecchio.
        if let live = liveFixture, let i = fixtures.firstIndex(where: { $0.id == live.id }) { fixtures[i] = live }
        stage.setFixtures(fixtures, portBase: base)
        // Gli universi dichiarati cambiano di rado: durante il trascinamento di una luce non si ricostruisce la configurazione del nodo.
        let universes = Set(fixtures.map(\.universe)).sorted()
        if universes != lastDeclaredUniverses {
            lastDeclaredUniverses = universes
            server.setPatchedUniverses(universes)
        }
    }

    // MARK: - Titolo e informazioni

    var fileDisplayName: String {
        currentFileURL?.deletingPathExtension().lastPathComponent ?? "Senza titolo"
    }

    var windowTitle: String {
        "\(AppInfo.name) — \(fileDisplayName)\(isDirty ? " — modificato" : "")"
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: "Nodo Art-Net virtuale e visualizzatore 3D per testare show luci senza luci fisiche.\nFormato scene: .\(ProjectFileType.fileExtension)",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits
        ])
    }

    // MARK: - Selezione

    /// Selezione proveniente dalla vista 3D: aggiorna lo stato condiviso e porta in primo piano la lista giusta.
    private func pick(_ id: UUID?) {
        scene.selectedEntityID = id
        guard let id else { return }
        if patch.patched.contains(where: { $0.id == id }) {
            section = .patch
        } else if scene.objects.contains(where: { $0.id == id }) {
            section = .stage
        }
    }

    // MARK: - Gumball

    /// Nuova coordinata di una fixture o di un oggetto (asse 0 = X, 1 = Y altezza sul palco, 2 = Z).
    /// Spostare a mano una luce agganciata a uno stativo la stacca dallo stativo.
    private func gizmoTranslate(_ id: UUID, axis: Int, value: Double) {
        guard value.isFinite else { return }
        if let i = patch.patched.firstIndex(where: { $0.id == id }) {
            // Una sola scrittura per evento di trascinamento (una sola notifica ai modelli e alla scena 3D),
            // con il valore esatto del cursore: nessun arrotondamento.
            var f = (liveFixture?.id == id ? liveFixture : nil) ?? patch.patched[i]
            switch axis {
            case 0: f.x = value
            case 1: f.y = value
            default: f.z = value
            }
            if f.mountedOn != nil {
                f.mountedOn = nil
                f.mountSlot = nil
            }
            commitLive(f)
        } else if let i = scene.objects.firstIndex(where: { $0.id == id }) {
            switch axis {
            case 0: scene.objects[i].x = value
            case 1: scene.objects[i].y = value
            default: scene.objects[i].z = value
            }
        }
    }

    /// Nuovo angolo in gradi. Arco verde (1) = orientamento base (yaw); arco rosso (0) = tilt della luce /
    /// inclinazione dell'oggetto; arco blu (2) = pan della luce / rollio dell'oggetto.
    private func gizmoRotate(_ id: UUID, axis: Int, value: Double) {
        guard value.isFinite else { return }
        if let i = patch.patched.firstIndex(where: { $0.id == id }) {
            var f = (liveFixture?.id == id ? liveFixture : nil) ?? patch.patched[i]
            switch axis {
            case 0: f.staticTilt = value
            case 1:
                f.yaw = value
                if f.mountedOn != nil {
                    f.mountedOn = nil
                    f.mountSlot = nil
                }
            default: f.staticPan = value
            }
            commitLive(f)
        } else if let i = scene.objects.firstIndex(where: { $0.id == id }) {
            switch axis {
            case 0: scene.objects[i].pitch = value
            case 1: scene.objects[i].yaw = value
            default: scene.objects[i].roll = value
            }
        }
    }

    // MARK: - Annulla / Ripristina

    /// Se si sta scrivendo in un campo di testo, ⌘Z annulla prima la digitazione; altrimenti l'ultima modifica alla scena.
    private var editingTextView: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor else { return nil }
        return tv
    }

    func performUndo() {
        if let tv = editingTextView, let um = tv.undoManager, um.canUndo {
            um.undo()
        } else {
            history.undo()
        }
    }

    func performRedo() {
        if let tv = editingTextView, let um = tv.undoManager, um.canRedo {
            um.redo()
        } else {
            history.redo()
        }
    }

    // MARK: - File di scena (.artnetstage)

    /// Fotografia dell'intero stato del progetto.
    func makeProject() -> ProjectFile {
        ProjectFile(
            format: ProjectFile.currentFormat,
            appVersion: AppInfo.version,
            savedAt: Date(),
            nodeName: server.shortName,
            net: server.net,
            subNet: server.subNet,
            stage: scene.stage,
            fixtures: patch.patched,
            library: patch.library,
            objects: scene.objects,
            camera: stage.cameraSnapshot(),
            ambientLevel: scene.ambientLevel,
            beamMaster: scene.beamMaster
        )
    }

    /// Salva (⌘S): scrive nel file corrente, oppure apre "Salva con nome" se la scena non ha ancora un file.
    func saveProject() {
        if let url = currentFileURL {
            write(to: url)
        } else {
            saveProjectAs()
        }
    }

    /// Salva con nome… (⇧⌘S) con il pannello nativo.
    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.title = "Salva scena"
        panel.prompt = "Salva"
        panel.allowedContentTypes = [ProjectFileType.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(currentFileURL == nil ? "Nuova scena" : fileDisplayName).\(ProjectFileType.fileExtension)"
        if let dir = currentFileURL?.deletingLastPathComponent() { panel.directoryURL = dir }

        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ProjectFileType.fileExtension {
            url.appendPathExtension(ProjectFileType.fileExtension)
        }
        write(to: url)
    }

    /// Apri scena… (⌘O) con il pannello nativo.
    func openProject() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.title = "Apri scena"
        panel.prompt = "Apri"
        panel.allowedContentTypes = [ProjectFileType.utType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    /// Apertura da Finder (doppio click su un file .artnetstage).
    func open(url: URL) {
        guard confirmDiscardChanges() else { return }
        load(url: url)
    }

    private func write(to url: URL) {
        do {
            let data = try makeProject().encoded()
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError("Impossibile salvare la scena", detail: error.localizedDescription)
        }
    }

    private func load(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let project = try ProjectFile.decode(from: data)
            apply(project)
            history.reset()                  // dopo l'apertura di un file la cronologia riparte da zero
            currentFileURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError("Impossibile aprire «\(url.lastPathComponent)»", detail: error.localizedDescription)
        }
    }

    /// Sostituisce lo stato corrente con quello del file.
    private func apply(_ p: ProjectFile) {
        ignoreDirty = true
        defer { ignoreDirty = false }

        scene.selectedEntityID = nil
        // Le posizioni delle luci nel file sono già coerenti con il palco salvato: niente riancoraggio.
        scene.setStageWithoutReanchor(p.stage)
        scene.objects = p.objects
        scene.ambientLevel = p.ambientLevel ?? SceneModel.defaultAmbient
        scene.beamMaster = p.beamMaster ?? SceneModel.defaultBeamMaster
        if let lib = p.library { patch.mergeLibrary(lib) }
        patch.replacePatch(with: p.fixtures)
        server.net = p.net
        server.subNet = p.subNet
        if let n = p.nodeName, !n.isEmpty { server.shortName = n }
        if let c = p.camera { stage.applyCamera(c) }
    }

    /// Chiusura della finestra (X rossa, ⌘W) o dell'app (⌘Q, Esci): `true` se si può chiudere.
    /// Senza modifiche non chiede nulla; altrimenti mostra Salva / Non salvare / Annulla.
    func confirmClose() -> Bool {
        confirmDiscardChanges()
    }

    /// Se ci sono modifiche non salvate chiede cosa fare. Restituisce `false` se l'operazione va annullata.
    private func confirmDiscardChanges() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Vuoi salvare le modifiche apportate al progetto corrente prima di chiudere?"
        alert.informativeText = "Scena: «\(fileDisplayName)». Se non salvi, le modifiche andranno perse."
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Non salvare")
        alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()            // senza file apre il pannello di salvataggio nativo
            return !isDirty          // pannello annullato o salvataggio fallito: si resta nell'app
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Test locale (senza software esterno)

    /// Accende tutte le luci patchate scrivendo direttamente nel buffer DMX locale.
    /// Viene sovrascritto non appena arrivano pacchetti Art-Net reali sullo stesso universo.
    func testAllOn() {
        let base = UInt16(((server.net & 0x7F) << 8) | ((server.subNet & 0x0F) << 4))
        var buffers: [UInt16: [UInt8]] = [:]
        for f in patch.patched {
            let port = base + UInt16(max(0, min(15, f.universe)))
            var buf = buffers[port] ?? dmx.universe(port)
            for (i, ch) in f.profile.channels.enumerated() {
                let a = f.startAddress - 1 + i
                guard a >= 0, a < 512 else { continue }
                switch ch.role {
                case .dimmer, .red, .green, .blue, .white, .pixel, .smoke:
                    buf[a] = 255
                case .pan, .tilt:
                    buf[a] = 128
                case .panFine, .tiltFine, .strobe, .colorWheel, .gobo, .prism, .panTiltSpeed, .custom:
                    buf[a] = 0
                }
            }
            buffers[port] = buf
        }
        for (port, buf) in buffers { dmx.write(port: port, bytes: buf) }
    }

    func blackout() {
        dmx.blackout()
    }

    // MARK: - Accesso DMX per fixture (anteprima pixel, test)

    /// Port-Address dell'universo `universe` (0–15) con Net/SubNet correnti.
    private func portAddress(_ universe: Int) -> UInt16 {
        let base = UInt16(((server.net & 0x7F) << 8) | ((server.subNet & 0x0F) << 4))
        return base + UInt16(max(0, min(15, universe)))
    }

    /// Valori DMX correnti dei canali della luce, nell'ordine del suo profilo.
    func channelValues(of f: PatchedFixture) -> [UInt8] {
        let buf = dmx.universe(portAddress(f.universe))
        return (0..<f.profile.channelCount).map { i in
            let a = f.startAddress - 1 + i
            return (a >= 0 && a < 512) ? buf[a] : 0
        }
    }

    /// Scrive alcuni canali (indice 0-based nella fixture → valore) nel buffer DMX locale.
    func setChannels(of f: PatchedFixture, _ changes: [Int: UInt8]) {
        let port = portAddress(f.universe)
        var buf = dmx.universe(port)
        for (i, v) in changes {
            let a = f.startAddress - 1 + i
            if a >= 0 && a < 512 { buf[a] = v }
        }
        dmx.write(port: port, bytes: buf)
    }

    /// Canali di un singolo LED per un colore (R, G, B, W). Il bianco usa il canale W se esiste, altrimenti R+G+B.
    private func pixelChanges(_ f: PatchedFixture, pixel: Int, color: (UInt8, UInt8, UInt8, UInt8)) -> [Int: UInt8] {
        guard let pc = f.profile.pixelConfig, pixel >= 0, pixel < pc.count else { return [:] }
        var (r, g, b, w) = color
        if w > 0 && !pc.components.contains(.w) {
            r = w; g = w; b = w; w = 0
        }
        var out: [Int: UInt8] = [:]
        for (k, comp) in pc.components.enumerated() {
            let idx = pc.firstChannel + pixel * pc.stride + k
            guard idx < f.profile.channelCount else { continue }
            switch comp {
            case .r: out[idx] = r
            case .g: out[idx] = g
            case .b: out[idx] = b
            case .w: out[idx] = w
            }
        }
        if !out.isEmpty {
            for (i, ch) in f.profile.channels.enumerated() where ch.role == .dimmer { out[i] = 255 }
        }
        return out
    }

    /// Accende il LED con il colore di prova, oppure lo spegne se è già acceso.
    func togglePixel(of f: PatchedFixture, pixel: Int, color: (UInt8, UInt8, UInt8, UInt8)) {
        guard let pc = f.profile.pixelConfig, pixel >= 0, pixel < pc.count else { return }
        let values = channelValues(of: f)
        let lit = (0..<pc.stride).contains { k in
            let idx = pc.firstChannel + pixel * pc.stride + k
            return idx < values.count && values[idx] > 0
        }
        setChannels(of: f, pixelChanges(f, pixel: pixel, color: lit ? (0, 0, 0, 0) : color))
    }

    func setAllPixels(of f: PatchedFixture, color: (UInt8, UInt8, UInt8, UInt8)) {
        guard let pc = f.profile.pixelConfig else { return }
        var all: [Int: UInt8] = [:]
        for p in 0..<pc.count {
            for (k, v) in pixelChanges(f, pixel: p, color: color) { all[k] = v }
        }
        setChannels(of: f, all)
    }
}
