import SwiftUI

/// Finestra unificata (v2.1): un unico sfondo continuo a tutta finestra, tinto dalla sezione attiva (o nero con
/// «Blackout UI»). Il pannello dei controlli poggia direttamente sullo sfondo, senza riquadro; la scena 3D
/// (sfondo trasparente) occupa l'area a destra della sottile barra verticale trascinabile, e il palco risulta
/// quindi sempre centrato nello spazio visibile.
struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var server: ArtNetServer
    @EnvironmentObject var scene: SceneModel
    @State private var showBrightness = true

    @AppStorage("panelWidth") private var storedPanelWidth: Double = 480
    @AppStorage("blackoutUI") private var blackout = false
    @State private var panelWidth: CGFloat = 480

    // Vista in prima persona dal manichino
    @State private var povActive = false
    @State private var povID: UUID?
    @State private var fov: Double = 75

    private static let minPanelWidth: CGFloat = 420
    private static let minViewportWidth: CGFloat = 700

    private var theme: SectionTheme { vm.section.theme }
    /// Figure con vista POV: manichini e Kevin.
    private var mannequins: [StageObject] { scene.objects.filter { $0.kind.isFigure } }

    var body: some View {
        GeometryReader { geo in
            let maxWidth = max(Self.minPanelWidth, geo.size.width - Self.minViewportWidth)
            let width = min(max(panelWidth, Self.minPanelWidth), maxWidth)
            ZStack {
                WindowBackdrop(section: vm.section, blackout: blackout)

                HStack(spacing: 0) {
                    sidebar
                        .frame(width: width)
                    PanelResizeHandle(width: $panelWidth, range: Self.minPanelWidth...maxWidth)
                    viewport
                }
            }
        }
        .ignoresSafeArea()
        .navigationTitle(vm.windowTitle)
        .background(WindowCloseGuard(viewModel: vm, hasUnsavedChanges: vm.hasUnsavedChanges))
        .onAppear {
            AppDelegate.viewModel = vm
            vm.installDeleteKeyMonitor()
            panelWidth = CGFloat(storedPanelWidth)
        }
        .onChange(of: panelWidth) { storedPanelWidth = Double($0) }
        .onChange(of: mannequins.map { $0.id }) { ids in
            guard povActive else { return }
            if ids.isEmpty {
                vm.stage.exitPOV()
                povActive = false
            } else if let id = povID, !ids.contains(id) {
                povID = ids[0]
                vm.stage.enterPOV(objectID: ids[0], fov: fov)
            }
        }
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
            Text(vm.fileDisplayName)
                .lineLimit(1)
                .truncationMode(.middle)
            statusBadge
            Spacer()
            Text("\(AppInfo.name) \(AppInfo.version)")
                .monospacedDigit()
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Stato del file, sempre scritto in testo accanto al nome: «Modificato» se `hasUnsavedChanges == true`,
    /// «Salvato» altrimenti (anche per «Senza titolo» ancora intatto).
    private var statusBadge: some View {
        badge(vm.hasUnsavedChanges ? "Modificato" : "Salvato",
              color: vm.hasUnsavedChanges ? Color(rgb: 0xFFB74D) : Color(rgb: 0x4CE08A))
    }

    /// Etichetta testuale (non un pallino): la parola è sempre scritta per intero e non viene mai compressa.
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(color.opacity(0.18)))
            .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 0.75))
            .layoutPriority(2)
            .animation(.easeInOut(duration: 0.2), value: text)
    }

    // MARK: - Viewport 3D

    private var viewport: some View {
        ZStack {
            StageSceneView(controller: vm.stage)
            viewportOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var viewportOverlay: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    statusHUD
                    Spacer(minLength: 8)
                    viewControls
                }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack { statusHUD; Spacer(minLength: 0) }
                    viewControls
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                brightnessPanel
                Spacer()
                lightTestButton
            }
            Text("Trascina: orbita (in POV: guarda intorno) · tasto destro o ⌥ + trascina: pan · rotellina / pizzico: zoom · click: seleziona · frecce e archi del Gumball: sposta / ruota (Shift = a passi)")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassSurface(cornerRadius: 14)
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
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

    /// Pillola delle viste + Blackout UI (+ controlli POV quando la vista manichino è attiva).
    private var viewControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Riga 1: pillola delle viste + Blackout UI (larghezza naturale, mai compressa).
            HStack(spacing: 8) {
                cameraButtons
                blackoutButton
            }
            .fixedSize(horizontal: true, vertical: false)
            // Riga 2: controlli secondari della vista Manichino (selettore e slider FOV).
            if povActive { povControls }
        }
    }

    /// Pillola delle viste: la camera si sposta con un'animazione (SCNTransaction).
    private var cameraButtons: some View {
        HStack(spacing: 4) {
            viewButton("Frontale", "rectangle.portrait") { goPreset(.front) }
            viewButton("Laterale", "sidebar.right") { goPreset(.side) }
            viewButton("Superiore", "arrow.down.to.line") { goPreset(.top) }
            viewButton("3/4", "cube") { goPreset(.threeQuarter) }
            Button { togglePOV() } label: {
                Label("Manichino", systemImage: "eye")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(GlassButtonStyle(prominent: povActive))
            .disabled(mannequins.isEmpty)
            .help(mannequins.isEmpty
                  ? "Vista Manichino / Kevin (POV): aggiungi un manichino o Kevin dalla scheda Palco"
                  : "Vista Manichino / Kevin (POV): guarda dagli occhi del manichino o di Kevin")
            Rectangle()                                              // divisore verticale sottile
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)
            Button {
                vm.isOrthographic.toggle()
            } label: {
                Text("Orto")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(GlassButtonStyle(prominent: vm.isOrthographic))
            .fixedSize(horizontal: true, vertical: false)
            .help(vm.isOrthographic
                  ? "Orto attivo: Frontale, Laterale e Superiore in proiezione ortogonale (zoom con rotellina / pizzico)"
                  : "Orto: usa la proiezione ortogonale nelle viste Frontale, Laterale e Superiore")
        }
        .fixedSize(horizontal: true, vertical: false)       // i pulsanti non vengono mai compressi né vanno a capo
        .buttonStyle(GlassButtonStyle())
        .controlSize(.small)
        .environment(\.sectionTheme, theme)
        .padding(5)
        .glassSurface(cornerRadius: 16)
    }

    /// Pulsante della pillola delle viste: sempre a una riga e alla sua larghezza naturale.
    private func viewButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// «Test Luci»: accende tutte le fixture con colori casuali e movimenti fluidi, senza toccare DMX, Annulla o file.
    private var lightTestButton: some View {
        Button { vm.isLightTest.toggle() } label: {
            Label("Test Luci", systemImage: "flashlight.on.fill")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GlassButtonStyle(prominent: vm.isLightTest))
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.small)
        .environment(\.sectionTheme, theme)
        .padding(5)
        .glassSurface(cornerRadius: 16)
        .help(vm.isLightTest
              ? "Test Luci attivo: clic per tornare ai valori reali del segnale Art-Net / DMX"
              : "Test Luci: accende tutte le luci con colori casuali e movimenti fluidi (non altera DMX né Annulla)")
    }

    /// «Blackout UI»: sfondo nero puro dietro pannello e viewport; pannelli e card in vetro restano invariati.
    private var blackoutButton: some View {
        Button { withAnimation(.easeInOut(duration: 0.3)) { blackout.toggle() } } label: {
            Image(systemName: blackout ? "moon.fill" : "moon")
        }
        .buttonStyle(GlassButtonStyle(prominent: blackout))
        .controlSize(.small)
        .environment(\.sectionTheme, theme)
        .padding(5)
        .glassSurface(cornerRadius: 16)
        .help(blackout ? "Blackout UI attivo: torna allo sfondo colorato" : "Blackout UI: sfondo nero puro")
    }

    /// Selettore del manichino (se ce n'è più di uno) e slider del campo visivo.
    private var povControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Vista Manichino (POV)", systemImage: "eye.fill")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 6)
                if mannequins.count > 1 {
                    Picker("Manichino", selection: Binding<UUID>(
                        get: { povID ?? mannequins[0].id },
                        set: { id in
                            povID = id
                            vm.stage.enterPOV(objectID: id, fov: fov)
                        }
                    )) {
                        ForEach(mannequins) { m in Text(m.name).tag(m.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)
                } else if let m = mannequins.first {
                    Text(m.name)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            HStack(spacing: 8) {
                Text("Campo visivo")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("35°")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $fov, in: StageController.povMinFOV...StageController.povMaxFOV)
                    .onChange(of: fov) { vm.stage.setPOVFieldOfView($0) }
                Text("110°")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(Int(fov.rounded()))°")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, alignment: .trailing)
            }
            Text("Trascina nella vista per guardarti intorno. Il manichino si sposta e ruota con il Gumball.")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.sectionTheme, theme)
        .tint(theme.accent)
        .padding(12)
        .frame(width: 360)
        .glassSurface(cornerRadius: 16, tint: theme)
    }

    private func goPreset(_ preset: CameraPreset) {
        povActive = false
        vm.stage.setPreset(preset)
    }

    private func togglePOV() {
        if povActive {
            vm.stage.exitPOV()
            povActive = false
            return
        }
        let list = mannequins
        guard !list.isEmpty else { return }
        let selected = scene.selectedEntityID.flatMap { id in list.first(where: { $0.id == id })?.id }
        let id = selected ?? povID.flatMap { p in list.first(where: { $0.id == p })?.id } ?? list[0].id
        povID = id
        povActive = true
        vm.stage.enterPOV(objectID: id, fov: fov)
    }
}
