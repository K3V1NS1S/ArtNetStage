import SwiftUI
import AppKit

// MARK: - Chiusura finestra / app con modifiche non salvate (v2.4)

/// `NSApplicationDelegate`: intercetta ⌘Q e «Esci» (`applicationShouldTerminate`) e chiude l'app quando si chiude la finestra.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Impostato da `ContentView` appena la vista compare.
    static weak var viewModel: AppViewModel?
    /// La finestra è già stata approvata (Salva / Non salvare): la terminazione successiva non chiede di nuovo.
    static var closeApproved = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = AppDelegate.viewModel, vm.hasUnsavedChanges, !AppDelegate.closeApproved else { return .terminateNow }
        return vm.confirmClose() ? .terminateNow : .terminateCancel
    }

    /// Un'unica finestra: chiuderla (già confermata) chiude anche l'app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `NSWindowDelegate` per la finestra principale. Inoltra tutti gli altri messaggi al delegate originale di SwiftUI,
/// così ridimensionamento, salvataggio del frame e il resto continuano a funzionare come prima.
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var viewModel: AppViewModel?

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let o = original, o.responds(to: aSelector) { return o }
        return super.forwardingTarget(for: aSelector)
    }

    /// X rossa, ⌘W: nessuna richiesta se tutto è salvato; altrimenti Salva / Non salvare / Annulla.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let o = original, o.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           o.windowShouldClose?(sender) == false {
            return false
        }
        guard let vm = viewModel else { return true }
        if vm.confirmClose() {
            AppDelegate.closeApproved = true
            return true
        }
        return false
    }
}

/// Aggancia il delegate alla finestra che contiene la vista e tiene allineato `isDocumentEdited`
/// (il punto interno al pallino rosso della finestra) con `hasUnsavedChanges`.
struct WindowCloseGuard: NSViewRepresentable {
    let viewModel: AppViewModel
    let hasUnsavedChanges: Bool

    final class Coordinator {
        let delegate = WindowCloseDelegate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let vm = viewModel
        let edited = hasUnsavedChanges
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            coordinator.delegate.viewModel = vm
            if window.delegate !== coordinator.delegate {
                coordinator.delegate.original = window.delegate
                window.delegate = coordinator.delegate
            }
            window.isDocumentEdited = edited
        }
    }
}
