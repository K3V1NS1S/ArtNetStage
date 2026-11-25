import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum PanelSection: String, CaseIterable, Identifiable {
    case network = "Rete"
    case patch = "Patch"
    case fixtures = "Fixture"
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

    private func apply(fixtures: [PatchedFixture], net: Int, subNet: Int) {
        let base = ((net & 0x7F) << 8) | ((subNet & 0x0F) << 4)
        stage.setFixtures(fixtures, portBase: base)
        server.setPatchedUniverses(Set(fixtures.map(\.universe)).sorted())
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
            switch axis {
            case 0: patch.patched[i].x = value
            case 1: patch.patched[i].y = value
            default: patch.patched[i].z = value
            }
            if patch.patched[i].mountedOn != nil {
                patch.patched[i].mountedOn = nil
                patch.patched[i].mountSlot = nil
            }
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
            switch axis {
            case 0: patch.patched[i].staticTilt = value
            case 1:
                patch.patched[i].yaw = value
                if patch.patched[i].mountedOn != nil {
                    patch.patched[i].mountedOn = nil
                    patch.patched[i].mountSlot = nil
                }
            default: patch.patched[i].staticPan = value
            }
        } else if let i = scene.objects.firstIndex(where: { $0.id == id }) {
            switch axis {
            case 0: scene.objects[i].pitch = value
            case 1: scene.objects[i].yaw = value
            default: scene.objects[i].roll = value
            }
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

    /// Se ci sono modifiche non salvate chiede cosa fare. Restituisce `false` se l'operazione va annullata.
    private func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Salvare le modifiche alla scena «\(fileDisplayName)»?"
        alert.informativeText = "Se non salvi, le modifiche andranno perse."
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Non salvare")
        alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()
            return !isDirty          // salvataggio annullato o fallito: si resta dove si è
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
