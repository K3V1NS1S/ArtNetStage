import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var server: ArtNetServer
    @EnvironmentObject var scene: SceneModel
    @State private var showBrightness = true

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 450, idealWidth: 500, maxWidth: 840)
            stageArea
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(vm.windowTitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { vm.openProject() } label: {
                    Label("Apri…", systemImage: "folder")
                }
                .help("Apri scena… (⌘O)")
                Button { vm.saveProject() } label: {
                    Label("Salva", systemImage: "square.and.arrow.down")
                }
                .help("Salva scena (⌘S)")
                Button { vm.saveProjectAs() } label: {
                    Label("Salva con nome…", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Salva con nome… (⇧⌘S)")
            }
        }
    }

    // MARK: - Pannello laterale

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sezione", selection: $vm.section) {
                ForEach(PanelSection.allCases) { s in
                    Text(s.rawValue).tag(s)
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
                case .stage: StagePanelView()
                case .monitor: DMXMonitorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "doc")
                Text(vm.fileDisplayName + (vm.isDirty ? " •" : ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(AppInfo.name) \(AppInfo.version)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                HStack(alignment: .bottom) {
                    brightnessPanel
                    Spacer()
                }
                Text("Trascina: orbita · tasto destro o ⇧/⌥ + trascina: pan · rotellina / pizzico: zoom · click: seleziona · frecce e archi del Gumball: sposta / ruota (⌃ = a passi)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(10)
        }
    }

    /// Due slider indipendenti: luce di servizio degli elementi di scena e master dei fasci. Lo sfondo resta nero.
    private var brightnessPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Luminosità", systemImage: "sun.max")
                    .font(.caption.bold())
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showBrightness.toggle() }
                } label: {
                    Image(systemName: showBrightness ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(showBrightness ? "Nascondi" : "Mostra")
            }
            if showBrightness {
                brightnessRow(
                    "Elementi scena",
                    value: $scene.ambientLevel, range: 0...1,
                    display: "\(Int((scene.ambientLevel * 100).rounded()))%",
                    help: "Luce ambiente / di servizio: palco, americane, stativi, parallelepipedi e manichini. Lo sfondo resta nero."
                )
                brightnessRow(
                    "Luci (master)",
                    value: $scene.beamMaster, range: 0...2,
                    display: "\(Int((scene.beamMaster * 100).rounded()))%",
                    help: "Moltiplicatore globale su intensità delle luci reali e luminosità dei coni. Non cambia la luce ambiente."
                )
                Button("Ripristina") { scene.resetBrightness() }
                    .controlSize(.small)
                    .disabled(scene.ambientLevel == SceneModel.defaultAmbient && scene.beamMaster == SceneModel.defaultBeamMaster)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func brightnessRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               display: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
        .help(help)
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

    /// Toolbar delle viste: la camera si sposta con un'animazione (SCNTransaction).
    private var cameraButtons: some View {
        HStack(spacing: 6) {
            Button { vm.stage.setPreset(.front) } label: {
                Label("Frontale", systemImage: "rectangle.portrait")
            }
            Button { vm.stage.setPreset(.side) } label: {
                Label("Laterale", systemImage: "sidebar.right")
            }
            Button { vm.stage.setPreset(.top) } label: {
                Label("Superiore", systemImage: "arrow.down.to.line")
            }
            Button { vm.stage.setPreset(.threeQuarter) } label: {
                Label("3/4", systemImage: "cube")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
