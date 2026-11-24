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
                .textFieldStyle(.roundedBorder)
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
                Text("Gli oggetti vengono illuminati dai fasci delle luci e proiettano ombra.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: - Elenco unico

    private var listBox: some View {
        GroupBox(label: Label("Elementi in scena", systemImage: "list.bullet.rectangle")) {
            List(selection: $scene.selectedEntityID) {
                Section("Fixture") {
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
                    Button("Modifica indirizzo e posizione nella Patch") { vm.section = .patch }
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
    @Binding var object: StageObject
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GroupBox(label: Label("Oggetto selezionato", systemImage: object.kind.icon)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Nome", text: $object.name)
                        .textFieldStyle(.roundedBorder)
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

                Text("Dimensioni (metri)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    numberField("Larghezza", $object.width, min: 0.05)
                    numberField("Altezza", $object.height, min: 0.05)
                    numberField("Profondità", $object.depth, min: 0.05)
                }

                HStack {
                    Text("Rotazione: \(Int(object.yaw))°")
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $object.yaw, in: -180...180)
                }
            }
            .padding(6)
        }
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
            .textFieldStyle(.roundedBorder)
        }
    }
}
