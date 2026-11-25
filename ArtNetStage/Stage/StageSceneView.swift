import SwiftUI
import SceneKit

/// SCNView con controlli camera personalizzati: la camera è il rig `pivot → pitch → camera` di `StageController`.
///
/// - click sinistro + trascinamento: orbita (yaw/pitch, orizzonte sempre orizzontale)
/// - click destro, oppure ⇧ / ⌥ + trascinamento: pan sul piano del palco
/// - rotellina, due dita sul trackpad (scroll) o pizzico: zoom
/// - click senza trascinamento: seleziona fixture/oggetto (hitTest); doppio click: vista 3/4
/// - Gumball (con un elemento selezionato): un click su una freccia o su un arco blocca l'orbita della camera
///   e vincola il trascinamento a quel solo asse; con ⌃ premuto spostamento a passi di 5 cm e rotazione a 5°
final class StageSCNView: SCNView {
    weak var controller: StageController?

    private var downPoint: CGPoint = .zero
    private var travel: CGFloat = 0
    private var panning = false
    /// Vero mentre si trascina il Gumball: orbita e pan sono sospesi.
    private var gizmoDragging = false

    override var acceptsFirstResponder: Bool { true }

    private func isPanModifier(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        travel = 0
        panning = isPanModifier(event)
        gizmoDragging = false

        // Prima di tutto il hitTest sul Gumball: se colpito, la camera orbitale resta bloccata.
        if let c = controller, let handle = c.gizmoHandle(at: downPoint, in: self),
           c.beginGizmoDrag(handle, at: downPoint, in: self) {
            gizmoDragging = true
            return
        }
        if event.clickCount == 2 { controller?.setPreset(.threeQuarter) }
    }

    override func mouseDragged(with event: NSEvent) {
        if gizmoDragging {
            let p = convert(event.locationInWindow, from: nil)
            controller?.updateGizmoDrag(to: p, snap: event.modifierFlags.contains(.control))
            return
        }
        let dx = Double(event.deltaX)
        let dy = Double(event.deltaY)
        travel += abs(event.deltaX) + abs(event.deltaY)
        if panning || isPanModifier(event) {
            controller?.pan(dx: dx, dy: dy)
        } else {
            controller?.orbit(dx: dx, dy: dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if gizmoDragging {
            // Rilascio: si toglie il vincolo d'asse e i controlli della camera tornano normali.
            gizmoDragging = false
            controller?.endGizmoDrag()
            return
        }
        // Un click senza trascinamento (e non un doppio click) seleziona l'elemento sotto il puntatore.
        if travel < 4, event.clickCount == 1, !panning, !isPanModifier(event) {
            controller?.pick(at: downPoint, in: self)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        controller?.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func otherMouseDragged(with event: NSEvent) {
        controller?.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        if isPanModifier(event) {
            controller?.pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
            return
        }
        let delta = Double(event.scrollingDeltaY)
        if delta == 0 { return }
        if event.hasPreciseScrollingDeltas {
            // Trackpad: delta in pixel, quindi un passo più fine.
            controller?.zoom(factor: exp(-delta * 0.008))
        } else {
            // Rotellina del mouse: delta a scatti.
            controller?.zoom(factor: pow(0.9, delta))
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.zoom(factor: 1 - Double(event.magnification))
    }
}

struct StageSceneView: NSViewRepresentable {
    let controller: StageController

    func makeNSView(context: Context) -> StageSCNView {
        let view = StageSCNView(frame: .zero, options: nil)
        view.controller = controller
        view.scene = controller.scene
        view.pointOfView = controller.cameraNode
        view.delegate = controller
        view.backgroundColor = NSColor.black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = false     // la camera è gestita dal rig personalizzato (niente rollio)
        view.isPlaying = true                // loop continuo: serve per leggere il DMX a ogni frame
        return view
    }

    func updateNSView(_ nsView: StageSCNView, context: Context) {}
}
