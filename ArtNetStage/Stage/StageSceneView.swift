import SwiftUI
import SceneKit

/// SCNView con controlli camera personalizzati (la camera è pilotata da `StageController`).
final class StageSCNView: SCNView {
    weak var controller: StageController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = Double(event.deltaX)
        let dy = Double(event.deltaY)
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
            controller?.pan(dx: dx, dy: dy)
        } else {
            controller?.orbit(dx: dx, dy: dy)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        controller?.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func otherMouseDragged(with event: NSEvent) {
        controller?.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad: due dita = orbita, ⇧ + due dita = pan.
            let dx = Double(event.scrollingDeltaX)
            let dy = Double(event.scrollingDeltaY)
            if event.modifierFlags.contains(.shift) {
                controller?.pan(dx: dx, dy: dy)
            } else {
                controller?.orbit(dx: dx * 0.6, dy: dy * 0.6)
            }
        } else {
            // Rotellina del mouse: zoom.
            controller?.zoom(factor: pow(0.92, Double(event.scrollingDeltaY)))
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
        view.backgroundColor = NSColor(white: 0.012, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = false
        view.isPlaying = true       // loop continuo: serve per leggere il DMX a ogni frame
        return view
    }

    func updateNSView(_ nsView: StageSCNView, context: Context) {}
}
