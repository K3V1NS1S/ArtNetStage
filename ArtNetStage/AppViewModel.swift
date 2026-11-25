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
            .sink { [weak stage] value in stage?.setObjects(value) }
            .store(in: &bag)
        scene.$selectedEntityID
            .removeDuplicates()
            .sink { [weak stage] id in stage?.setSelection(id) }
            .store(in: &bag)

        // Qualsiasi modifica a patch, palco o oggetti segna la scena come "modificata".
        Publishers.MergeMany(
            patch.$patched.map { _ in () }.eraseToAnyPublisher(),
            scene.$stage.map { _ in () }.eraseToAnyPublisher(),
            scene.$objects.map { _ in () }.eraseToAnyPublisher()
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
            camera: stage.cameraSnapshot()
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
                case .dimmer, .red, .green, .blue, .white, .pixel:
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
}
