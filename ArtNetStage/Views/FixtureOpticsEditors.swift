import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Editor delle funzioni "ottiche" di un profilo fixture (v1.2):
// modalità colore, strobo in Hz, gobo con maschere personalizzate e prisma radiale.

/// Binding di un valore DMX: limitato a 0...255.
func dmxClamped(_ b: Binding<Int>) -> Binding<Int> {
    Binding(
        get: { b.wrappedValue },
        set: { b.wrappedValue = min(max($0, 0), 255) }
    )
}

// MARK: - Colore del fascio

struct ColorModeBox: View {
    @Binding var profile: FixtureProfile

    private var wheelIndex: Int? { profile.channels.firstIndex { $0.role == .colorWheel } }

    private var wheelSlotsBinding: Binding<[ColorWheelSlot]> {
        Binding(
            get: { wheelIndex.map { profile.channels[$0].wheelSlots } ?? [] },
            set: { newValue in
                if let i = wheelIndex { profile.channels[i].wheelSlots = newValue }
            }
        )
    }

    var body: some View {
        GroupBox(label: Label("Colore del fascio", systemImage: "paintpalette")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Modalità", selection: $profile.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch profile.colorMode {
                case .wheel: wheelBody
                case .rgb: directBody(withWhite: false)
                case .rgbw: directBody(withWhite: true)
                }
            }
            .padding(6)
        }
    }

    // Ruota colori

    @ViewBuilder
    private var wheelBody: some View {
        if wheelIndex != nil {
            ColorWheelEditor(slots: wheelSlotsBinding)
        } else {
            Text("Nessun canale ha il ruolo «Color Wheel»: il fascio resta bianco.")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Assegna Color Wheel al primo canale libero") { assignWheelChannel() }
                .controlSize(.small)
        }
    }

    private func assignWheelChannel() {
        var index = profile.channels.firstIndex { $0.role == .custom }
        if index == nil {
            profile.setChannelCount(profile.channels.count + 1)
            index = profile.channels.count - 1
        }
        guard let i = index, i < profile.channels.count else { return }
        profile.channels[i].role = .colorWheel
        profile.channels[i].name = "Color Wheel"
        if profile.channels[i].wheelSlots.isEmpty {
            profile.channels[i].wheelSlots = FixturePresets.standardWheel()
        }
    }

    // RGB / RGBW

    @ViewBuilder
    private func directBody(withWhite: Bool) -> some View {
        Text("Il colore cambia subito, in modo diretto, seguendo i valori dei canali.")
            .font(.caption)
            .foregroundStyle(.secondary)
        let roles: [(ChannelRole, String)] = withWhite
            ? [(.red, "Rosso"), (.green, "Verde"), (.blue, "Blu"), (.white, "Bianco")]
            : [(.red, "Rosso"), (.green, "Verde"), (.blue, "Blu")]
        HStack(spacing: 12) {
            ForEach(roles, id: \.0) { role, name in
                if let i = profile.channels.firstIndex(where: { $0.role == role }) {
                    Text("\(name): CH \(i + 1)")
                } else {
                    Text("\(name): non assegnato").foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        if !profile.channels.contains(where: { $0.role == .red || $0.role == .green || $0.role == .blue }) {
            Text("Nessun canale Rosso/Verde/Blu: il fascio resta bianco. Assegna i ruoli nella mappatura canali.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Strobo

struct StrobeBox: View {
    @Binding var profile: FixtureProfile

    private var hzBinding: Binding<Double> {
        Binding(
            get: { profile.strobeMaxHz },
            set: { profile.strobeMaxHz = min(max($0, 0.5), 60) }
        )
    }

    var body: some View {
        GroupBox(label: Label("Strobo", systemImage: "bolt.fill")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Frequenza massima (DMX 255)")
                    TextField("Hz", value: hzBinding, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("Hz")
                    Stepper("", value: hzBinding, in: 0.5...60, step: 0.5)
                        .labelsHidden()
                }
                Text("Il canale Strobo parte da DMX 10 (1 Hz) e arriva a questa frequenza a DMX 255; 0–9 = shutter aperto. Il lampeggio nel 3D segue la frequenza impostata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}

// MARK: - Gobo

struct GoboBox: View {
    @Binding var profile: FixtureProfile
    @State private var message: String?

    private var hasOverlap: Bool {
        let s = profile.gobos.sorted { $0.from < $1.from }
        guard s.count > 1 else { return false }
        for i in 1..<s.count where s[i].from <= s[i - 1].to { return true }
        return false
    }

    var body: some View {
        GroupBox(label: Label("Gobo", systemImage: "circle.hexagongrid")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Associa a ogni intervallo DMX (0–255) una maschera quadrata in bianco e nero, JPG o PNG: le aree bianche lasciano passare la luce, quelle nere la bloccano. Se l'immagine non è quadrata viene ritagliata al centro. Un intervallo senza immagine è «aperto». Le maschere vengono incorporate nei file scena .artnetstage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if profile.type == .ledBar {
                    Text("I gobo non sono applicati alle barre LED multi-pixel.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach($profile.gobos) { $slot in
                    GoboSlotRow(
                        slot: $slot,
                        onDelete: { id in profile.gobos.removeAll { $0.id == id } },
                        onError: { message = $0 }
                    )
                }

                HStack {
                    Button("Aggiungi gobo") {
                        let start = min((profile.gobos.map { $0.to }.max() ?? -1) + 1, 255)
                        profile.gobos.append(GoboSlot(from: start, to: min(start + 9, 255), name: "Gobo \(profile.gobos.count + 1)"))
                    }
                    Button("Svuota") { profile.gobos = [] }
                        .disabled(profile.gobos.isEmpty)
                }
                .controlSize(.small)

                if hasOverlap {
                    Text("Alcuni intervalli si sovrappongono: vale il primo che contiene il valore DMX.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        }
    }
}

struct GoboSlotRow: View {
    @Binding var slot: GoboSlot
    let onDelete: (UUID) -> Void
    let onError: (String?) -> Void

    private var fromBinding: Binding<Int> {
        Binding(
            get: { slot.from },
            set: {
                slot.from = min(max($0, 0), 255)
                if slot.to < slot.from { slot.to = slot.from }
            }
        )
    }

    private var toBinding: Binding<Int> {
        Binding(
            get: { slot.to },
            set: { slot.to = min(max($0, slot.from), 255) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Da", value: fromBinding, format: .number)
                        .frame(width: 46)
                    Text("–")
                    TextField("A", value: toBinding, format: .number)
                        .frame(width: 46)
                    TextField("Nome", text: $slot.name)
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button(slot.hasImage ? "Cambia immagine…" : "Scegli immagine…") { chooseImage() }
                    if slot.hasImage {
                        Button("Rimuovi (aperto)") {
                            slot.imageData = nil
                            slot.sourceName = nil
                            slot.revision = UUID()
                        }
                    }
                    if let n = slot.sourceName {
                        Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .controlSize(.small)
            }
            Button(role: .destructive) { onDelete(slot.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = slot.imageData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "circle.dashed").foregroundStyle(.secondary))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Scegli la maschera del gobo"
        panel.message = "Immagine quadrata in bianco e nero (JPG o PNG): bianco = luce, nero = bloccato."
        panel.prompt = "Scegli"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let png = try GoboImageImporter.normalizedPNG(from: url)
            slot.imageData = png
            slot.revision = UUID()
            slot.sourceName = url.lastPathComponent
            let base = url.deletingPathExtension().lastPathComponent
            if slot.name.isEmpty || slot.name.hasPrefix("Gobo ") || slot.name == "Aperto" { slot.name = base }
            onError(nil)
        } catch {
            onError("«\(url.lastPathComponent)»: \(error.localizedDescription)")
        }
    }
}

// MARK: - Prisma radiale

struct PrismBox: View {
    @Binding var profile: FixtureProfile

    private var facetOptions: [Int] {
        Array(Set([3, 4, 5, 6, 8, 12, 18, 24, profile.prismFacets])).sorted()
    }

    private var facetsBinding: Binding<Int> {
        Binding(get: { profile.prismFacets }, set: { profile.prismFacets = min(max($0, 2), 24) })
    }

    private var inFromBinding: Binding<Int> {
        Binding(get: { profile.prismInFrom }, set: { profile.prismInFrom = min(max($0, 0), 255) })
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(profile.prismRotateThreshold) },
            set: { profile.prismRotateThreshold = min(max(Int($0.rounded()), 0), 255) }
        )
    }

    var body: some View {
        GroupBox(label: Label("Prisma radiale", systemImage: "hexagon")) {
            VStack(alignment: .leading, spacing: 8) {
                if profile.type == .ledBar {
                    Text("Il prisma non è applicato alle barre LED multi-pixel.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Facce (sotto-fasci)")
                    Picker("", selection: facetsBinding) {
                        ForEach(facetOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Stepper("", value: facetsBinding, in: 2...24)
                        .labelsHidden()
                    Text("\(profile.prismFacets)").monospacedDigit().foregroundStyle(.secondary)
                }

                HStack {
                    Text("Prisma inserito da DMX")
                    TextField("0–255", value: inFromBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: inFromBinding, in: 0...255)
                        .labelsHidden()
                }

                HStack {
                    Text("Soglia rotazione DMX: \(profile.prismRotateThreshold)")
                        .monospacedDigit()
                        .frame(width: 190, alignment: .leading)
                    Slider(value: thresholdBinding, in: 0...255, step: 1)
                }

                Stepper(value: $profile.prismMaxRPM, in: 1...600, step: 5) {
                    Text("Velocità a DMX 255: \(Int(profile.prismMaxRPM)) giri/min").monospacedDigit()
                }

                Text("Sotto «inserito da» il prisma è fuori e il fascio è singolo. Da lì il fascio si duplica in \(profile.prismFacets) sotto-fasci disposti a corona attorno all'asse ottico. Fino alla soglia il prisma resta fermo; oltre la soglia ruota in modo continuo, con velocità proporzionale all'aumento del valore DMX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}
