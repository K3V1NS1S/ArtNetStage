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
                    .help("Elimina profilo dalla libreria (le luci già in catena restano)")
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
    @EnvironmentObject var patch: PatchManager
    @EnvironmentObject var vm: AppViewModel
    @Binding var profile: FixtureProfile
    @State private var mapperSelection: Int?
    @State private var dropTarget: UUID?
    @State private var dropAtEnd = false

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
                    set: { n in applyChange { $0.setChannelCount(n); $0.syncPixelConfig() } }
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
                    Text("Tondo = corpo cilindrico, Rettangolare = cassa. Le dimensioni 3D si regolano per ogni luce in «Catena».")
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

    /// Modifica discreta dei canali = un passo di annulla/ripristina: chiude il passo precedente, applica la modifica
    /// e chiude subito il nuovo passo (dopo che il profilo è stato propagato a Catena e visualizzatore).
    private func applyChange(_ change: (inout FixtureProfile) -> Void) {
        vm.history.commitNow()
        var copy = profile
        change(&copy)
        profile = copy
        DispatchQueue.main.async { vm.history.commitNow() }
    }

    /// Luci in Catena che usano questo profilo (per indirizzi assoluti e conflitti).
    private var patchedInstances: [PatchedFixture] { patch.patched.filter { $0.profile.id == profile.id } }

    /// Messaggi di conflitto: sovrapposizioni con altre luci o canali oltre il 512.
    private var conflictMessages: [String] {
        var out: [String] = []
        for f in patchedInstances where patch.conflicts.contains(f.id) {
            if f.endAddress > 512 {
                out.append("\(f.label): occupa fino al canale \(f.endAddress), oltre il limite di 512 dell'universo.")
            }
            for o in patch.patched where o.id != f.id && o.universe == f.universe
                && f.startAddress <= o.endAddress && o.startAddress <= f.endAddress {
                out.append("\(f.label) (\(f.startAddress)–\(f.endAddress)) invade \(o.label) (\(o.startAddress)–\(o.endAddress)) nell'universo \(f.universe).")
            }
        }
        return Array(Set(out)).sorted()
    }

    private func pixelNumber(at index: Int) -> Int? {
        let role = profile.channels[index].role
        guard role.isPixelRole, role != .pixel else { return nil }
        return profile.channels[..<index].filter { $0.role == role }.count + 1
    }

    private var channelsBox: some View {
        GroupBox(label: HStack {
            Label("Mappatura canali", systemImage: "slider.vertical.3")
            Spacer()
            Text("\(profile.channels.count) canali")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            addMenu
        }) {
            VStack(alignment: .leading, spacing: 4) {
                if let first = patchedInstances.first {
                    Text("Indirizzo assoluto calcolato su \(first.label): DMX \(first.startAddress) + offset − 1. Trascina la maniglia per riordinare i canali.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Trascina la maniglia per riordinare i canali. Gli indirizzi assoluti compaiono quando la luce è in «Catena».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let messages = conflictMessages
                if !messages.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(messages, id: \.self) { m in
                            Label(m, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                let count = profile.channels.count
                ForEach($profile.channels) { $ch in
                    let index = profile.channels.firstIndex(where: { $0.id == ch.id }) ?? 0
                    ChannelRowView(
                        index: index,
                        channel: $ch,
                        absoluteAddress: patchedInstances.first.map { $0.startAddress + index },
                        pixelNumber: index < profile.channels.count ? pixelNumber(at: index) : nil,
                        canMoveUp: index > 0,
                        canMoveDown: index < count - 1,
                        canDelete: count > 1,
                        isDropTarget: dropTarget == ch.id,
                        onRole: { role in applyChange { $0.setRole(id: ch.id, to: role) } },
                        onMove: { step in applyChange { $0.nudgeChannel(id: ch.id, by: step) } },
                        onDelete: { applyChange { $0.removeChannel(id: ch.id) } }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        dropTarget = nil
                        guard let raw = items.first, let moving = UUID(uuidString: raw) else { return false }
                        applyChange { $0.moveChannel(id: moving, before: ch.id) }
                        return true
                    } isTargeted: { inside in
                        if inside { dropTarget = ch.id } else if dropTarget == ch.id { dropTarget = nil }
                    }
                }

                // Zona di rilascio in fondo: sposta il canale come ultimo.
                RoundedRectangle(cornerRadius: 3)
                    .fill(dropAtEnd ? Color.accentColor : Color.clear)
                    .frame(height: 4)
                    .padding(.horizontal, 4)
                    .dropDestination(for: String.self) { items, _ in
                        dropAtEnd = false
                        guard let raw = items.first, let moving = UUID(uuidString: raw) else { return false }
                        applyChange { $0.moveChannel(id: moving, before: nil) }
                        return true
                    } isTargeted: { dropAtEnd = $0 }

                HStack {
                    Button {
                        applyChange { $0.addChannels(1, role: .custom) }
                    } label: {
                        Label("Aggiungi Canale", systemImage: "plus.circle.fill")
                    }
                    .disabled(profile.channels.count >= 512)
                    addMenu
                    Spacer()
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(6)
        }
    }

    /// Opzioni rapide: duplica l'ultimo canale, aggiungi più canali o LED completi (barre multi-pixel).
    private var addMenu: some View {
        Menu {
            Button("+ Aggiungi Canale") { applyChange { $0.addChannels(1, role: .custom) } }
            Button("Duplica ultimo canale") { applyChange { $0.duplicateLastChannel() } }
            Divider()
            Button("Aggiungi 2 canali") { applyChange { $0.addChannels(2) } }
            Button("Aggiungi 4 canali") { applyChange { $0.addChannels(4) } }
            Button("Aggiungi 8 canali") { applyChange { $0.addChannels(8) } }
            Divider()
            Button("Aggiungi LED RGB (3 canali pixel)") { applyChange { $0.addPixelLED(white: false) } }
            Button("Aggiungi LED RGBW (4 canali pixel)") { applyChange { $0.addPixelLED(white: true) } }
        } label: {
            Label("Altro", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Riga canale: maniglia di trascinamento, badge CH, indirizzo assoluto, nome, funzione, frecce su/giù, elimina.
struct ChannelRowView: View {
    @Environment(\.sectionTheme) private var theme
    let index: Int
    @Binding var channel: ChannelDefinition
    var absoluteAddress: Int? = nil
    var pixelNumber: Int? = nil
    var canMoveUp = true
    var canMoveDown = true
    var canDelete = true
    var isDropTarget = false
    var onRole: (ChannelRole) -> Void = { _ in }
    var onMove: (Int) -> Void = { _ in }
    var onDelete: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                    .draggable(channel.id.uuidString) {
                        Text("CH \(index + 1) · \(channel.name)")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.accent.opacity(0.35), in: Capsule())
                    }
                    .help("Trascina per riordinare il canale")

                Text("CH \(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.accent.opacity(0.22), in: Capsule())
                    .frame(width: 58)

                if let a = absoluteAddress {
                    Text("DMX \(a)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(a > 512 ? Color.red : Color.secondary)
                        .frame(width: 58, alignment: .leading)
                }

                TextField("Nome canale", text: $channel.name)
                    .textFieldStyle(.glass)

                Picker("", selection: Binding(get: { channel.role }, set: { onRole($0) })) {
                    if channel.role == .pixel { Text(ChannelRole.pixel.label).tag(ChannelRole.pixel) }
                    ForEach(ChannelRole.selectable) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)

                VStack(spacing: 0) {
                    Button { onMove(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)) }
                        .disabled(!canMoveUp)
                        .help("Sposta su di una posizione")
                    Button { onMove(1) } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                        .disabled(!canMoveDown)
                        .help("Sposta giù di una posizione")
                }
                .buttonStyle(.borderless)
                .frame(width: 16)

                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(canDelete ? Color.red.opacity(hovering ? 0.95 : 0.55) : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.borderless)
                .disabled(!canDelete)
                .help(canDelete ? "Elimina il canale (i successivi scalano di una posizione)" : "Una fixture deve avere almeno 1 canale")
            }
            if let hint = sectionHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            Divider()
        }
        .padding(.vertical, 1)
        .background(isDropTarget ? theme.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule().fill(theme.accent).frame(height: 3).offset(y: -2)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Le funzioni ottiche si configurano nelle sezioni dedicate sopra la mappatura.
    private var sectionHint: String? {
        switch channel.role {
        case .colorWheel: return "Slot e colori: sezione «Colore del fascio» (modalità Ruota Colori)."
        case .strobe: return "Intervalli DMX (spento / attivo) e frequenza massima: sezione «Strobo»."
        case .gobo: return "Intervalli DMX e maschere: sezione «Gobo»."
        case .prism: return "Facce, 3 intervalli DMX (Spento / Fisso / Rotazione) e velocità: sezione «Prisma radiale»."
        case .prismRotation: return "Velocità di rotazione del prisma: 0 = ferma, 1–255 = dalla velocità minima alla massima («Prisma radiale»)."
        case .macro, .reset: return "Canale di controllo: viene riservato nel footprint ma non ha effetto nel visualizzatore 3D."
        case .pixelRed, .pixelGreen, .pixelBlue, .pixelWhite:
            if let n = pixelNumber { return "LED \(n) della barra: l'ordine dei canali nell'elenco decide l'ordine dei pixel." }
            return nil
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
