import SwiftUI

struct PatchView: View {
    @EnvironmentObject var patch: PatchManager

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
                        Text("Nessuna luce in patch.")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ChainDiagramView(
                            fixtures: patch.patched,
                            conflicts: patch.conflicts,
                            selection: $patch.selectedID
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

                GroupBox(label: Label("Luci patchate (trascina per riordinare la catena)", systemImage: "list.bullet")) {
                    List(selection: $patch.selectedID) {
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
                Picker("Fixture", selection: $patch.selectedProfileID) {
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
                    Button { addInSeries() } label: { Label("Collega in serie (Auto-Patch)", systemImage: "link.badge.plus") }
                        .buttonStyle(.borderedProminent)
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
        patch.addFixture(p, universe: newUniverse, address: newAddress)
    }

    private func addInSeries() {
        guard let p = selectedProfile() else { return }
        patch.addFixtureInSeries(p)
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
        .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Ispettore

    @ViewBuilder
    private var inspector: some View {
        if let id = patch.selectedID, let binding = patch.fixtureBinding(id) {
            FixtureInspector(
                fixture: binding,
                conflict: patch.conflicts.contains(id),
                onAutoPatch: { patch.autoPatch(id) },
                onDelete: { patch.remove(id) }
            )
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
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1))
    }
}

struct FixtureCard: View {
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
        .background(Color.secondary.opacity(selected ? 0.28 : 0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(conflict ? Color.red : (selected ? Color.accentColor : Color.clear), lineWidth: 2)
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
    let onAutoPatch: () -> Void
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
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                        .help("Rimuovi dalla patch")
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
                Text("Posizione sul palco (metri)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    numberField("X (sx/dx)", $fixture.x)
                    numberField("Y (altezza)", $fixture.y)
                    numberField("Z (verso pubblico)", $fixture.z)
                }
                Picker("Montaggio", selection: $fixture.mount) {
                    ForEach(MountOrientation.allCases) { Text($0.rawValue).tag($0) }
                }
                slider("Rotazione (yaw)", $fixture.yaw, -180...180)
                slider("Offset Pan", $fixture.staticPan, -270...270)
                slider("Offset Tilt", $fixture.staticTilt, -135...135)
                if fixture.profile.type.isMover {
                    HStack {
                        Toggle("Inverti Pan", isOn: $fixture.invertPan)
                        Toggle("Inverti Tilt", isOn: $fixture.invertTilt)
                    }
                }
            }
            .padding(6)
        }
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
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
