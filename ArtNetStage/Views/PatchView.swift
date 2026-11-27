import SwiftUI

struct PatchView: View {
    @EnvironmentObject var patch: PatchManager
    @EnvironmentObject var scene: SceneModel
    @EnvironmentObject var vm: AppViewModel

    @State private var newUniverse = 0
    @State private var newAddress = 1

    private var usedUniverses: [Int] {
        Set(patch.patched.map { $0.universe }).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                addBox

                if !patch.conflicts.isEmpty { conflictBanner }

                GroupBox(label: Label("Catena DMX (daisy-chain)", systemImage: "link")) {
                    if patch.patched.isEmpty {
                        Text("Nessuna luce in catena.")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ChainDiagramView(
                            fixtures: patch.patched,
                            conflicts: patch.conflicts,
                            selection: $scene.selectedEntityID
                        )
                    }
                }

                if !usedUniverses.isEmpty {
                    GroupBox(label: Label("Occupazione universi", systemImage: "chart.bar.xaxis")) {
                        VStack(spacing: 8) {
                            ForEach(usedUniverses, id: \.self) { u in
                                UniverseMapView(
                                    universe: u,
                                    fixtures: patch.patched.filter { $0.universe == u },
                                    conflicts: patch.conflicts
                                )
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox(label: Label("Luci in catena (trascina per riordinare la catena)", systemImage: "list.bullet")) {
                    List(selection: $scene.selectedEntityID) {
                        ForEach(patch.patched) { f in
                            FixtureRow(fixture: f, conflict: patch.conflicts.contains(f.id))
                                .tag(f.id)
                        }
                        .onMove { source, destination in
                            patch.move(from: source, to: destination)
                        }
                    }
                    .frame(height: 210)
                }

                inspector
            }
            .padding(12)
        }
    }

    // MARK: - Aggiunta

    private var addBox: some View {
        GroupBox(label: Label("Aggiungi luce", systemImage: "plus.circle")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Luce", selection: $patch.selectedProfileID) {
                    ForEach(patch.library) { p in
                        Text("\(p.modelName) — \(p.channelCount) ch").tag(p.id as UUID?)
                    }
                }
                HStack(spacing: 16) {
                    Stepper("Universo \(newUniverse)", value: $newUniverse, in: 0...15)
                    Stepper("Indirizzo \(newAddress)", value: $newAddress, in: 1...512)
                }
                HStack {
                    Button { addManual() } label: { Label("Aggiungi", systemImage: "plus") }
                    Button { addInSeries() } label: { Label("Collega in serie (auto-catena)", systemImage: "link.badge.plus") }
                        .buttonStyle(GlassButtonStyle(prominent: true))
                    Spacer()
                    Button("Ricalcola catena") { patch.repatchChain() }
                        .help("Riassegna tutte le luci in sequenza da Universo 0 / canale 1")
                }
            }
            .padding(6)
        }
    }

    private func selectedProfile() -> FixtureProfile? {
        guard let id = patch.selectedProfileID else { return nil }
        return patch.library.first(where: { $0.id == id })
    }

    private func addManual() {
        guard let p = selectedProfile() else { return }
        scene.selectedEntityID = patch.addFixture(p, universe: newUniverse, address: newAddress)
    }

    private func addInSeries() {
        guard let p = selectedProfile() else { return }
        scene.selectedEntityID = patch.addFixtureInSeries(p)
    }

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Conflitto di indirizzi DMX: \(patch.conflicts.count) luci si sovrappongono o escono dall'universo (canale > 512).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Ispettore

    @ViewBuilder
    private var inspector: some View {
        if let id = scene.selectedEntityID, let binding = patch.fixtureBinding(id) {
            FixtureInspector(
                fixture: binding,
                conflict: patch.conflicts.contains(id),
                stands: scene.objects.filter { $0.kind.isStand },
                onAutoPatch: { patch.autoPatch(id) },
                onAttach: { stand, slot in
                    if let stand { patch.attach(id, to: stand, slot: slot) } else { patch.detach(id) }
                },
                onDelete: {
                    patch.remove(id)
                    if scene.selectedEntityID == id { scene.selectedEntityID = nil }
                }
            )
            if let f = patch.patched.first(where: { $0.id == id }) {
                if !f.profile.pixelLayout.isEmpty { PixelTestBox(fixture: f) }
                if f.profile.type == .smokeMachine { SmokeTestBox(fixture: f) }
            }
        } else {
            Text("Seleziona una luce per modificarne indirizzo e posizione.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

// MARK: - Riga lista

struct FixtureRow: View {
    let fixture: PatchedFixture
    let conflict: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fixture.profile.type.icon)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(fixture.label).lineLimit(1)
                Text(fixture.profile.modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if conflict {
                Label("Conflitto", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("U\(fixture.universe)  \(String(format: "%03d", fixture.startAddress))–\(String(format: "%03d", fixture.endAddress))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(conflict ? Color.red : Color.primary)
        }
    }
}

// MARK: - Diagramma della catena con cavi

struct ChainDiagramView: View {
    @Environment(\.sectionTheme) private var theme
    let fixtures: [PatchedFixture]
    let conflicts: Set<UUID>
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                sourceBox
                ForEach(Array(fixtures.enumerated()), id: \.element.id) { idx, f in
                    let prev: PatchedFixture? = idx > 0 ? fixtures[idx - 1] : nil
                    let bad = conflicts.contains(f.id) || (prev.map { conflicts.contains($0.id) } ?? false)
                    CableView(
                        warning: bad,
                        jump: prev.map { $0.universe != f.universe } ?? false,
                        label: (prev.map { $0.universe != f.universe } ?? false) ? "U\(f.universe)" : "DMX"
                    )
                    FixtureCard(fixture: f, conflict: conflicts.contains(f.id), selected: selection == f.id)
                        .onTapGesture { selection = f.id }
                }
            }
            .padding(8)
        }
        .frame(height: 112)
    }

    private var sourceBox: some View {
        VStack(spacing: 4) {
            Image(systemName: "network")
                .font(.title2)
            Text("Art-Net")
                .font(.caption.bold())
            Text("DMX OUT")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 70, height: 70)
        .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.accent, lineWidth: 1))
    }
}

struct FixtureCard: View {
    @Environment(\.sectionTheme) private var theme
    let fixture: PatchedFixture
    let conflict: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: fixture.profile.type.icon)
            Text(fixture.label)
                .font(.caption.bold())
                .lineLimit(1)
            Text("U\(fixture.universe) \(fixture.startAddress)–\(fixture.endAddress)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(conflict ? Color.red : Color.secondary)
        }
        .padding(6)
        .frame(width: 118, height: 70)
        .background(Color.secondary.opacity(selected ? 0.28 : 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(conflict ? Color.red : (selected ? theme.accent : Color.clear), lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

struct CableShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY - 6
        p.move(to: CGPoint(x: 0, y: y))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: y),
            control1: CGPoint(x: rect.maxX * 0.25, y: rect.maxY),
            control2: CGPoint(x: rect.maxX * 0.75, y: rect.maxY)
        )
        return p
    }
}

struct CableView: View {
    let warning: Bool
    let jump: Bool
    let label: String

    var body: some View {
        ZStack {
            CableShape()
                .stroke(
                    warning ? Color.red : Color.gray,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: jump ? [5, 4] : [])
                )
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(warning ? Color.red : Color.secondary)
                .offset(y: 22)
        }
        .frame(width: 58, height: 70)
    }
}

// MARK: - Mappa occupazione universo

struct UniverseMapView: View {
    let universe: Int
    let fixtures: [PatchedFixture]
    let conflicts: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Universo \(universe)")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    ForEach(fixtures) { f in
                        let x = geo.size.width * CGFloat(f.startAddress - 1) / 512
                        let w = max(2, geo.size.width * CGFloat(min(f.endAddress, 512) - f.startAddress + 1) / 512)
                        Rectangle()
                            .fill(conflicts.contains(f.id) ? Color.red.opacity(0.8) : Self.color(for: f))
                            .frame(width: w)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    static func color(for f: PatchedFixture) -> Color {
        Color(hue: Double(f.id.uuid.0) / 255, saturation: 0.55, brightness: 0.9)
    }
}

// MARK: - Ispettore luce

struct FixtureInspector: View {
    @Binding var fixture: PatchedFixture
    let conflict: Bool
    /// Stativi presenti in scena (per l'aggancio ai punti di montaggio).
    let stands: [StageObject]
    let onAutoPatch: () -> Void
    /// Aggancia la luce al punto `slot` dello stativo, oppure la stacca (nil).
    let onAttach: (StageObject?, Int) -> Void
    let onDelete: () -> Void

    private var universeBinding: Binding<Int> {
        Binding(get: { fixture.universe }, set: { fixture.universe = min(max($0, 0), 15) })
    }

    private var addressBinding: Binding<Int> {
        Binding(get: { fixture.startAddress }, set: { fixture.startAddress = min(max($0, 1), 512) })
    }

    var body: some View {
        GroupBox(label: Label("Luce selezionata", systemImage: "slider.horizontal.3")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Nome", text: $fixture.label)
                        .textFieldStyle(.glass)
                    Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                        .help("Rimuovi dalla catena")
                }

                // Indirizzamento DMX
                HStack(spacing: 14) {
                    Stepper(value: universeBinding, in: 0...15) {
                        Text("Universo \(fixture.universe)").monospacedDigit()
                    }
                    Stepper(value: addressBinding, in: 1...512) {
                        Text("Start \(fixture.startAddress)").monospacedDigit()
                    }
                }
                HStack {
                    Text("Indirizzo finale: \(fixture.endAddress)  (\(fixture.profile.channelCount) canali)")
                        .font(.callout)
                        .foregroundStyle(fixture.endAddress > 512 ? Color.red : Color.secondary)
                    Spacer()
                    Button("Collega in serie dopo la precedente") { onAutoPatch() }
                        .controlSize(.small)
                }
                if conflict {
                    Label("Indirizzi sovrapposti ad un'altra luce sullo stesso universo", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()

                // Posizione e montaggio
                Text("Posizione sul palco (metri) — Y è l'altezza sopra il piano del palco").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    numberField("X (sx/dx)", $fixture.x)
                    numberField("Y (alt. sul palco)", $fixture.y)
                    numberField("Z (verso pubblico)", $fixture.z)
                }
                Picker("Montaggio", selection: $fixture.mount) {
                    ForEach(MountOrientation.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(fixture.mountedOn != nil)
                slider("Rotazione (yaw)", $fixture.yaw, -180...180)
                if fixture.profile.type.emitsLight {
                    slider("Offset Pan", $fixture.staticPan, -270...270)
                    slider("Offset Tilt", $fixture.staticTilt, -135...135)
                }
                if fixture.profile.type.isMover {
                    HStack {
                        Toggle("Inverti Pan", isOn: $fixture.invertPan)
                    Toggle("Inverti Tilt", isOn: $fixture.invertTilt)
                    }
                } else if fixture.profile.hasTilt {
                    Toggle("Inverti Tilt", isOn: $fixture.invertTilt)
                }

                Divider()
                sizeSection

                if !stands.isEmpty {
                    Divider()
                    standSection
                }
            }
            .padding(6)
        }
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            DecimalTextField(value: value, maxFractionDigits: 3)
        }
    }

    // MARK: Dimensioni 3D

    private var dimLabels: (String, String, String) {
        switch fixture.profile.type {
        case .ledBar: return ("Lunghezza", "Altezza", "Spessore")
        default: return ("Larghezza", "Altezza", "Profondità")
        }
    }

    /// Misura in metri con limite 3 cm – 5 m. Se il valore coincide con quello predefinito torna a «predefinito» (nil).
    private func sizeBinding(_ keyPath: WritableKeyPath<PatchedFixture, Double?>, default def: Double,
                             current: Double) -> Binding<Double> {
        Binding(
            get: { current },
            set: { newValue in
                let v = min(max(newValue, 0.03), 5)
                fixture[keyPath: keyPath] = abs(v - def) < 0.0005 ? nil : v
            }
        )
    }

    private var sizeSection: some View {
        let dims = fixture.dims
        let def = fixture.profile.defaultDims
        let labels = dimLabels
        let uniform = def.w > 0 ? dims.w / def.w : 1
        return VStack(alignment: .leading, spacing: 6) {
            Text("Dimensioni fisiche in scena (metri)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                numberField(labels.0, sizeBinding(\.sizeW, default: def.w, current: dims.w))
                numberField(labels.1, sizeBinding(\.sizeH, default: def.h, current: dims.h))
                numberField(labels.2, sizeBinding(\.sizeD, default: def.d, current: dims.d))
            }
            HStack {
                Text("Scala: \(Int((uniform * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { uniform },
                    set: { k in
                        let kk = min(max(k, 0.3), 3)
                        fixture.sizeW = abs(kk - 1) < 0.005 ? nil : def.w * kk
                        fixture.sizeH = abs(kk - 1) < 0.005 ? nil : def.h * kk
                        fixture.sizeD = abs(kk - 1) < 0.005 ? nil : def.d * kk
                    }
                ), in: 0.3...3)
                Button("Predefinite") {
                    fixture.sizeW = nil
                    fixture.sizeH = nil
                    fixture.sizeD = nil
                }
                .controlSize(.small)
                .disabled(!fixture.hasCustomSize)
            }
        }
    }

    // MARK: Aggancio a uno stativo

    private var currentStand: StageObject? {
        guard let id = fixture.mountedOn else { return nil }
        return stands.first { $0.id == id }
    }

    private var standSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stativo / cavalletto")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Aggancia a", selection: Binding<UUID?>(
                get: { currentStand?.id },
                set: { newID in
                    if let newID, let stand = stands.first(where: { $0.id == newID }) {
                        onAttach(stand, min(fixture.mountSlot ?? 0, max(stand.kind.mountCount - 1, 0)))
                    } else {
                        onAttach(nil, 0)
                    }
                }
            )) {
                Text("Nessuno (libera)").tag(UUID?.none)
                ForEach(stands) { s in
                    Text("\(s.name) — \(s.kind.mountCount) \(s.kind.mountCount == 1 ? "attacco" : "attacchi")")
                        .tag(UUID?.some(s.id))
                }
            }
            if let stand = currentStand, stand.kind.mountCount > 1 {
                Picker("Attacco", selection: Binding<Int>(
                    get: { fixture.mountSlot ?? 0 },
                    set: { onAttach(stand, $0) }
                )) {
                    ForEach(0..<stand.kind.mountCount, id: \.self) { Text("Posto \($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if currentStand != nil {
                Text("Agganciata: segue lo stativo quando lo sposti, lo ruoti o ne cambi altezza e larghezza. Spostarla a mano la stacca.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text("\(title): \(Int(value.wrappedValue))°")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}


// MARK: - Prova della macchina del fumo

/// Slider diretto sul canale «Fumo»: scrive nel buffer DMX locale per provare l'effetto senza console luci.
struct SmokeTestBox: View {
    @EnvironmentObject var vm: AppViewModel
    let fixture: PatchedFixture

    private var channelIndex: Int? {
        fixture.profile.channels.firstIndex { $0.role == .smoke }
    }

    var body: some View {
        GroupBox(label: Label("Prova fumo", systemImage: "cloud.fill")) {
            VStack(alignment: .leading, spacing: 6) {
                if let idx = channelIndex {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        let values = vm.channelValues(of: fixture)
                        let current = idx < values.count ? Double(values[idx]) : 0
                        HStack {
                            Text("DMX \(Int(current))")
                                .font(.callout)
                                .monospacedDigit()
                                .frame(width: 80, alignment: .leading)
                            Slider(value: Binding(
                                get: { current },
                                set: { vm.setChannels(of: fixture, [idx: UInt8(min(max($0, 0), 255))]) }
                            ), in: 0...255)
                            Button("Off") { vm.setChannels(of: fixture, [idx: 0]) }
                                .controlSize(.small)
                        }
                    }
                } else {
                    Text("Il profilo non ha un canale con ruolo «Fumo».")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }
}
