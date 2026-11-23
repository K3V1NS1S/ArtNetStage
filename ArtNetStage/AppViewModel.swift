import SwiftUI
import Combine

enum PanelSection: String, CaseIterable, Identifiable {
    case network = "Rete"
    case patch = "Patch"
    case fixtures = "Fixture"
    case monitor = "DMX"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .network: return "network"
        case .patch: return "link"
        case .fixtures: return "lightbulb"
        case .monitor: return "waveform"
        }
    }
}

/// Coordinatore dell'applicazione (MVVM): possiede i servizi e li tiene sincronizzati.
final class AppViewModel: ObservableObject {
    @Published var section: PanelSection = .network

    let dmx: DMXStore
    let patch: PatchManager
    let server: ArtNetServer
    let stage: StageController

    private var bag = Set<AnyCancellable>()

    init() {
        let dmx = DMXStore()
        let patch = PatchManager()
        let server = ArtNetServer(dmx: dmx)
        let stage = StageController(dmx: dmx)
        self.dmx = dmx
        self.patch = patch
        self.server = server
        self.stage = stage

        // Ogni modifica alla patch o a Net/SubNet aggiorna scena 3D e universi dichiarati nell'ArtPollReply.
        Publishers.CombineLatest3(patch.$patched, server.$net, server.$subNet)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fixtures, net, subNet in
                self?.apply(fixtures: fixtures, net: net, subNet: subNet)
            }
            .store(in: &bag)

        server.start()
    }

    private func apply(fixtures: [PatchedFixture], net: Int, subNet: Int) {
        let base = ((net & 0x7F) << 8) | ((subNet & 0x0F) << 4)
        stage.setFixtures(fixtures, portBase: base)
        server.setPatchedUniverses(Set(fixtures.map(\.universe)).sorted())
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
