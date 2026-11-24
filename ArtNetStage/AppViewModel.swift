import SwiftUI
import Combine

enum PanelSection: String, CaseIterable, Identifiable {
    case network = "Rete"
    case patch = "Patch"
    case fixtures = "Fixture"
    case stage = "Palco"
    case monitor = "DMX"
    case scenes = "Scene"

    var id: String { rawValue }
}

/// Coordinatore dell'applicazione (MVVM): possiede i servizi e li tiene sincronizzati.
final class AppViewModel: ObservableObject {
    @Published var section: PanelSection = .network

    let dmx: DMXStore
    let patch: PatchManager
    let server: ArtNetServer
    let stage: StageController
    let scene: SceneModel
    let scenes: ScenePresetStore

    private var bag = Set<AnyCancellable>()

    init() {
        let dmx = DMXStore()
        let patch = PatchManager()
        let server = ArtNetServer(dmx: dmx)
        let stage = StageController(dmx: dmx)
        let scene = SceneModel()
        let scenes = ScenePresetStore()
        self.dmx = dmx
        self.patch = patch
        self.server = server
        self.stage = stage
        self.scene = scene
        self.scenes = scenes

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

        server.start()
    }

    private func apply(fixtures: [PatchedFixture], net: Int, subNet: Int) {
        let base = ((net & 0x7F) << 8) | ((subNet & 0x0F) << 4)
        stage.setFixtures(fixtures, portBase: base)
        server.setPatchedUniverses(Set(fixtures.map(\.universe)).sorted())
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

    // MARK: - Scene salvate

    @discardableResult
    func saveScene(name: String, includeCamera: Bool) -> UUID {
        scenes.save(
            name: name,
            fixtures: patch.patched,
            stage: scene.stage,
            objects: scene.objects,
            net: server.net,
            subNet: server.subNet,
            camera: includeCamera ? stage.cameraSnapshot() : nil
        )
    }

    func overwriteScene(_ id: UUID, includeCamera: Bool) {
        scenes.update(
            id: id,
            fixtures: patch.patched,
            stage: scene.stage,
            objects: scene.objects,
            net: server.net,
            subNet: server.subNet,
            camera: includeCamera ? stage.cameraSnapshot() : nil
        )
    }

    func loadScene(_ id: UUID) {
        guard let s = scenes.presets.first(where: { $0.id == id }) else { return }
        scene.selectedEntityID = nil
        // Le posizioni delle luci salvate sono già coerenti con il palco salvato: niente riancoraggio.
        scene.setStageWithoutReanchor(s.stage)
        scene.objects = s.objects
        patch.replacePatch(with: s.fixtures)
        server.net = s.net
        server.subNet = s.subNet
        if let c = s.camera { stage.applyCamera(c) }
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
                case .panFine, .tiltFine, .strobe, .colorWheel, .panTiltSpeed, .custom:
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
