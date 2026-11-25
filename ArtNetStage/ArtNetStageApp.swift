import SwiftUI

@main
struct ArtNetStageApp: App {
    @StateObject private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environmentObject(vm)
                .environmentObject(vm.patch)
                .environmentObject(vm.server)
                .environmentObject(vm.scene)
                .frame(minWidth: 1240, minHeight: 720)
                .preferredColorScheme(.dark)
                .onOpenURL { url in vm.open(url: url) }     // doppio click su un file .artnetstage nel Finder
        }
        .handlesExternalEvents(matching: ["*"])             // un'unica finestra anche aprendo file dal Finder
        .windowStyle(.hiddenTitleBar)                        // v2.0: scena a tutta finestra, nessuna barra del titolo
        .windowResizability(.contentMinSize)
        .commands {
            ProjectCommands(vm: vm)
        }
    }
}

/// Voci del menu File (Apri ⌘O, Salva ⌘S, Salva con nome ⇧⌘S) e voce "Informazioni su ArtNet Stage".
struct ProjectCommands: Commands {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var history: SceneHistory

    init(vm: AppViewModel) {
        self.vm = vm
        self.history = vm.history
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Apri scena…") { vm.openProject() }
                .keyboardShortcut("o", modifiers: .command)
        }
        // Menu Modifica: Annulla ⌘Z / Ripristina ⇧⌘Z
        CommandGroup(replacing: .undoRedo) {
            Button("Annulla") { vm.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!history.canUndo)
            Button("Ripristina") { vm.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!history.canRedo)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Salva scena") { vm.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Salva con nome…") { vm.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button("Informazioni su \(AppInfo.name)") { vm.showAbout() }
        }
    }
}
