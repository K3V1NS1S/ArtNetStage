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
                Text("Seleziona o crea un profilo fixture.")
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
                    .help("Elimina profilo dalla libreria (le luci già patchate restano)")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                generalBox
                if profile.type == .ledBar || profile.pixelConfig != nil { pixelBox }
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
                    TextField("Nome modello", text: $profile.modelName).textFieldStyle(.roundedBorder)
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
                    Stepper(value: $profile.tiltRange, in: 45...540, step: 5) {
                        Text("Escursione Tilt massima: \(Int(profile.tiltRange))°").monospacedDigit()
                    }
                }
                HStack {
                    Text("Apertura fascio: \(Int(profile.beamAngle))°").monospacedDigit()
                        .frame(width: 150, alignment: .leading)
                    Slider(value: $profile.beamAngle, in: 1...70)
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
                if profile.pixelConfig != nil {
                    Stepper(value: pixelBinding.count, in: 1...170) {
                        Text("Numero di pixel: \(pixelBinding.wrappedValue.count)").monospacedDigit()
                    }
                    Picker("Ordine canali per pixel", selection: Binding(
                        get: { PixelConfig.orderPresets.firstIndex(of: pixelBinding.wrappedValue.components) ?? 0 },
                        set: { var pc = pixelBinding.wrappedValue; pc.components = PixelConfig.orderPresets[$0]; pixelBinding.wrappedValue = pc }
                    )) {
                        ForEach(PixelConfig.orderPresets.indices, id: \.self) { i in
                            Text(PixelConfig.orderLabel(PixelConfig.orderPresets[i])).tag(i)
                        }
                    }
                    Stepper(value: Binding(
                        get: { pixelBinding.wrappedValue.firstChannel + 1 },
                        set: { var pc = pixelBinding.wrappedValue; pc.firstChannel = max(0, $0 - 1); pixelBinding.wrappedValue = pc }
                    ), in: 1...512) {
                        Text("Primo canale pixel: CH \(pixelBinding.wrappedValue.firstChannel + 1)").monospacedDigit()
                    }
                    Button("Genera / aggiorna canali pixel") { profile.regeneratePixelChannels() }
                    Text("Imposta il ruolo «Multi-Pixel» e i nomi sui canali occupati dai pixel, ampliando il numero di canali se serve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $channel.role) {
                    ForEach(ChannelRole.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            if channel.role == .colorWheel {
                ColorWheelEditor(slots: $channel.wheelSlots)
                    .padding(.leading, 34)
            }
        }
    }
}

struct ColorWheelEditor: View {
    @Binding var slots: [ColorWheelSlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Range DMX → colore (scatto netto)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($slots) { $slot in
                HStack(spacing: 6) {
                    TextField("Da", value: $slot.from, format: .number)
                        .frame(width: 44)
                    Text("–")
                    TextField("A", value: $slot.to, format: .number)
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
                .textFieldStyle(.roundedBorder)
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
        }
    }
}
