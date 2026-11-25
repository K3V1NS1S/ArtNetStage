import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FixtureBuilderView: View {
    @EnvironmentObject var patch: PatchManager
    @State private var selectedProfileID: UUID?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(10)
            Divider()
            if let id = selectedProfileID, let binding = patch.profileBinding(id) {
                ProfileEditor(profile: binding)
            } else {
                Text("Seleziona o crea un profilo luce.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedProfileID == nil { selectedProfileID = patch.library.first?.id }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Profilo", selection: $selectedProfileID) {
                    ForEach(patch.library) { p in
                        Text("\(p.modelName) — \(p.channelCount) ch").tag(p.id as UUID?)
                    }
                }
                Button { selectedProfileID = patch.newProfile() } label: { Image(systemName: "plus") }
                    .help("Nuovo profilo")
                Button {
                    if let id = selectedProfileID, let n = patch.duplicateProfile(id) { selectedProfileID = n }
                } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplica profilo")
                Button(role: .destructive) {
                    if let id = selectedProfileID {
                        patch.deleteProfile(id)
                        selectedProfileID = patch.library.first?.id
                    }
                } label: { Image(systemName: "trash") }
                    .help("Elimina profilo dalla libreria (le luci già collegate restano)")
            }
            HStack {
                Button("Importa JSON…") { importJSON() }
                Button("Esporta JSON…") { exportJSON() }
                Button("Ripristina preset") { patch.restorePresets() }
                Spacer()
            }
            .controlSize(.small)
            if let m = message {
                Text(m).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func exportJSON() {
        guard let id = selectedProfileID, let p = patch.library.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(p.modelName).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try patch.exportProfile(p, to: url)
                message = nil
            } catch {
                message = "Esportazione non riuscita: \(error.localizedDescription)"
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if let id = try patch.importProfiles(from: url) { selectedProfileID = id }
                message = nil
            } catch {
                message = "Importazione non riuscita: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Editor del profilo

struct ProfileEditor: View {
    @Binding var profile: FixtureProfile
    @State private var mapperSelection: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                generalBox
                if profile.type == .ledBar || profile.pixelConfig != nil { pixelBox }
                if profile.type == .smokeMachine { smokeBox }
                if profile.type != .ledBar && profile.type != .smokeMachine { ColorModeBox(profile: $profile) }
                if profile.hasChannel(.strobe) { StrobeBox(profile: $profile) }
                if profile.hasChannel(.gobo) { GoboBox(profile: $profile) }
                if profile.hasChannel(.prism) { PrismBox(profile: $profile) }
                channelsBox
            }
            .padding(12)
        }
    }

    // MARK: Generale

    private var generalBox: some View {
        GroupBox(label: Label("Generale", systemImage: "info.circle")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Modello").frame(width: 70, alignment: .leading)
                    TextField("Nome modello", text: $profile.modelName).textFieldStyle(.glass)
                }
                Picker("Tipologia", selection: $profile.type) {
                    ForEach(FixtureType.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper(value: Binding(
                    get: { profile.channels.count },
                    set: { profile.setChannelCount($0) }
                ), in: 1...512) {
                    Text("Numero totale di canali: \(profile.channels.count)").monospacedDigit()
                }
                if profile.type.isMover {
                    Stepper(value: $profile.panRange, in: 90...1080, step: 10) {
                        Text("Escursione Pan massima: \(Int(profile.panRange))°").monospacedDigit()
                    }
                }
                if profile.hasTilt {
                    Stepper(value: $profile.tiltRange, in: 45...540, step: 5) {
                        Text("Escursione Tilt massima: \(Int(profile.tiltRange))°").monospacedDigit()
                    }
                }
                if profile.type.isWash {
                    Picker("Forma del corpo", selection: $profile.bodyShape) {
                        ForEach(BodyShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Tondo = corpo cilindrico, Rettangolare = cassa. Le dimensioni 3D si regolano per ogni luce in «Collegamenti».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if profile.type == .ledBar {
                    Picker("Tipo di barra", selection: Binding(
                        get: { profile.barMotorized },
                        set: { profile.setBarMotorized($0) }
                    )) {
                        Text("Non motorizzata (fissa)").tag(false)
                        Text("Motorizzata (canale Tilt)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(profile.barMotorized
                         ? "Il canale Tilt (primo canale) inclina l'intera barra attorno al proprio asse longitudinale."
                         : "La barra resta ferma: nessun canale di movimento.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if profile.type.emitsLight {
                    HStack {
                        Text("Apertura fascio: \(Int(profile.beamAngle))°").monospacedDigit()
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $profile.beamAngle, in: 1...70)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: Pixel

    private var pixelBinding: Binding<PixelConfig> {
        Binding(
            get: { profile.pixelConfig ?? PixelConfig() },
            set: { profile.pixelConfig = $0 }
        )
    }

    /// Quantità di LED proposte nel menu rapido.
    private static let ledCounts = [4, 8, 10, 12, 16, 20, 24, 32]

    private var pixelBox: some View {
        GroupBox(label: Label("Multi-Pixel RGB / RGBW", systemImage: "rectangle.split.3x1")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Abilita pixel indipendenti", isOn: Binding(
                    get: { profile.pixelConfig != nil },
                    set: { on in
                        profile.pixelConfig = on ? PixelConfig() : nil
                        if on { profile.regeneratePixelChannels() }
                    }
                ))
                if let pc = profile.pixelConfig {
                    let white = pc.components.contains(.w)

                    HStack {
                        Picker("Numero di LED", selection: Binding(
                            get: { pc.count },
                            set: { profile.setPixelCount($0) }
                        )) {
                            ForEach(Array(Set(Self.ledCounts + [pc.count])).sorted(), id: \.self) { n in
                                Text("\(n) LED").tag(n)
                            }
                        }
                        .frame(maxWidth: 220)
                        Stepper("", value: Binding(
                            get: { pc.count },
                            set: { profile.setPixelCount($0) }
                        ), in: 1...170)
                        .labelsHidden()
                        Text("\(pc.count)").monospacedDigit().foregroundStyle(.secondary)
                    }

                    Picker("Modalità colore LED", selection: Binding(
                        get: { white },
                        set: { profile.setPixelWhite($0) }
                    )) {
                        Text("RGB (3 canali per LED)").tag(false)
                        Text("RGBW (4 canali per LED)").tag(true)
                    }
                    .pickerStyle(.segmented)

                    let orders = PixelConfig.orderPresets.filter { $0.contains(.w) == white }
                    Picker("Ordine canali per pixel", selection: Binding(
                        get: { orders.firstIndex(of: pc.components) ?? 0 },
                        set: { var c = pixelBinding.wrappedValue; c.components = orders[$0]; pixelBinding.wrappedValue = c; profile.regeneratePixelChannels() }
                    )) {
                        ForEach(orders.indices, id: \.self) { i in
                            Text(PixelConfig.orderLabel(orders[i])).tag(i)
                        }
                    }
                    Stepper(value: Binding(
                        get: { pixelBinding.wrappedValue.firstChannel + 1 },
                        set: { var c = pixelBinding.wrappedValue; c.firstChannel = max(0, $0 - 1); pixelBinding.wrappedValue = c; profile.regeneratePixelChannels() }
                    ), in: 1...512) {
                        Text("Primo canale pixel: CH \(pc.firstChannel + 1)").monospacedDigit()
                    }
                    Button("Genera / aggiorna canali pixel") { profile.regeneratePixelChannels() }
                    Text("Imposta il ruolo «Multi-Pixel» e i nomi sui canali occupati dai pixel, ampliando il numero di canali se serve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()
                    Text("Mappa dei LED sulla barra")
                        .font(.caption.bold())
                    PixelMapperView(profile: profile, selected: $mapperSelection)
                }
            }
            .padding(6)
        }
    }

    // MARK: Macchina del fumo

    private var smokeBox: some View {
        GroupBox(label: Label("Macchina del Fumo", systemImage: "cloud.fill")) {
            VStack(alignment: .leading, spacing: 8) {
                if let i = profile.channels.firstIndex(where: { $0.role == .smoke }) {
                    Text("Canale di attivazione / intensità: CH \(i + 1) (0 = spenta, 255 = emissione massima).")
                        .font(.callout)
                } else {
                    Text("Nessun canale ha il ruolo «Fumo»: la macchina non emette.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Assegna Fumo al primo canale") {
                        if profile.channels.isEmpty { profile.setChannelCount(1) }
                        profile.channels[0].role = .smoke
                        profile.channels[0].name = "Fumo"
                    }
                    .controlSize(.small)
                }
                Text("Nel 3D il fumo è un sistema di particelle molto leggero (sprite sfumati), senza calcoli volumetrici.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    // MARK: Canali

    private var channelsBox: some View {
        GroupBox(label: Label("Mappatura canali", systemImage: "slider.vertical.3")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($profile.channels) { $ch in
                    ChannelRowView(
                        index: profile.channels.firstIndex(where: { $0.id == ch.id }) ?? 0,
                        channel: $ch
                    )
                    Divider()
                }
            }
            .padding(6)
        }
    }
}

struct ChannelRowView: View {
    let index: Int
    @Binding var channel: ChannelDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                TextField("Nome canale", text: $channel.name)
                    .textFieldStyle(.glass)
                Picker("", selection: $channel.role) {
                    ForEach(ChannelRole.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            if let hint = sectionHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
    }

    /// Le funzioni ottiche si configurano nelle sezioni dedicate sopra la mappatura.
    private var sectionHint: String? {
        switch channel.role {
        case .colorWheel: return "Slot e colori: sezione «Colore del fascio» (modalità Ruota Colori)."
        case .strobe: return "Intervalli DMX (spento / attivo) e frequenza massima: sezione «Strobo»."
        case .gobo: return "Intervalli DMX e maschere: sezione «Gobo»."
        case .prism: return "Facce, 3 intervalli DMX (Spento / Fisso / Rotazione) e velocità: sezione «Prisma radiale»."
        case .smoke: return "Attivazione / intensità del fumo: 0 = spenta, 255 = massima."
        default: return nil
        }
    }
}

struct ColorWheelEditor: View {
    @Binding var slots: [ColorWheelSlot]

    /// Ordine fisico degli slot lungo la ruota = valore DMX crescente.
    private var ordered: [ColorWheelSlot] { slots.sorted { $0.from < $1.from } }

    private var hasOverlap: Bool {
        let s = ordered
        guard s.count > 1 else { return false }
        for i in 1..<s.count where s[i].from <= s[i - 1].to { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intervalli DMX (0–255) → colore. L'ordine sulla ruota segue i valori DMX crescenti: passando a uno slot non adiacente la luce attraversa e mostra brevemente i colori intermedi, come una ruota fisica.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !slots.isEmpty {
                HStack(spacing: 2) {
                    ForEach(ordered) { s in
                        VStack(spacing: 1) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: s.colorHex))
                                .frame(width: 26, height: 14)
                            Text("\(s.from)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .help("Ordine degli slot lungo la ruota")
            }
            ForEach($slots) { $slot in
                HStack(spacing: 6) {
                    TextField("Da", value: Binding(
                        get: { slot.from },
                        set: {
                            slot.from = min(max($0, 0), 255)
                            if slot.to < slot.from { slot.to = slot.from }
                        }
                    ), format: .number)
                        .frame(width: 44)
                    Text("–")
                    TextField("A", value: Binding(
                        get: { slot.to },
                        set: { slot.to = min(max($0, slot.from), 255) }
                    ), format: .number)
                        .frame(width: 44)
                    TextField("Nome", text: $slot.name)
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: slot.colorHex) },
                        set: { slot.colorHex = $0.hexString }
                    ))
                    .labelsHidden()
                    Button(role: .destructive) {
                        slots.removeAll { $0.id == slot.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.glass)
            }
            HStack {
                Button("Aggiungi range") {
                    let start = (slots.map { $0.to }.max() ?? -1) + 1
                    slots.append(ColorWheelSlot(from: min(start, 255), to: min(start + 9, 255), name: "Colore", colorHex: "#FFFFFF"))
                }
                Button("Ruota standard") { slots = FixturePresets.standardWheel() }
                Button("Svuota") { slots = [] }
            }
            .controlSize(.small)
            if hasOverlap {
                Text("Alcuni intervalli si sovrappongono: vale il primo che contiene il valore DMX.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
