import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pannello "Scene": salva lo stato corrente come preset (patch, palco, oggetti, Net/SubNet, camera) e lo ricarica.
struct ScenesPanelView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var store: ScenePresetStore

    @State private var newName = ""
    @State private var includeCamera = true
    @State private var selectedPresetID: UUID?
    @State private var renameText = ""
    @State private var message: String?
    @State private var confirmDelete = false

    private var selectedPreset: ScenePreset? {
        guard let id = selectedPresetID else { return nil }
        return store.presets.first(where: { $0.id == id })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                saveBox
                listBox
                if selectedPreset != nil { actionsBox }
                if let m = message {
                    Text(m).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Salvataggio

    private var saveBox: some View {
        GroupBox(label: Label("Salva la scena corrente", systemImage: "square.and.arrow.down")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Nome della scena", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Includi inquadratura della camera", isOn: $includeCamera)
                Button {
                    selectedPresetID = vm.saveScene(name: newName, includeCamera: includeCamera)
                    newName = ""
                    message = nil
                } label: {
                    Label("Salva come preset", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                Text("Un preset contiene la patch con le posizioni delle luci, le dimensioni del palco, gli oggetti 3D, Net/SubNet e (opzionale) la camera. I profili fixture restano nella libreria.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    // MARK: - Elenco

    private var listBox: some View {
        GroupBox(label: Label("Scene salvate", systemImage: "tray.full")) {
            if store.presets.isEmpty {
                Text("Nessuna scena salvata.")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                List(selection: $selectedPresetID) {
                    ForEach(store.presets) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text("\(p.fixtures.count) luci · \(p.objects.count) oggetti · \(Int(p.stage.width))×\(Int(p.stage.depth)) m · \(p.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(p.id)
                    }
                }
                .frame(height: 200)
                .onChange(of: selectedPresetID) { _ in
                    renameText = selectedPreset?.name ?? ""
                }
            }
        }
    }

    // MARK: - Azioni

    private var actionsBox: some View {
        GroupBox(label: Label("Scena selezionata", systemImage: "slider.horizontal.3")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Nome", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                    Button("Rinomina") {
                        if let id = selectedPresetID { store.rename(id: id, to: renameText) }
                    }
                }
                HStack {
                    Button {
                        if let id = selectedPresetID { vm.loadScene(id) }
                    } label: {
                        Label("Carica", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Sovrascrivi con la scena attuale") {
                        if let id = selectedPresetID { vm.overwriteScene(id, includeCamera: includeCamera) }
                    }
                }
                HStack {
                    Button("Esporta JSON…") { exportJSON() }
                    Button("Importa JSON…") { importJSON() }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
                .controlSize(.small)
            }
            .padding(6)
        }
        .confirmationDialog("Eliminare la scena «\(selectedPreset?.name ?? "")»?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                if let id = selectedPresetID {
                    store.delete(id: id)
                    selectedPresetID = nil
                }
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    private func exportJSON() {
        guard let id = selectedPresetID, let p = selectedPreset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(p.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.export(id: id, to: url)
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
                selectedPresetID = try store.importPreset(from: url)
                message = nil
            } catch {
                message = "Importazione non riuscita: \(error.localizedDescription)"
            }
        }
    }
}
