import SceneKit
import AppKit
import simd

/// Costruisce e aggiorna un oggetto 3D della scena: parallelepipedo, manichino o stativo per luci.
/// Materiale `.blinn` + `castsShadow`, così i fasci delle fixture (SCNLight spot) li illuminano davvero.
///
/// Parallelepipedo e manichino sono modelli unitari scalati a larghezza × altezza × profondità.
/// Gli stativi invece vengono **ricostruiti** quando cambiano le misure (un'asta scalata si deformerebbe):
/// `width` = larghezza della barra superiore, `height` = altezza totale (estensione dell'asta),
/// `depth` = ingombro (diametro) della base a treppiede.
final class StageObjectRenderer {

    private struct Built {
        var content: SCNNode
        var materials: [SCNMaterial]
        var norm: SIMD3<Float>          // dimensioni (m) del modello normalizzato
        var selSize: SIMD3<Float>
        var selCenter: SIMD3<Float>
    }

    private(set) var object: StageObject

    /// Radice: posizione, rotazione e scala. Il nome è l'UUID dell'oggetto (usato dal hitTest).
    let node = SCNNode()

    private var content = SCNNode()
    private var materials: [SCNMaterial] = []
    private var norm = SIMD3<Float>(1, 1, 1)
    private var selection = SCNNode()
    private var selCenterY: Float = 0.5
    private var lastColorHex = ""
    private var isSelected = false
    private var standKey = ""

    init(object: StageObject, deckY: Double) {
        self.object = object
        node.name = object.id.uuidString
        node.castsShadow = true
        rebuild(for: object)
        update(object, deckY: deckY)
    }

    /// Centro dell'oggetto sul piano del palco (quota Y relativa al piano), per posizionare il Gumball.
    func worldCenter(deckY: Double) -> SIMD3<Float> {
        let base = SIMD3<Float>(Float(object.x), Float(deckY + object.y), Float(object.z))
        let local = SIMD3<Float>(0, selCenterY, 0)
        return base + Self.orientation(for: object).act(local)
    }

    func update(_ obj: StageObject, deckY: Double) {
        object = obj
        if obj.kind.isStand {
            let key = "\(obj.width)|\(obj.height)|\(obj.depth)"
            if key != standKey { rebuild(for: obj) }
        }
        node.simdPosition = SIMD3<Float>(Float(obj.x), Float(deckY + obj.y), Float(obj.z))
        node.simdOrientation = Self.orientation(for: obj)
        if obj.kind.isStand {
            node.simdScale = SIMD3<Float>(1, 1, 1)
        } else {
            node.simdScale = SIMD3<Float>(
                Float(max(obj.width, 0.01)) / norm.x,
                Float(max(obj.height, 0.01)) / norm.y,
                Float(max(obj.depth, 0.01)) / norm.z
            )
        }
        if obj.colorHex != lastColorHex {
            lastColorHex = obj.colorHex
            let c = parseHex(obj.colorHex)
            let color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            for m in materials { m.diffuse.contents = color }
        }
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        selection.isHidden = !selected
    }

    /// Yaw (Y) · pitch (X) · roll (Z): l'inclinazione si applica nel riferimento dell'oggetto, il yaw nel mondo.
    private static func orientation(for o: StageObject) -> simd_quatf {
        let d = Float.pi / 180
        return simd_quatf(angle: Float(o.yaw) * d, axis: [0, 1, 0])
            * simd_quatf(angle: Float(o.pitchDeg) * d, axis: [1, 0, 0])
            * simd_quatf(angle: Float(o.rollDeg) * d, axis: [0, 0, 1])
    }

    /// (Ri)costruisce contenuto e contorno di selezione.
    private func rebuild(for obj: StageObject) {
        content.removeFromParentNode()
        selection.removeFromParentNode()

        let built: Built
        switch obj.kind {
        case .box: built = Self.buildBox()
        case .mannequin: built = Self.buildMannequin()
        case .standSingle, .standDouble, .standQuad:
            built = Self.buildStand(obj)
            standKey = "\(obj.width)|\(obj.height)|\(obj.depth)"
        }
        content = built.content
        materials = built.materials
        norm = built.norm
        selCenterY = built.selCenter.y
        selection = SceneHelpers.wireBox(size: built.selSize, center: built.selCenter)
        selection.isHidden = !isSelected

        node.addChildNode(content)
        node.addChildNode(selection)
        content.enumerateHierarchy { n, _ in n.castsShadow = true }
        lastColorHex = ""            // forza la ri-applicazione del colore ai materiali nuovi
    }

    // MARK: - Geometrie

    private static func makeMaterial(shininess: CGFloat = 0.25) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: 0.6, alpha: 1)
        m.specular.contents = NSColor(white: 0.25, alpha: 1)
        m.shininess = shininess
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

        // Dettagli frontali (fuori da `materials`, quindi il colore scelto per il manichino non li cambia).
        // Il fronte è +Z locale: con yaw 0 il manichino guarda verso il pubblico («PUBBLICO», lato +Z).
        let visorMat = SCNMaterial()
        visorMat.lightingModel = .blinn
        visorMat.diffuse.contents = NSColor(white: 0.04, alpha: 1)
        visorMat.specular.contents = NSColor(white: 0.7, alpha: 1)
        visorMat.shininess = 0.8
        let noseMat = SCNMaterial()
        noseMat.lightingModel = .blinn
        noseMat.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.10, alpha: 1)
        noseMat.emission.contents = NSColor(srgbRed: 0.35, green: 0.16, blue: 0.0, alpha: 1)
        func addFace(_ g: SCNGeometry, _ mat: SCNMaterial, _ p: SIMD3<Float>, euler: SIMD3<Float> = .zero) {
            g.materials = [mat]
            let n = SCNNode(geometry: g)
            n.simdPosition = p
            n.simdEulerAngles = euler
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
        addFace(SCNBox(width: 0.15, height: 0.045, length: 0.03, chamferRadius: 0.012), visorMat,
                SIMD3<Float>(0, 1.635, 0.095))                                                                 // visiera / occhi
        addFace(SCNCone(topRadius: 0, bottomRadius: 0.022, height: 0.05), noseMat,
                SIMD3<Float>(0, 1.595, 0.115), euler: SIMD3<Float>(Float.pi / 2, 0, 0))                        // naso: punta verso +Z

        return Built(
            content: root, materials: [m],
            norm: SIMD3<Float>(0.6, 1.75, 0.3),
            selSize: SIMD3<Float>(0.64, 1.79, 0.36),
            selCenter: SIMD3<Float>(0, 0.875, 0)
        )
    }

    /// Cilindro sottile fra due punti.
    private static func tube(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let d = b - a
        let len = simd_length(d)
        let cyl = SCNCylinder(radius: radius, height: CGFloat(max(len, 0.001)))
        cyl.materials = [material]
        let n = SCNNode(geometry: cyl)
        n.simdPosition = (a + b) / 2
        if len > 1e-5 { n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: d / len) }
        return n
    }

    /// Stativo a treppiede con asta telescopica. Variante in base al tipo:
    /// singolo = piattello con un attacco; doppio = T-Bar con 2 attacchi alle estremità;
    /// quadruplo = T-Bar con 4 attacchi equidistanti.
    private static func buildStand(_ o: StageObject) -> Built {
        let m = makeMaterial(shininess: 0.4)
        let root = SCNNode()

        let H = Float(min(max(o.height, 0.5), 8))
        let W = Float(min(max(o.width, 0.2), 8))
        let D = Float(min(max(o.depth, 0.3), 4))
        let bar = Float(StageObject.barThickness)

        // Treppiede: tre gambe dal mozzo (a ~38% dell'altezza) ai piedini sul pavimento.
        let hubY = min(H * 0.38, 0.9)
        for k in 0..<3 {
            let a = Float(k) * 2 * Float.pi / 3 + Float.pi / 6
            let foot = SIMD3<Float>(cosf(a) * D / 2, 0.012, sinf(a) * D / 2)
            root.addChildNode(tube(from: SIMD3<Float>(0, hubY, 0), to: foot, radius: 0.016, material: m))
            let pad = SCNCylinder(radius: 0.03, height: 0.024)
            pad.materials = [m]
            let pn = SCNNode(geometry: pad)
            pn.simdPosition = SIMD3<Float>(foot.x, 0.012, foot.z)
            root.addChildNode(pn)
        }
        let hub = SCNCylinder(radius: 0.045, height: 0.09)
        hub.materials = [m]
        let hubNode = SCNNode(geometry: hub)
        hubNode.simdPosition = SIMD3<Float>(0, hubY, 0)
        root.addChildNode(hubNode)

        // Asta: sezione inferiore più larga, sezione telescopica superiore più sottile, con manopola di bloccaggio.
        let splitY = hubY + (H - hubY) * 0.55
        root.addChildNode(tube(from: SIMD3<Float>(0, hubY, 0), to: SIMD3<Float>(0, splitY, 0), radius: 0.024, material: m))
        root.addChildNode(tube(from: SIMD3<Float>(0, splitY - 0.1, 0), to: SIMD3<Float>(0, H, 0), radius: 0.017, material: m))
        let clamp = SCNCylinder(radius: 0.034, height: 0.06)
        clamp.materials = [m]
        let clampNode = SCNNode(geometry: clamp)
        clampNode.simdPosition = SIMD3<Float>(0, splitY, 0)
        root.addChildNode(clampNode)

        // Parte superiore.
        let topExtent: Float
        switch o.kind {
        case .standSingle:
            let plate = SCNCylinder(radius: 0.06, height: 0.012)
            plate.materials = [m]
            let pn = SCNNode(geometry: plate)
            pn.simdPosition = SIMD3<Float>(0, H + 0.006, 0)
            root.addChildNode(pn)
            topExtent = 0.12
        default:
            let tb = SCNBox(width: CGFloat(W), height: CGFloat(bar), length: 0.045, chamferRadius: 0.004)
            tb.materials = [m]
            let tn = SCNNode(geometry: tb)
            tn.simdPosition = SIMD3<Float>(0, H + bar / 2, 0)
            root.addChildNode(tn)
            // Piattelli di appoggio sui punti di montaggio.
            for lx in o.mountLocalX() {
                let pl = SCNCylinder(radius: 0.04, height: 0.006)
                pl.materials = [m]
                let pn = SCNNode(geometry: pl)
                pn.simdPosition = SIMD3<Float>(Float(lx), H + bar + 0.003, 0)
                root.addChildNode(pn)
            }
            topExtent = W
        }

        let footprint = max(D, topExtent) + 0.1
        let selHeight = H + bar + 0.1
        return Built(
            content: root, materials: [m],
            norm: SIMD3<Float>(1, 1, 1),
            selSize: SIMD3<Float>(footprint, selHeight, max(D, 0.2) + 0.1),
            selCenter: SIMD3<Float>(0, selHeight / 2 - 0.02, 0)
        )
    }
}
