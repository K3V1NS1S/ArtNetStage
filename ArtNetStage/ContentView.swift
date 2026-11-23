import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var server: ArtNetServer

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 430, idealWidth: 490, maxWidth: 840)
            stageArea
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pannello laterale

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sezione", selection: $vm.section) {
                ForEach(PanelSection.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                switch vm.section {
                case .network: NetworkPanelView()
                case .patch: PatchView()
                case .fixtures: FixtureBuilderView()
                case .monitor: DMXMonitorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Stage 3D

    private var stageArea: some View {
        ZStack {
            StageSceneView(controller: vm.stage)

            VStack {
                HStack(alignment: .top) {
                    statusHUD
                    Spacer()
                    cameraButtons
                }
                Spacer()
                Text("Trascina: orbita · ⇧ o tasto destro: pan · rotellina / pizzico: zoom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(10)
        }
    }

    private var statusHUD: some View {
        let receiving = server.totalHz > 0.5
        let color: Color = receiving ? .green : (server.isRunning ? .orange : .red)
        let text: String = receiving
            ? String(format: "Art-Net in ricezione · %.0f Hz", server.totalHz)
            : (server.isRunning ? "In attesa di dati Art-Net…" : "Nodo fermo")
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var cameraButtons: some View {
        HStack(spacing: 6) {
            Button { vm.stage.setPreset(.front) } label: {
                Label("Frontale", systemImage: "rectangle.portrait")
            }
            Button { vm.stage.setPreset(.top) } label: {
                Label("Dall'alto", systemImage: "arrow.down.to.line")
            }
            Button { vm.stage.setPreset(.threeQuarter) } label: {
                Label("3/4 Palco", systemImage: "cube")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
