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
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
                .onOpenURL { url in vm.open(url: url) }     // doppio click su un file .artnetstage nel Finder
        }
        .handlesExternalEvents(matching: ["*"])             // un'unica finestra anche aprendo file dal Finder
        .windowResizability(.contentMinSize)
        .commands {
            ProjectCommands(vm: vm)
        }
    }
}

/// Voci del menu File (Apri ⌘O, Salva ⌘S, Salva con nome ⇧⌘S) e voce "Informazioni su ArtNet Stage".
struct ProjectCommands: Commands {
    @ObservedObject var vm: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Apri scena…") { vm.openProject() }
                .keyboardShortcut("o", modifiers: .command)
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
