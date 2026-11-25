import SwiftUI

/// Pannello "Palco": dimensioni di palco e americane (in tempo reale), oggetti 3D, elenco unico degli elementi in scena.
/// L'elenco usa `SceneModel.selectedEntityID`, lo stesso stato della vista 3D.
struct StagePanelView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var scene: SceneModel
    @EnvironmentObject var patch: PatchManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stageBox
                addBox
                listBox
                inspector
            }
            .padding(12)
        }
    }

    // MARK: - Dimensioni del palco

    private var stageBox: some View {
        GroupBox(label: Label("Dimensioni del palco", systemImage: "square.dashed")) {
            VStack(alignment: .leading, spacing: 8) {
                valueRow("Larghezza", $scene.stage.width, 4...40, step: 0.5, unit: "m")
                valueRow("Profondità", $scene.stage.depth, 3...30, step: 0.5, unit: "m")
                valueRow("Altezza base palco", $scene.stage.baseHeight, 0...3, step: 0.05, unit: "m")
                valueRow("Altezza americane", $scene.stage.trussHeight, 2...15, step: 0.1, unit: "m")
                Toggle("Mostra americane", isOn: $scene.stage.showTruss)
                HStack(spacing: 8) {
                    ColorPicker("Colore americane", selection: Binding(
                        get: { Color(hex: scene.stage.trussColorHex) },
                        set: { scene.stage.trussColorHex = $0.hexString }
                    ), supportsOpacity: false)
                    Button("Nero") { scene.stage.trussColorHex = "#151515" }
                    Button("Alluminio") { scene.stage.trussColorHex = StageConfig.defaultTrussColorHex }
                }
                .controlSize(.small)
                .disabled(!scene.stage.showTruss)
                HStack(spacing: 8) {
                    ColorPicker("Colore piano palco", selection: Binding(
                        get: { Color(hex: scene.stage.deckColorHex) },
                        set: { scene.stage.deckColorHex = $0.hexString }
                    ), supportsOpacity: false)
                    Button("Standard") {
                        scene.stage.deckColorHex = StageConfig.defaultDeckColorHex
                        scene.stage.deckBrightness = StageConfig.defaultDeckBrightness
                    }
                }
                .controlSize(.small)
                HStack {
                    Text("Luminosità piano")
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $scene.stage.deckBrightness, in: 0...1.5)
                    Text("\(Int((scene.stage.deckBrightness * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                .help("Luminosità / riflettività del solo piano del palco, indipendente dallo slider «Elementi scena».")
                Toggle("Ombre dei fasci sugli oggetti", isOn: $scene.stage.beamShadows)
                Text("Le luci a terra seguono l'altezza della base; quelle su americana restano agganciate quando cambi l'altezza o la profondità. La Y delle luci è misurata dal piano del palco.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ripristina dimensioni standard") {
                    // Ripristina solo le dimensioni: visibilità, colore e ombre restano come sono.
                    var s = StageConfig()
                    s.showTruss = scene.stage.showTruss
                    s.trussColorHex = scene.stage.trussColorHex
                    s.beamShadows = scene.stage.beamShadows
                    s.deckColorHex = scene.stage.deckColorHex
                    s.deckBrightness = scene.stage.deckBrightness
                    scene.stage = s
                }
                .controlSize(.small)
            }
            .padding(6)
        }
    }

    private func valueRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                          step: Double, unit: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range, step: step)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.glass)
                .frame(width: 62)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    // MARK: - Aggiunta oggetti

    private var addBox: some View {
        GroupBox(label: Label("Oggetti 3D", systemImage: "cube.transparent")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { scene.addObject(.box) } label: {
                        Label("Aggiungi parallelepipedo", systemImage: "cube")
                    }
                    Button { scene.addObject(.mannequin) } label: {
                        Label("Aggiungi manichino", systemImage: "person.fill")
                    }
                }
                Text("Stativo / Cavalletto luci")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(StageObjectKind.standKinds) { kind in
                        Button { scene.addObject(kind) } label: {
                            Label(Self.standButtonTitle(kind), systemImage: kind.icon)
                        }
                    }
                }
                .controlSize(.small)
                Text("Gli oggetti vengono illuminati dai fasci, proiettano ombra e bloccano i coni di luce. Con un elemento selezionato compare il Gumball nella vista 3D: frecce per spostare, archi per ruotare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private static func standButtonTitle(_ kind: StageObjectKind) -> String {
        switch kind {
        case .standSingle: return "Singolo"
        case .standDouble: return "T-Bar 2 posti"
        case .standQuad: return "T-Bar 4 posti"
        default: return kind.rawValue
        }
    }

    // MARK: - Elenco unico

    private var listBox: some View {
        GroupBox(label: Label("Elementi in scena", systemImage: "list.bullet.rectangle")) {
            List(selection: $scene.selectedEntityID) {
                Section("Luci") {
                    ForEach(patch.patched) { f in
                        HStack(spacing: 8) {
                            Image(systemName: f.profile.type.icon).frame(width: 20)
                            Text(f.label).lineLimit(1)
                            Spacer()
                            Text("U\(f.universe) \(f.startAddress)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .tag(f.id)
                    }
                }
                Section("Oggetti") {
                    ForEach(scene.objects) { o in
                        HStack(spacing: 8) {
                            Image(systemName: o.kind.icon).frame(width: 20)
                            Text(o.name).lineLimit(1)
                            Spacer()
                            Text(o.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(o.id)
                    }
                }
            }
            .frame(height: 250)
        }
    }

    // MARK: - Ispettore

    @ViewBuilder
    private var inspector: some View {
        if let id = scene.selectedEntityID, let binding = scene.objectBinding(id) {
            ObjectInspector(
                object: binding,
                onDuplicate: { scene.duplicateObject(id) },
                onDelete: { scene.removeObject(id) }
            )
        } else if let id = scene.selectedEntityID, let f = patch.patched.first(where: { $0.id == id }) {
            GroupBox(label: Label(f.label, systemImage: f.profile.type.icon)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(f.profile.modelName) · Universo \(f.universe) · canali \(f.startAddress)–\(f.endAddress)")
                        .font(.callout)
                    Button("Modifica indirizzo e posizione in «Collegamenti»") { vm.section = .patch }
                }
                .padding(6)
            }
        } else {
            Text("Seleziona un elemento nell'elenco o nella vista 3D.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

// MARK: - Ispettore oggetto

struct ObjectInspector: View {
    @EnvironmentObject var patch: PatchManager
    @Binding var object: StageObject
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var isStand: Bool { object.kind.isStand }

    /// Etichette delle tre misure: per gli stativi hanno un altro significato.
    private var dimLabels: (String, String, String) {
        isStand
            ? ("Larghezza barra", "Altezza asta", "Ingombro base")
            : ("Larghezza", "Altezza", "Profondità")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label(isStand ? "Stativo selezionato" : "Oggetto selezionato", systemImage: object.kind.icon)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Nome", text: $object.name)
                            .textFieldStyle(.glass)
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: object.colorHex) },
                            set: { object.colorHex = $0.hexString }
                        ))
                        .labelsHidden()
                        Button { onDuplicate() } label: { Image(systemName: "plus.square.on.square") }
                            .help("Duplica")
                        Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                            .help("Rimuovi dalla scena")
                    }

                    Text("Posizione (metri) — Y è l'altezza della base sopra il piano del palco")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        numberField("X (sx/dx)", $object.x)
                        numberField("Y (altezza)", $object.y)
                        numberField("Z (verso pubblico)", $object.z)
                    }

                    Text(isStand ? "Dimensioni dello stativo (metri)" : "Dimensioni (metri)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if object.kind == .standSingle {
                            numberField(dimLabels.1, $object.height, min: 0.5)
                            numberField(dimLabels.2, $object.depth, min: 0.3)
                        } else {
                            numberField(dimLabels.0, $object.width, min: isStand ? 0.2 : 0.05)
                            numberField(dimLabels.1, $object.height, min: isStand ? 0.5 : 0.05)
                            numberField(dimLabels.2, $object.depth, min: isStand ? 0.3 : 0.05)
                        }
                    }
                    if isStand {
                        HStack {
                            Text("Altezza asta: \(String(format: "%.2f", object.height)) m")
                                .font(.callout)
                                .monospacedDigit()
                                .frame(width: 150, alignment: .leading)
                            Slider(value: $object.height, in: 0.5...6)
                        }
                    }

                    HStack {
                        Text("Rotazione (yaw): \(Int(object.yaw))°")
                            .font(.callout)
                            .monospacedDigit()
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $object.yaw, in: -180...180)
                    }
                    if !isStand {
                        HStack {
                            Text("Inclinazione X: \(Int(object.pitchDeg))°")
                                .font(.callout)
                                .monospacedDigit()
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { object.pitchDeg },
                                set: { object.pitch = abs($0) < 0.01 ? nil : $0 }
                            ), in: -180...180)
                        }
                        HStack {
                            Text("Rollio Z: \(Int(object.rollDeg))°")
                                .font(.callout)
                                .monospacedDigit()
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { object.rollDeg },
                                set: { object.roll = abs($0) < 0.01 ? nil : $0 }
                            ), in: -180...180)
                        }
                    }
                }
                .padding(6)
            }
            if isStand { mountsBox }
        }
    }

    // MARK: Punti di montaggio

    private var mountsBox: some View {
        GroupBox(label: Label("Attacchi per le luci", systemImage: "link")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<object.kind.mountCount, id: \.self) { slot in
                    HStack {
                        Text(object.kind.mountCount == 1 ? "Attacco superiore" : "Posto \(slot + 1)")
                            .frame(width: 130, alignment: .leading)
                        Picker("", selection: Binding<UUID?>(
                            get: { fixtureID(at: slot) },
                            set: { newID in assign(newID, to: slot) }
                        )) {
                            Text("Vuoto").tag(UUID?.none)
                            ForEach(patch.patched) { f in
                                Text(f.label).tag(UUID?.some(f.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
                Text("Le luci agganciate si posano sul punto di montaggio e seguono lo stativo quando lo sposti, lo ruoti o ne cambi altezza e larghezza.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private func fixtureID(at slot: Int) -> UUID? {
        patch.patched.first { $0.mountedOn == object.id && ($0.mountSlot ?? 0) == slot }?.id
    }

    private func assign(_ newID: UUID?, to slot: Int) {
        // Libera il posto se era occupato da un'altra luce.
        for f in patch.patched where f.mountedOn == object.id && (f.mountSlot ?? 0) == slot && f.id != newID {
            patch.detach(f.id)
        }
        if let newID { patch.attach(newID, to: object, slot: slot) }
    }

    private func numberField(_ title: String, _ value: Binding<Double>, min lower: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { newValue in
                    if let lower { value.wrappedValue = Swift.max(lower, newValue) } else { value.wrappedValue = newValue }
                }
            ), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.glass)
        }
    }
}
