import SwiftUI

@main
struct ArtNetStageApp: App {
    @StateObject private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup("ArtNet Stage") {
            ContentView()
                .environmentObject(vm)
                .environmentObject(vm.patch)
                .environmentObject(vm.server)
                .environmentObject(vm.scene)
                .environmentObject(vm.scenes)
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}
