import SwiftUI

/// Finestra unificata: la scena 3D occupa tutta la finestra e il pannello dei controlli è una lastra di vetro
/// satinato appoggiata sopra. Il bordo destro del pannello si trascina per allargare o stringere la viewport.
struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var server: ArtNetServer
    @EnvironmentObject var scene: SceneModel
    @State private var showBrightness = true

    @AppStorage("panelWidth") private var storedPanelWidth: Double = 480
    @State private var panelWidth: CGFloat = 480

    private static let minPanelWidth: CGFloat = 420
    private static let panelMargin: CGFloat = 10
    private static let handleWidth: CGFloat = 14

    private var theme: SectionTheme { vm.section.theme }

    var body: some View {
        GeometryReader { geo in
            let maxWidth = max(Self.minPanelWidth, geo.size.width - 620)
            let width = min(max(panelWidth, Self.minPanelWidth), maxWidth)
            ZStack(alignment: .topLeading) {
                StageSceneView(controller: vm.stage)
                    .ignoresSafeArea()

                // Elementi sovrapposti alla viewport (a destra del pannello).
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: width + Self.panelMargin + Self.handleWidth)
                    viewportOverlay
                }

                // Pannello in vetro + maniglia di ridimensionamento.
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: width)
                        .background(GlassPanelBackground(section: vm.section))
                    PanelResizeHandle(
                        width: $panelWidth,
                        range: Self.minPanelWidth...maxWidth
                    )
                }
                .padding(.leading, Self.panelMargin)
                .padding(.vertical, Self.panelMargin)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .navigationTitle(vm.windowTitle)
        .onAppear { panelWidth = CGFloat(storedPanelWidth) }
        .onChange(of: panelWidth) { storedPanelWidth = Double($0) }
    }

    // MARK: - Pannello laterale

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            SectionTabBar(selection: $vm.section)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            hairline

            Group {
                switch vm.section {
                case .network: NetworkPanelView()
                case .patch: PatchView()
                case .fixtures: FixtureBuilderView()
                case .stage: StagePanelView()
                case .monitor: DMXMonitorView()
                }
            }
            .id(vm.section)
            .transition(.opacity)
            .sectionStyled(vm.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            hairline
            footer
        }
        .animation(.easeInOut(duration: 0.22), value: vm.section)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    /// Intestazione: spazio per i semafori della finestra, titolo e comandi file. È anche l'area di trascinamento finestra.
    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 62, height: 1)          // semafori della finestra
            Text(AppInfo.name)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Button { vm.openProject() } label: { Image(systemName: "folder") }
                .help("Apri scena… (⌘O)")
            Button { vm.saveProject() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Salva scena (⌘S)")
            Button { vm.saveProjectAs() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .help("Salva con nome… (⇧⌘S)")
        }
        .buttonStyle(GlassButtonStyle())
        .controlSize(.small)
        .environment(\.sectionTheme, theme)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(WindowDragArea())
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
            Text(vm.fileDisplayName + (vm.isDirty ? " •" : ""))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(AppInfo.name) \(AppInfo.version)")
                .monospacedDigit()
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Viewport 3D

    private var viewportOverlay: some View {
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
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassSurface(cornerRadius: 14)
        }
        .padding(.top, Self.panelMargin + 6)
        .padding(.trailing, 14)
        .padding(.bottom, Self.panelMargin + 4)
    }

    /// Due slider indipendenti: luce di servizio degli elementi di scena e master dei fasci. Lo sfondo resta nero.
    private var brightnessPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Luminosità", systemImage: "sun.max.fill")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent)
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
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .disabled(scene.ambientLevel == SceneModel.defaultAmbient && scene.beamMaster == SceneModel.defaultBeamMaster)
            }
        }
        .environment(\.sectionTheme, theme)
        .tint(theme.accent)
        .padding(12)
        .frame(width: 290)
        .glassSurface(cornerRadius: 16, tint: theme)
    }

    private func brightnessRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               display: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 94, alignment: .leading)
            Slider(value: value, in: range)
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
        }
        .help(help)
    }

    private var statusHUD: some View {
        let receiving = server.totalHz > 0.5
        let color: Color = receiving ? .green : (server.isRunning ? .orange : .red)
        let text: String = receiving
            ? String(format: "Art-Net in ricezione · %.0f Hz", server.totalHz)
            : (server.isRunning ? "In attesa di dati Art-Net…" : "Nodo fermo")
        return HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .monospacedDigit()
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 14)
    }

    /// Pillola delle viste: la camera si sposta con un'animazione (SCNTransaction).
    private var cameraButtons: some View {
        HStack(spacing: 4) {
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
        .buttonStyle(GlassButtonStyle())
        .controlSize(.small)
        .environment(\.sectionTheme, theme)
        .padding(5)
        .glassSurface(cornerRadius: 16)
    }
}
