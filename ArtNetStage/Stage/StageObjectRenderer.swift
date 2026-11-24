import SceneKit
import AppKit
import simd

/// Costruisce e aggiorna un oggetto 3D della scena (parallelepipedo o manichino).
/// Materiale `.blinn` + `castsShadow`, così i fasci delle fixture (SCNLight spot) li illuminano davvero.
final class StageObjectRenderer {

    private struct Built {
        var content: SCNNode
        var materials: [SCNMaterial]
        var norm: SIMD3<Float>          // dimensioni (m) del modello normalizzato
        var selSize: SIMD3<Float>
        var selCenter: SIMD3<Float>
    }

    private(set) var object: StageObject

    /// Radice: posizione, rotazione (yaw) e scala. Il nome è l'UUID dell'oggetto (usato dal hitTest).
    let node = SCNNode()

    private let materials: [SCNMaterial]
    private let norm: SIMD3<Float>
    private let selection: SCNNode
    private var lastColorHex = ""

    init(object: StageObject, deckY: Double) {
        self.object = object

        let built: Built
        switch object.kind {
        case .box: built = Self.buildBox()
        case .mannequin: built = Self.buildMannequin()
        }
        materials = built.materials
        norm = built.norm
        selection = SceneHelpers.wireBox(size: built.selSize, center: built.selCenter)

        node.name = object.id.uuidString
        node.addChildNode(built.content)
        node.addChildNode(selection)
        node.castsShadow = true
        built.content.enumerateHierarchy { n, _ in n.castsShadow = true }

        update(object, deckY: deckY)
    }

    func update(_ obj: StageObject, deckY: Double) {
        object = obj
        node.simdPosition = SIMD3<Float>(Float(obj.x), Float(deckY + obj.y), Float(obj.z))
        node.simdEulerAngles = SIMD3<Float>(0, Float(obj.yaw * Double.pi / 180), 0)
        node.simdScale = SIMD3<Float>(
            Float(max(obj.width, 0.01)) / norm.x,
            Float(max(obj.height, 0.01)) / norm.y,
            Float(max(obj.depth, 0.01)) / norm.z
        )
        if obj.colorHex != lastColorHex {
            lastColorHex = obj.colorHex
            let c = parseHex(obj.colorHex)
            let color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            for m in materials { m.diffuse.contents = color }
        }
    }

    func setSelected(_ selected: Bool) {
        selection.isHidden = !selected
    }

    // MARK: - Geometrie

    private static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: 0.6, alpha: 1)
        m.specular.contents = NSColor(white: 0.25, alpha: 1)
        m.shininess = 0.25
        return m
    }

    /// Cubo unitario con l'origine sulla faccia inferiore (scalato poi a larghezza × altezza × profondità).
    private static func buildBox() -> Built {
        let g = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        let m = makeMaterial()
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = SIMD3<Float>(0, 0.5, 0)
        return Built(
            content: n, materials: [m],
            norm: SIMD3<Float>(1, 1, 1),
            selSize: SIMD3<Float>(1.03, 1.03, 1.03),
            selCenter: SIMD3<Float>(0, 0.5, 0)
        )
    }

    /// Sagoma umana stilizzata (0.60 × 1.75 × 0.30 m) fatta di primitive; origine ai piedi.
    private static func buildMannequin() -> Built {
        let m = makeMaterial()
        let root = SCNNode()

        func add(_ g: SCNGeometry, _ p: SIMD3<Float>, rotZ: Float = 0) {
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.simdPosition = p
            n.simdEulerAngles = SIMD3<Float>(0, 0, rotZ)
            root.addChildNode(n)
        }

        add(SCNCapsule(capRadius: 0.065, height: 0.86), SIMD3<Float>(-0.085, 0.43, 0))      // gamba sinistra
        add(SCNCapsule(capRadius: 0.065, height: 0.86), SIMD3<Float>(0.085, 0.43, 0))       // gamba destra
        add(SCNBox(width: 0.34, height: 0.20, length: 0.20, chamferRadius: 0.05), SIMD3<Float>(0, 0.90, 0))   // bacino
        add(SCNBox(width: 0.38, height: 0.46, length: 0.22, chamferRadius: 0.07), SIMD3<Float>(0, 1.20, 0))   // torso
        add(SCNCapsule(capRadius: 0.045, height: 0.62), SIMD3<Float>(-0.255, 1.12, 0), rotZ: 0.08)            // braccio sinistro
        add(SCNCapsule(capRadius: 0.045, height: 0.62), SIMD3<Float>(0.255, 1.12, 0), rotZ: -0.08)            // braccio destro
        add(SCNCylinder(radius: 0.045, height: 0.09), SIMD3<Float>(0, 1.47, 0))                               // collo
        add(SCNSphere(radius: 0.11), SIMD3<Float>(0, 1.62, 0))                                                // testa

        return Built(
            content: root, materials: [m],
            norm: SIMD3<Float>(0.6, 1.75, 0.3),
            selSize: SIMD3<Float>(0.64, 1.79, 0.36),
            selCenter: SIMD3<Float>(0, 0.875, 0)
        )
    }
}
